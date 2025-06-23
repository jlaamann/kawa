defmodule KawaWeb.WorkflowExecutionChannel do
  @moduledoc """
  WebSocket channel for workflow execution requests.

  Handles client requests to trigger workflow execution by:
  1. Validating the workflow and client
  2. Creating a new saga with saga steps
  3. Starting the saga execution engine
  4. Broadcasting execution status updates
  """

  use KawaWeb, :channel
  require Logger

  alias Kawa.Repo
  alias Kawa.Schemas.{Saga, SagaStep, Client}
  alias Kawa.Core.{SagaSupervisor, ClientRegistry}
  alias Kawa.Contexts.Workflows

  @impl true
  def join("workflow_execution:" <> client_id, payload, socket) do
    Logger.info("Client attempting to join workflow execution channel: #{client_id}")
    Logger.debug("Join payload: #{inspect(payload)}")

    case authenticate_client(client_id, payload) do
      {:ok, client} ->
        # Register client in registry
        ClientRegistry.register_client_channel(client.id, self(), :workflow_execution)

        socket =
          socket
          |> assign(:client_id, client.id)
          |> assign(:client, client)

        Logger.info("Client #{client_id} joined workflow execution channel successfully")
        {:ok, %{status: "connected", channel: "workflow_execution"}, socket}

      {:error, reason} ->
        Logger.warning("Client #{client_id} failed to join: #{inspect(reason)}")
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("trigger_workflow", payload, socket) do
    Logger.info("Received workflow trigger request from client #{socket.assigns.client_id}")
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
  def handle_in(event, payload, socket) do
    Logger.warning("Received unhandled event: #{event} with payload: #{inspect(payload)}")
    {:reply, {:error, %{reason: "unhandled_event", event: event}}, socket}
  end

  @impl true
  def handle_info({:step_result_ack, message}, socket) do
    Logger.debug(
      "Received step result ack in WorkflowExecutionChannel - forwarding to ClientChannel"
    )

    # Forward to client channel since step result acks should go there
    case ClientRegistry.get_client_channel_pid(socket.assigns.client_id, :client) do
      {:ok, client_channel_pid} ->
        send(client_channel_pid, {:step_result_ack, message})

      {:error, :not_found} ->
        Logger.warning("Could not find client channel to forward step result ack")
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:saga_status_update, message}, socket) do
    Logger.debug("Received saga status update in WorkflowExecutionChannel")
    # This channel can handle saga status updates directly
    push(socket, "saga_status_update", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:execute_step, message}, socket) do
    Logger.debug(
      "Received execute step in WorkflowExecutionChannel - forwarding to ClientChannel"
    )

    # Forward to client channel since step execution should go there
    case ClientRegistry.get_client_channel_pid(socket.assigns.client_id, :client) do
      {:ok, client_channel_pid} ->
        send(client_channel_pid, {:execute_step, message})

      {:error, :not_found} ->
        Logger.warning("Could not find client channel to forward execute step")
    end

    {:noreply, socket}
  end

  @impl true
  def terminate(reason, socket) do
    if client_id = socket.assigns[:client_id] do
      Logger.info(
        "Client #{client_id} disconnected from workflow execution channel: #{inspect(reason)}"
      )

      # Pause any running sagas for this client
      SagaSupervisor.pause_client_sagas(client_id)

      # Unregister client
      ClientRegistry.unregister_client(client_id)
    end

    :ok
  end

  # Private functions

  defp authenticate_client(client_id, %{"api_key" => api_key}) do
    case Repo.get(Client, client_id) do
      nil ->
        {:error, :client_not_found}

      client ->
        if Kawa.Utils.ApiKey.validate(api_key, client.api_key_hash) do
          {:ok, client}
        else
          {:error, :invalid_api_key}
        end
    end
  end

  defp authenticate_client(_client_id, _payload) do
    {:error, :missing_api_key}
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
end
