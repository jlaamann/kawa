defmodule Kawa.Core.ClientRegistry do
  @moduledoc """
  Registry for tracking connected WebSocket clients and their PIDs.

  This module manages the mapping between client IDs and their WebSocket process PIDs,
  enabling the saga orchestrator to communicate with connected clients.
  """

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Register a client connection with its WebSocket PID.
  """
  def register_client(client_id, pid) when is_binary(client_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, client_id, pid})
  end

  @doc """
  Register a client channel with its WebSocket PID and channel type.
  """
  def register_client_channel(client_id, pid, channel_type)
      when is_binary(client_id) and is_pid(pid) and is_atom(channel_type) do
    GenServer.call(__MODULE__, {:register_channel, client_id, pid, channel_type})
  end

  @doc """
  Unregister a client connection.
  """
  def unregister_client(client_id) when is_binary(client_id) do
    GenServer.call(__MODULE__, {:unregister, client_id})
  end

  @doc """
  Get the WebSocket PID for a connected client.
  """
  def get_client_pid(client_id) when is_binary(client_id) do
    GenServer.call(__MODULE__, {:get_pid, client_id})
  end

  @doc """
  Get the WebSocket PID for a specific client channel type.
  """
  def get_client_channel_pid(client_id, channel_type)
      when is_binary(client_id) and is_atom(channel_type) do
    GenServer.call(__MODULE__, {:get_channel_pid, client_id, channel_type})
  end

  @doc """
  Check if a client is currently connected.
  """
  def client_connected?(client_id) when is_binary(client_id) do
    case get_client_pid(client_id) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, :not_found} -> false
    end
  end

  @doc """
  Get all connected client IDs.
  """
  def list_connected_clients do
    GenServer.call(__MODULE__, :list_clients)
  end

  @doc """
  Send a message to a connected client via their WebSocket channel.
  """
  def send_to_client(client_id, event, payload) do
    case get_client_pid(client_id) do
      {:ok, pid} ->
        send(pid, {:push, event, payload})
        :ok

      {:error, :not_found} ->
        Logger.warning("Attempted to send message to disconnected client: #{client_id}")
        {:error, :client_not_connected}
    end
  end

  ## GenServer Implementation

  @impl true
  def init(_) do
    # Monitor client processes to automatically clean up when they die
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, client_id, pid}, _from, state) do
    # Monitor the client process
    Process.monitor(pid)

    new_state = Map.put(state, client_id, pid)
    Logger.debug("Registered client #{client_id} with PID #{inspect(pid)}")

    # Check for paused sagas and attempt to resume them
    Task.start(fn ->
      resume_client_sagas(client_id)
    end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:register_channel, client_id, pid, channel_type}, _from, state) do
    # Monitor the client process
    Process.monitor(pid)

    # Store channels in a nested map: %{client_id => %{channel_type => pid}}
    client_channels = Map.get(state, client_id, %{})
    updated_channels = Map.put(client_channels, channel_type, pid)
    new_state = Map.put(state, client_id, updated_channels)

    Logger.debug(
      "Registered client #{client_id} #{channel_type} channel with PID #{inspect(pid)}"
    )

    Task.start(fn ->
      resume_client_sagas(client_id)
    end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unregister, client_id}, _from, state) do
    new_state = Map.delete(state, client_id)
    Logger.debug("Unregistered client #{client_id}")

    # Pause running sagas for this client
    Task.start(fn ->
      pause_client_sagas(client_id)
    end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_pid, client_id}, _from, state) do
    case Map.get(state, client_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{} = channels ->
        # Return only the client channel PID
        case Map.get(channels, :client) do
          nil -> {:reply, {:error, :not_found}, state}
          pid -> {:reply, {:ok, pid}, state}
        end

      pid when is_pid(pid) ->
        # Legacy format: direct PID mapping, assume it's a client channel
        {:reply, {:ok, pid}, state}
    end
  end

  @impl true
  def handle_call({:get_channel_pid, client_id, channel_type}, _from, state) do
    case Map.get(state, client_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{} = channels ->
        case Map.get(channels, channel_type) do
          nil -> {:reply, {:error, :not_found}, state}
          pid -> {:reply, {:ok, pid}, state}
        end

      pid when is_pid(pid) ->
        # Old format: only one channel, assume it's the requested type
        {:reply, {:ok, pid}, state}
    end
  end

  @impl true
  def handle_call(:list_clients, _from, state) do
    client_ids = Map.keys(state)
    {:reply, client_ids, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and remove the client that went down
    client_id =
      state
      |> Enum.find(fn {_id, client_pid} -> client_pid == pid end)
      |> case do
        {id, _pid} -> id
        nil -> nil
      end

    if client_id do
      new_state = Map.delete(state, client_id)
      Logger.info("Client #{client_id} process died, removing from registry")

      # Pause running sagas for this client
      Task.start(fn ->
        pause_client_sagas(client_id)
      end)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Private functions for saga management

  defp resume_client_sagas(client_id) do
    Logger.info("Attempting to resume sagas for reconnected client #{client_id}")

    # Find paused sagas for this client
    paused_sagas = get_paused_sagas_for_client(client_id)

    Logger.info("Found #{length(paused_sagas)} paused sagas for client #{client_id}")

    Enum.each(paused_sagas, fn saga ->
      case Kawa.Core.SagaRecovery.recover_saga(saga.id) do
        {:ok, :recovered} ->
          Logger.info("Successfully resumed saga #{saga.id} for client #{client_id}")

        {:ok, :paused} ->
          Logger.debug("Saga #{saga.id} remains paused")

        {:error, reason} ->
          Logger.error(
            "Failed to resume saga #{saga.id} for client #{client_id}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp pause_client_sagas(client_id) do
    Logger.info("Pausing running sagas for disconnected client #{client_id}")

    # Find running sagas for this client
    running_sagas = get_running_sagas_for_client(client_id)

    Logger.info("Found #{length(running_sagas)} running sagas for client #{client_id}")

    Enum.each(running_sagas, fn saga ->
      case Kawa.Core.SagaSupervisor.get_saga_pid(saga.id) do
        {:ok, _pid} ->
          Kawa.Core.SagaServer.pause(saga.id)
          Logger.info("Paused saga #{saga.id} for disconnected client #{client_id}")

        {:error, _reason} ->
          Logger.debug("Saga #{saga.id} not currently running")
      end
    end)
  end

  defp get_paused_sagas_for_client(client_id) do
    import Ecto.Query

    from(s in Kawa.Schemas.Saga,
      where: s.client_id == ^client_id and s.status == "paused"
    )
    |> Kawa.Repo.all()
  end

  defp get_running_sagas_for_client(client_id) do
    import Ecto.Query

    from(s in Kawa.Schemas.Saga,
      where: s.client_id == ^client_id and s.status in ["running", "compensating"]
    )
    |> Kawa.Repo.all()
  end
end
