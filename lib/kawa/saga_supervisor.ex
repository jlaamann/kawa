defmodule Kawa.SagaSupervisor do
  @moduledoc """
  DynamicSupervisor for managing multiple concurrent saga executions.

  This supervisor handles the lifecycle of SagaServer processes, providing:
  - Dynamic creation of saga processes
  - Automatic restart on failure
  - Resource management and cleanup
  - Monitoring and health checks
  """

  use DynamicSupervisor
  require Logger

  @doc """
  Starts the SagaSupervisor.
  """
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a new saga execution process.

  Returns `{:ok, pid}` if successful, `{:error, reason}` otherwise.
  """
  def start_saga(saga_id) when is_binary(saga_id) do
    case get_saga_pid(saga_id) do
      {:ok, _pid} ->
        {:error, :already_running}

      {:error, :not_found} ->
        spec = {Kawa.SagaServer, saga_id}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} ->
            Logger.info("Started saga process for saga #{saga_id}")
            {:ok, pid}

          {:error, reason} ->
            Logger.error("Failed to start saga #{saga_id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Stops a saga execution process.

  Returns `:ok` if successful, `{:error, reason}` otherwise.
  """
  def stop_saga(saga_id) when is_binary(saga_id) do
    case get_saga_pid(saga_id) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("Stopped saga process for saga #{saga_id}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to stop saga #{saga_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_running}
    end
  end

  @doc """
  Gets the process ID for a running saga.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.
  """
  def get_saga_pid(saga_id) when is_binary(saga_id) do
    case Registry.lookup(Kawa.SagaRegistry, saga_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Checks if a saga is currently running.
  """
  def saga_running?(saga_id) when is_binary(saga_id) do
    case get_saga_pid(saga_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Lists all currently running sagas.

  Returns a list of {saga_id, pid} tuples.
  """
  def list_running_sagas do
    Registry.select(Kawa.SagaRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Gets statistics about running sagas.
  """
  def get_statistics do
    running_sagas = list_running_sagas()

    %{
      total_running: length(running_sagas),
      saga_ids: Enum.map(running_sagas, fn {saga_id, _pid} -> saga_id end),
      supervisor_children: DynamicSupervisor.count_children(__MODULE__)
    }
  end

  @doc """
  Starts or resumes saga execution.

  If the saga is not running, starts a new process.
  If already running, resumes execution.
  """
  def start_or_resume_saga(saga_id) when is_binary(saga_id) do
    case get_saga_pid(saga_id) do
      {:ok, _pid} ->
        # Saga is already running, resume it
        Kawa.SagaServer.resume(saga_id)

      {:error, :not_found} ->
        # Start new saga process
        case start_saga(saga_id) do
          {:ok, _pid} ->
            # Start execution
            Kawa.SagaServer.start_execution(saga_id)

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Pauses all running sagas for a specific client.

  Used when a client disconnects.
  """
  def pause_client_sagas(client_id) when is_binary(client_id) do
    client_sagas = get_client_sagas(client_id)

    Enum.each(client_sagas, fn saga_id ->
      case get_saga_pid(saga_id) do
        {:ok, _pid} ->
          Kawa.SagaServer.pause(saga_id)

        {:error, :not_found} ->
          Logger.warning("Saga #{saga_id} not running when trying to pause")
      end
    end)

    Logger.info("Paused #{length(client_sagas)} sagas for client #{client_id}")
    :ok
  end

  @doc """
  Resumes all paused sagas for a specific client.

  Used when a client reconnects.
  """
  def resume_client_sagas(client_id) when is_binary(client_id) do
    client_sagas = get_client_sagas(client_id)

    resumed_count =
      Enum.reduce(client_sagas, 0, fn saga_id, count ->
        case start_or_resume_saga(saga_id) do
          :ok ->
            count + 1

          {:ok, _} ->
            count + 1

          {:error, reason} ->
            Logger.warning("Failed to resume saga #{saga_id}: #{inspect(reason)}")
            count
        end
      end)

    Logger.info("Resumed #{resumed_count}/#{length(client_sagas)} sagas for client #{client_id}")
    :ok
  end

  @doc """
  Performs health check on all running saga processes.

  Returns a report of healthy and unhealthy processes.
  """
  def health_check do
    running_sagas = list_running_sagas()

    {healthy, unhealthy} =
      Enum.reduce(running_sagas, {[], []}, fn {saga_id, pid}, {healthy, unhealthy} ->
        if Process.alive?(pid) do
          case Kawa.SagaServer.get_status(saga_id) do
            %{} -> {[saga_id | healthy], unhealthy}
            _ -> {healthy, [saga_id | unhealthy]}
          end
        else
          {healthy, [saga_id | unhealthy]}
        end
      end)

    %{
      total_checked: length(running_sagas),
      healthy: Enum.reverse(healthy),
      unhealthy: Enum.reverse(unhealthy),
      healthy_count: length(healthy),
      unhealthy_count: length(unhealthy)
    }
  end

  @doc """
  Gracefully shuts down all running sagas.

  Used during application shutdown.
  """
  def shutdown_all_sagas(timeout \\ 30_000) do
    running_sagas = list_running_sagas()

    Logger.info("Shutting down #{length(running_sagas)} running sagas")

    # Pause all sagas first
    Enum.each(running_sagas, fn {saga_id, _pid} ->
      try do
        Kawa.SagaServer.pause(saga_id)
      rescue
        error ->
          Logger.warning("Failed to pause saga #{saga_id} during shutdown: #{inspect(error)}")
      end
    end)

    # Then terminate the supervisor
    case DynamicSupervisor.stop(__MODULE__, :normal, timeout) do
      :ok ->
        Logger.info("All sagas shut down successfully")
        :ok

      {:error, reason} ->
        Logger.error("Failed to shutdown sagas: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # DynamicSupervisor callbacks

  @impl true
  def init(_init_arg) do
    Logger.info("SagaSupervisor started")

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 30
    )
  end

  # Private functions

  defp get_client_sagas(client_id) do
    # Query database for sagas belonging to this client
    # that are in running or paused state
    alias Kawa.Repo
    alias Kawa.Schemas.Saga
    import Ecto.Query

    from(s in Saga,
      where: s.client_id == ^client_id and s.status in ["running", "paused"],
      select: s.id
    )
    |> Repo.all()
  end
end
