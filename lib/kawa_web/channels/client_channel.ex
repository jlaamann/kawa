defmodule KawaWeb.ClientChannel do
  use KawaWeb, :channel

  alias Kawa.{Repo}
  alias Kawa.Core.ClientRegistry
  alias Kawa.Schemas.Client
  alias Kawa.Utils.ApiKey

  require Logger

  @impl true
  def join("client:" <> _client_id, %{"api_key" => api_key}, socket) do
    case authenticate_client(api_key) do
      {:ok, client} ->
        socket = assign(socket, :client, client)

        # Register the client connection
        ClientRegistry.register_client(client.id, self())

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
  def handle_in("register_workflow", %{"workflow" => workflow_def}, socket) do
    client = socket.assigns.client

    case Kawa.Validation.WorkflowValidator.validate(workflow_def) do
      {:ok, validated_workflow} ->
        Logger.info(
          "Client #{client.name} registering valid workflow: #{validated_workflow["name"]}"
        )

        # TODO: Store workflow definition in database
        {:reply, {:ok, %{status: "workflow_registered", workflow_id: validated_workflow["name"]}},
         socket}

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
  def handle_in(
        "compensation_result",
        %{"saga_id" => saga_id, "step_id" => step_id, "result" => result, "status" => status},
        socket
      ) do
    client = socket.assigns.client

    Logger.info(
      "Client #{client.name} reported compensation result for saga #{saga_id}, step #{step_id}"
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

  defp update_client_status(client, status) do
    client
    |> Client.changeset(%{
      status: status,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end
end
