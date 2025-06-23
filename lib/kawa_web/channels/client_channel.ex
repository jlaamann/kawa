defmodule KawaWeb.ClientChannel do
  use KawaWeb, :channel

  alias Kawa.{Repo}
  alias Kawa.Core.{ClientRegistry, SagaSupervisor, WorkflowRegistry}
  alias Kawa.Schemas.{Client, Saga, SagaStep, WorkflowDefinition}
  alias Kawa.Utils.ApiKey
  alias Kawa.Contexts.Workflows

  require Logger

  @impl true
  def join("client:" <> _client_id, %{"api_key" => api_key}, socket) do
    case authenticate_client(api_key) do
      {:ok, client} ->
        socket =
          socket
          |> assign(:client, client)
          |> assign(:client_id, client.id)

        # Register the client connection
        ClientRegistry.register_client_channel(client.id, self(), :client)

        # Update client status to connected
        update_client_status(client, "connected")

        Logger.info("Client #{client.name} (#{client.id}) connected via WebSocket")

        {:ok, %{client_id: client.id, status: "connected"}, socket}

      {:error, reason} ->
        Logger.warning("Client authentication failed: #{reason}")
        {:error, %{reason: "authentication_failed"}}
    end
  end

  @impl true
  def join("client:" <> _client_id, _params, _socket) do
    {:error, %{reason: "api_key_required"}}
  end

  @impl true
  @spec handle_in(<<_::64, _::_*8>>, any(), any()) ::
          {:reply, {:error, map()} | {:ok, map()}, any()}
  def handle_in("heartbeat", _payload, socket) do
    client = socket.assigns.client

    # Update last heartbeat
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    client
    |> Client.changeset(%{last_heartbeat_at: now})
    |> Repo.update()

    {:reply, {:ok, %{timestamp: now}}, socket}
  end

  @impl true
  def handle_in("register_workflow", workflow_def, socket) do
    client = socket.assigns.client

    case Kawa.Validation.WorkflowValidator.validate(workflow_def) do
      {:ok, validated_workflow} ->
        Logger.info(
          "Client #{client.name} registering valid workflow: #{validated_workflow["name"]}"
        )

        case store_workflow_definition(client, validated_workflow) do
          {:ok, workflow_db_record} ->
            # Deactivate previous versions in the DB
            Workflows.deactivate_previous_versions(workflow_db_record)

            # Also register in the in-memory registry for runtime use
            workflow_params = %{
              definition: validated_workflow,
              client_id: client.id,
              metadata: %{
                "database_id" => workflow_db_record.id,
                "registered_via" => "websocket"
              }
            }

            case WorkflowRegistry.register_workflow(validated_workflow["name"], workflow_params) do
              {:ok, version} ->
                Logger.info(
                  "Workflow '#{validated_workflow["name"]}' v#{version} stored in database and registered in memory for client #{client.name}"
                )

                {:reply,
                 {:ok,
                  %{
                    status: "workflow_registered",
                    workflow_id: validated_workflow["name"],
                    version: version,
                    database_id: workflow_db_record.id
                  }}, socket}

              {:error, registry_error} ->
                Logger.error(
                  "Failed to register workflow in memory registry: #{inspect(registry_error)}"
                )

                {:reply, {:error, %{reason: "registry_error", details: registry_error}}, socket}
            end

          {:error, :version_already_exists} ->
            Logger.error(
              "Failed to store workflow definition in database: workflow with the provided version already exists"
            )

            {:reply, {:error, :version_already_exists}, socket}

          {:error, changeset} ->
            Logger.error(
              "Failed to store workflow definition in database: #{inspect(changeset.errors)}"
            )

            {:reply, {:error, %{reason: "database_error", errors: changeset.errors}}, socket}
        end

      {:error, validation_errors} ->
        Logger.warning(
          "Client #{client.name} submitted invalid workflow: #{inspect(validation_errors)}"
        )

        {:reply, {:error, %{reason: "validation_failed", errors: validation_errors}}, socket}
    end
  end

  @impl true
  def handle_in("trigger_workflow", payload, socket) do
    Logger.info("Received workflow trigger request from client #{socket.assigns.client.name}")
    Logger.debug("Trigger payload: #{inspect(payload)}")

    case validate_trigger_payload(payload) do
      {:ok, validated_payload} ->
        # Start workflow execution asynchronously to avoid client timeout
        task =
          Task.async(fn ->
            execute_workflow(validated_payload, socket.assigns.client)
          end)

        try do
          # 4 second timeout to keep under client's 5s limit
          case Task.await(task, 4_000) do
            {:ok, saga} ->
              # Broadcast successful trigger
              broadcast(socket, "workflow_triggered", %{
                saga_id: saga.id,
                correlation_id: saga.correlation_id,
                workflow_name: validated_payload.workflow_name,
                workflow_version: validated_payload.workflow_version,
                status: "triggered"
              })

              {:reply, {:ok, %{saga_id: saga.id, correlation_id: saga.correlation_id}}, socket}

            {:error, reason} ->
              Logger.error("Failed to execute workflow: #{inspect(reason)}")
              # Convert tuple reasons to JSON-serializable format
              serializable_reason =
                case reason do
                  {:execution_start_failed, detail} ->
                    %{type: "execution_start_failed", detail: to_string(detail)}

                  {:step_creation_failed, detail} ->
                    %{type: "step_creation_failed", detail: to_string(detail)}

                  {:saga_creation_failed, detail} ->
                    %{type: "saga_creation_failed", detail: to_string(detail)}

                  other ->
                    to_string(other)
                end

              {:reply, {:error, %{reason: serializable_reason}}, socket}
          end
        catch
          :exit, {:timeout, _} ->
            Logger.warning("Workflow execution timed out, responding to client anyway")
            # Return a partial response to prevent client timeout
            {:reply,
             {:ok,
              %{status: "processing", message: "Workflow execution started but still processing"}},
             socket}
        end

      {:error, errors} ->
        Logger.warning("Invalid trigger payload: #{inspect(errors)}")
        {:reply, {:error, %{validation_errors: errors}}, socket}
    end
  end

  @impl true
  def handle_in("get_saga_status", %{"saga_id" => saga_id}, socket) do
    try do
      case Kawa.Core.SagaServer.get_status(saga_id) do
        %{} = status ->
          {:reply, {:ok, status}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: reason}}, socket}
      end
    catch
      :exit, {:noproc, _} ->
        {:reply, {:error, %{reason: :saga_not_running}}, socket}

      :exit, reason ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in(
        "step_result",
        %{"saga_id" => saga_id, "step_id" => step_id, "result" => result},
        socket
      ) do
    client = socket.assigns.client
    Logger.info("Client #{client.name} reported step result for saga #{saga_id}, step #{step_id}")

    # Forward result to SagaServer
    case Kawa.Core.SagaSupervisor.get_saga_pid(saga_id) do
      {:ok, _pid} ->
        Kawa.Core.SagaServer.step_completed(saga_id, step_id, result)
        {:reply, {:ok, %{status: "result_received"}}, socket}

      {:error, _reason} ->
        Logger.warning("Saga #{saga_id} not found for step result")
        {:reply, {:error, %{reason: "saga_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("step_completed", payload, socket) do
    client = socket.assigns.client

    with {:ok, saga_id} <- Map.fetch(payload, "saga_id"),
         {:ok, step_id} <- Map.fetch(payload, "step_id"),
         {:ok, result} <- Map.fetch(payload, "result") do
      Logger.info(
        "Client #{client.name} reported step_completed for saga #{saga_id}, step #{step_id}"
      )

      case SagaSupervisor.get_saga_pid(saga_id) do
        {:ok, _pid} ->
          Kawa.Core.SagaServer.step_completed(saga_id, step_id, result)
          {:reply, {:ok, %{status: "step_completed_received"}}, socket}

        {:error, _reason} ->
          Logger.warning("Saga #{saga_id} not found for step_completed")
          {:reply, {:error, %{reason: "saga_not_found"}}, socket}
      end
    else
      :error ->
        Logger.warning("Invalid step_completed payload: missing required fields")
        {:reply, {:error, %{reason: "invalid_payload"}}, socket}
    end
  end

  @impl true
  def handle_in("step_failed", payload, socket) do
    client = socket.assigns.client

    with {:ok, saga_id} <- Map.fetch(payload, "saga_id"),
         {:ok, step_id} <- Map.fetch(payload, "step_id"),
         {:ok, error} <- Map.fetch(payload, "error") do
      Logger.info(
        "Client #{client.name} reported step_failed for saga #{saga_id}, step #{step_id}"
      )

      case SagaSupervisor.get_saga_pid(saga_id) do
        {:ok, _pid} ->
          Kawa.Core.SagaServer.step_failed(saga_id, step_id, error)
          {:reply, {:ok, %{status: "step_failed_received"}}, socket}

        {:error, _reason} ->
          Logger.warning("Saga #{saga_id} not found for step_failed")
          {:reply, {:error, %{reason: "saga_not_found"}}, socket}
      end
    else
      :error ->
        Logger.warning("Invalid step_failed payload: missing required fields")
        {:reply, {:error, %{reason: "invalid_payload"}}, socket}
    end
  end

  # Generic handler for different step result formats
  @impl true
  def handle_in("step_result", payload, socket) when is_map(payload) do
    client = socket.assigns.client

    # Try to handle different formats that clients might send
    cond do
      Map.has_key?(payload, "status") and Map.has_key?(payload, "data") ->
        handle_status_data_format(payload, socket)

      true ->
        Logger.warning(
          "Client #{client.name} sent unrecognized step_result format: #{inspect(payload)}"
        )

        {:reply, {:error, %{reason: "unrecognized_format"}}, socket}
    end
  end

  @impl true
  def handle_in("compensation_completed", payload, socket) do
    handle_compensation_result(payload, socket, "compensation_completed")
  end

  @impl true
  def handle_in("compensation_failed", payload, socket) do
    handle_compensation_result(payload, socket, "compensation_failed")
  end

  # Legacy support for old message format
  @impl true
  def handle_in(
        "compensation_result",
        %{"saga_id" => saga_id, "step_id" => step_id, "result" => result, "status" => status},
        socket
      ) do
    client = socket.assigns.client

    Logger.info(
      "Client #{client.name} reported compensation result (legacy format) for saga #{saga_id}, step #{step_id}"
    )

    # Forward compensation result to CompensationEngine
    compensation_result_message =
      case status do
        "success" -> {:compensation_completed, saga_id, step_id, result}
        "failed" -> {:compensation_failed, saga_id, step_id, result}
        _ -> {:compensation_failed, saga_id, step_id, %{error: "invalid_status", details: result}}
      end

    # Send message to all processes that might be waiting for this compensation result
    # This is a broadcast approach - in production you'd want to track specific PIDs
    Registry.dispatch(Kawa.SagaRegistry, saga_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, compensation_result_message)
    end)

    {:reply, {:ok, %{status: "compensation_received"}}, socket}
  end

  @impl true
  def handle_info({:compensate_step, message}, socket) do
    client = socket.assigns.client

    Logger.info(
      "Sending compensation request to client #{client.name} for step #{message.step_id}"
    )

    Logger.debug("Compensation request message: #{inspect(message)}")

    # Send compensation request to client via WebSocket
    push(socket, "compensate_step", message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execute_step, message}, socket) do
    client = socket.assigns.client

    Logger.info(
      "ClientChannel: Received execute_step message for client #{client.name} (#{client.id}), step #{message.step_id}, saga #{message.saga_id}"
    )

    # Send execution request to client via WebSocket
    push(socket, "execute_step", message)

    Logger.info("ClientChannel: Pushed execute_step to WebSocket for client #{client.name}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:step_result_ack, message}, socket) do
    client = socket.assigns.client

    Logger.info(
      "Sending step result acknowledgment to client #{client.name} for saga #{message.saga_id}, step #{message.step_id}"
    )

    # Send step result acknowledgment to client via WebSocket
    push(socket, "step_result_ack", message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:saga_status_update, message}, socket) do
    client = socket.assigns.client

    Logger.info(
      "Sending saga status update to client #{client.name} for saga #{message.saga_id}: #{message.status}"
    )

    # Send saga status update to client via WebSocket
    push(socket, "saga_status_update", message)

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if client = socket.assigns[:client] do
      # Unregister the client
      ClientRegistry.unregister_client(client.id)

      # Update client status to disconnected
      update_client_status(client, "disconnected")

      Logger.info("Client #{client.name} (#{client.id}) disconnected")
    end

    :ok
  end

  defp authenticate_client(api_key) do
    case Repo.get_by(Client, api_key_hash: hash_api_key(api_key)) do
      nil ->
        {:error, "invalid_api_key"}

      client ->
        if ApiKey.validate(api_key, client.api_key_hash) do
          {:ok, client}
        else
          {:error, "invalid_api_key"}
        end
    end
  end

  defp hash_api_key(api_key) do
    :crypto.hash(:sha256, api_key) |> Base.encode16(case: :lower)
  end

  defp handle_compensation_result(payload, socket, result_type) do
    client = socket.assigns.client

    with {:ok, saga_id} <- Map.fetch(payload, "saga_id"),
         {:ok, step_id} <- Map.fetch(payload, "step_id") do
      Logger.info(
        "Client #{client.name} reported #{result_type} for saga #{saga_id}, step #{step_id}"
      )

      Logger.debug("Compensation result payload: #{inspect(payload)}")

      # Extract result or error based on message type
      result_or_error =
        case result_type do
          "compensation_completed" -> Map.get(payload, "result", %{})
          "compensation_failed" -> Map.get(payload, "error", %{})
        end

      # Forward compensation result to CompensationEngine
      compensation_result_message =
        case result_type do
          "compensation_completed" -> {:compensation_completed, saga_id, step_id, result_or_error}
          "compensation_failed" -> {:compensation_failed, saga_id, step_id, result_or_error}
        end

      # Send message to all processes that might be waiting for this compensation result
      # This is a broadcast approach - in production you'd want to track specific PIDs
      Registry.dispatch(Kawa.SagaRegistry, saga_id, fn entries ->
        for {pid, _} <- entries, do: send(pid, compensation_result_message)
      end)

      {:reply, {:ok, %{status: "compensation_received"}}, socket}
    else
      :error ->
        Logger.warning("Invalid compensation result payload: missing required fields")
        {:reply, {:error, %{reason: "invalid_payload"}}, socket}
    end
  end

  defp update_client_status(client, status) do
    client
    |> Client.changeset(%{
      status: status,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  defp handle_status_data_format(payload, socket) do
    client = socket.assigns.client

    with {:ok, saga_id} <- Map.fetch(payload, "saga_id"),
         {:ok, step_id} <- Map.fetch(payload, "step_id"),
         {:ok, status} <- Map.fetch(payload, "status"),
         {:ok, data} <- Map.fetch(payload, "data") do
      Logger.info(
        "Client #{client.name} sent step result with status/data format for saga #{saga_id}, step #{step_id}"
      )

      case SagaSupervisor.get_saga_pid(saga_id) do
        {:ok, _pid} ->
          case status do
            "success" ->
              Kawa.Core.SagaServer.step_completed(saga_id, step_id, data)
              {:reply, {:ok, %{status: "step_completed_received"}}, socket}

            "error" ->
              Kawa.Core.SagaServer.step_failed(saga_id, step_id, data)
              {:reply, {:ok, %{status: "step_failed_received"}}, socket}

            _ ->
              Logger.warning("Unknown status in step result: #{status}")
              {:reply, {:error, %{reason: "unknown_status", status: status}}, socket}
          end

        {:error, _reason} ->
          Logger.warning("Saga #{saga_id} not found for step result")
          {:reply, {:error, %{reason: "saga_not_found"}}, socket}
      end
    else
      :error ->
        Logger.warning("Invalid status/data format payload: missing required fields")
        {:reply, {:error, %{reason: "invalid_payload"}}, socket}
    end
  end

  defp validate_trigger_payload(payload) do
    required_fields = ["workflow_name", "correlation_id"]

    case validate_required_fields(payload, required_fields) do
      :ok ->
        validated = %{
          workflow_name: payload["workflow_name"],
          workflow_version: Map.get(payload, "workflow_version", "latest"),
          correlation_id: payload["correlation_id"],
          input: Map.get(payload, "input", %{}),
          metadata: Map.get(payload, "metadata", %{}),
          timeout_ms: Map.get(payload, "timeout_ms", 300_000)
        }

        # Additional validations
        case validate_workflow_exists(validated.workflow_name, validated.workflow_version) do
          {:ok, workflow_definition} ->
            {:ok, Map.put(validated, :workflow_definition, workflow_definition)}

          {:error, reason} ->
            {:error, [workflow: reason]}
        end

      {:error, missing_fields} ->
        {:error, [required_fields: "Missing required fields: #{Enum.join(missing_fields, ", ")}"]}
    end
  end

  defp validate_required_fields(payload, required_fields) do
    missing_fields =
      required_fields
      |> Enum.filter(fn field -> not Map.has_key?(payload, field) or is_nil(payload[field]) end)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, missing_fields}
    end
  end

  defp validate_workflow_exists(workflow_name, "latest") do
    # Get the latest active version
    case Workflows.list_workflow_versions(workflow_name) do
      [] ->
        {:error, :workflow_not_found}

      versions ->
        active_version = Enum.find(versions, & &1.is_active) || List.first(versions)
        {:ok, active_version}
    end
  end

  defp validate_workflow_exists(workflow_name, workflow_version) do
    # Get specific version
    case Workflows.list_workflow_versions(workflow_name) do
      [] ->
        {:error, :workflow_not_found}

      versions ->
        case Enum.find(versions, &(&1.version == workflow_version)) do
          nil -> {:error, :workflow_version_not_found}
          workflow -> {:ok, workflow}
        end
    end
  end

  defp execute_workflow(validated_payload, client) do
    # Create saga and steps in transaction first
    case Repo.transaction(fn ->
           # Create saga
           case create_saga(validated_payload, client) do
             {:ok, saga} ->
               # Create saga steps
               case create_saga_steps(saga, validated_payload.workflow_definition) do
                 {:ok, _steps} ->
                   saga

                 {:error, reason} ->
                   Repo.rollback({:step_creation_failed, reason})
               end

             {:error, reason} ->
               Repo.rollback({:saga_creation_failed, reason})
           end
         end) do
      {:ok, saga} ->
        # Start saga execution AFTER transaction commits
        case start_saga_execution(saga.id) do
          {:ok, _} ->
            {:ok, saga}

          {:error, reason} ->
            Logger.error("Failed to start saga execution for saga #{saga.id}: #{inspect(reason)}")
            {:error, {:execution_start_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_saga(validated_payload, client) do
    saga_attrs = %{
      correlation_id: validated_payload.correlation_id,
      status: "pending",
      input: validated_payload.input,
      context: %{
        "workflow_name" => validated_payload.workflow_name,
        "workflow_version" => validated_payload.workflow_definition.version,
        "triggered_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "timeout_ms" => validated_payload.timeout_ms
      },
      metadata: validated_payload.metadata,
      workflow_definition_id: validated_payload.workflow_definition.id,
      client_id: client.id
    }

    %Saga{}
    |> Saga.create_changeset(saga_attrs)
    |> Repo.insert()
  end

  defp create_saga_steps(saga, workflow_definition) do
    steps = Map.get(workflow_definition.definition, "steps", [])

    saga_steps =
      Enum.map(steps, fn step ->
        %{
          saga_id: saga.id,
          step_id: step["id"],
          step_type: "action",
          status: "pending",
          execution_metadata: %{
            "step_definition" => step,
            "workflow_name" => workflow_definition.name,
            "workflow_version" => workflow_definition.version
          },
          retry_count: 0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      end)

    case Repo.insert_all(SagaStep, saga_steps, returning: true) do
      {count, steps} when count > 0 ->
        Logger.info("Created #{count} saga steps for saga #{saga.id}")
        {:ok, steps}

      {0, _} ->
        {:error, :no_steps_created}
    end
  end

  defp start_saga_execution(saga_id) do
    Logger.info("Starting saga execution for saga #{saga_id}")

    # Add timeout protection for saga startup
    task =
      Task.async(fn ->
        SagaSupervisor.start_or_resume_saga(saga_id)
      end)

    try do
      # 10 second timeout
      case Task.await(task, 10_000) do
        :ok ->
          Logger.info("Started saga execution for saga #{saga_id}")
          {:ok, saga_id}

        {:ok, _pid} ->
          Logger.info("Started saga execution for saga #{saga_id}")
          {:ok, saga_id}

        {:error, reason} ->
          Logger.error("Failed to start saga execution for saga #{saga_id}: #{inspect(reason)}")
          {:error, reason}
      end
    catch
      :exit, {:timeout, _} ->
        Logger.error("Saga execution startup timed out for saga #{saga_id}")
        {:error, :startup_timeout}
    end
  end

  defp store_workflow_definition(client, validated_workflow) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Generate a checksum for the workflow definition
    definition_json = Jason.encode!(validated_workflow)
    checksum = :crypto.hash(:sha256, definition_json) |> Base.encode16(case: :lower)

    # Extract workflow metadata
    workflow_name = validated_workflow["name"]
    version = Map.get(validated_workflow, "version", "1.0.0")
    module_name = Map.get(validated_workflow, "module_name", workflow_name)
    timeout_ms = Map.get(validated_workflow, "timeout_ms", 300_000)

    retry_policy =
      Map.get(validated_workflow, "retry_policy", %{"max_retries" => 3, "backoff_ms" => 1000})

    # Check if workflow with same name and version already exists for this client
    case Repo.get_by(WorkflowDefinition,
           client_id: client.id,
           name: workflow_name,
           version: version
         ) do
      nil ->
        # Create new workflow definition
        %WorkflowDefinition{}
        |> WorkflowDefinition.changeset(%{
          name: workflow_name,
          version: version,
          module_name: module_name,
          definition: validated_workflow,
          definition_checksum: checksum,
          default_timeout_ms: timeout_ms,
          default_retry_policy: retry_policy,
          is_active: true,
          validation_errors: [],
          registered_at: now,
          client_id: client.id
        })
        |> Repo.insert()

      existing_workflow ->
        # Check if the definition is actually different
        existing_checksum = existing_workflow.definition_checksum

        if existing_checksum == checksum do
          # Exact same workflow - treat as success on reconnection
          Logger.info(
            "Client #{client.name} re-registering identical workflow: #{workflow_name} v#{version}"
          )

          {:ok, existing_workflow}
        else
          # Different definition with same version - this is an error
          {:error, :version_already_exists}
        end
    end
  end
end
