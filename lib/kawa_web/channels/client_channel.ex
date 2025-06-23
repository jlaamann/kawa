defmodule KawaWeb.ClientChannel do
  use KawaWeb, :channel

  alias Kawa.{Repo}
  alias Kawa.Core.ClientRegistry
  alias Kawa.Core.WorkflowRegistry
  alias Kawa.Schemas.Client
  alias Kawa.Schemas.WorkflowDefinition
  alias Kawa.Utils.ApiKey
  alias Kawa.Contexts.Workflows

  require Logger

  @impl true
  def join("client:" <> _client_id, %{"api_key" => api_key}, socket) do
    case authenticate_client(api_key) do
      {:ok, client} ->
        socket = assign(socket, :client, client)

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

    # Send compensation request to client via WebSocket
    push(socket, "compensate_step", message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execute_step, message}, socket) do
    client = socket.assigns.client

    Logger.info(
      "Sending step execution request to client #{client.name} for step #{message.step_id}"
    )

    # Send execution request to client via WebSocket
    push(socket, "execute_step", message)

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
