defmodule KawaWeb.ClientChannel do
  use KawaWeb, :channel

  alias Kawa.{Repo, ClientRegistry}
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
    # TODO: Implement workflow registration
    client = socket.assigns.client
    Logger.info("Client #{client.name} registering workflow: #{workflow_def["name"]}")

    {:reply, {:ok, %{status: "workflow_registered"}}, socket}
  end

  @impl true
  def handle_in(
        "step_result",
        %{"saga_id" => saga_id, "step_id" => step_id, "result" => _result},
        socket
      ) do
    # TODO: Implement step result handling
    client = socket.assigns.client
    Logger.info("Client #{client.name} reported step result for saga #{saga_id}, step #{step_id}")

    {:reply, {:ok, %{status: "result_received"}}, socket}
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
