defmodule Kawa.ClientRegistry do
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

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unregister, client_id}, _from, state) do
    new_state = Map.delete(state, client_id)
    Logger.debug("Unregistered client #{client_id}")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_pid, client_id}, _from, state) do
    case Map.get(state, client_id) do
      nil -> {:reply, {:error, :not_found}, state}
      pid -> {:reply, {:ok, pid}, state}
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
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end
end
