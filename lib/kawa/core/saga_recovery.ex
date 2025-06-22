defmodule Kawa.Core.SagaRecovery do
  @moduledoc """
  Handles saga recovery after server restarts.

  This module is responsible for:
  - Identifying active sagas that need recovery on startup
  - Reconstructing saga state from event logs
  - Resuming saga execution for connected clients
  - Handling orphaned sagas whose clients are no longer available
  - Providing monitoring and metrics for recovery operations

  ## Recovery Process

  1. **Discovery**: Query database for sagas in active states
  2. **Reconstruction**: Rebuild saga state from event logs 
  3. **Client Check**: Verify if client is connected
  4. **Resume or Pause**: Resume execution or mark as paused
  5. **Monitoring**: Track and alert on recovery operations

  ## Saga States Subject to Recovery

  - `running`: Currently executing steps
  - `paused`: Waiting for client reconnection
  - `compensating`: In the middle of compensation

  ## Recovery Strategies

  - **Client Available**: Resume execution immediately
  - **Client Unavailable**: Mark as paused, resume on client reconnect
  - **Orphaned**: Mark for cleanup after timeout period
  """

  use GenServer
  require Logger

  alias Kawa.Repo
  alias Kawa.Schemas.{Saga, SagaEvent}
  alias Kawa.Core.{SagaSupervisor, ClientRegistry}
  import Ecto.Query

  @recovery_timeout 30_000
  # 5 minutes
  @orphan_cleanup_interval 60_000 * 5
  # 30 minutes
  @max_orphan_age 60_000 * 30

  defmodule State do
    @moduledoc false
    defstruct [
      :recovery_stats,
      :orphan_timer_ref
    ]

    @type t :: %__MODULE__{
            recovery_stats: map(),
            orphan_timer_ref: reference() | nil
          }
  end

  # Client API

  @doc """
  Starts the saga recovery GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers recovery of all active sagas.
  Called during application startup.
  """
  def recover_all_sagas do
    GenServer.call(__MODULE__, :recover_all_sagas, @recovery_timeout)
  end

  @doc """
  Gets recovery statistics and status.
  """
  def get_recovery_stats do
    GenServer.call(__MODULE__, :get_recovery_stats)
  end

  @doc """
  Manually triggers cleanup of orphaned sagas.
  """
  def cleanup_orphaned_sagas do
    GenServer.call(__MODULE__, :cleanup_orphaned_sagas)
  end

  @doc """
  Attempts to recover a specific saga by ID.
  """
  def recover_saga(saga_id) do
    GenServer.call(__MODULE__, {:recover_saga, saga_id})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("SagaRecovery starting up")

    # Schedule orphan cleanup
    timer_ref = Process.send_after(self(), :cleanup_orphans, @orphan_cleanup_interval)

    state = %State{
      recovery_stats: initialize_stats(),
      orphan_timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:recover_all_sagas, _from, state) do
    Logger.info("Starting saga recovery process")
    start_time = System.monotonic_time(:millisecond)

    recovery_result = perform_full_recovery()

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    # Update recovery stats
    updated_stats = update_recovery_stats(state.recovery_stats, recovery_result, duration)

    Logger.info("Saga recovery completed",
      recovered: recovery_result.recovered,
      paused: recovery_result.paused,
      failed: recovery_result.failed,
      duration_ms: duration
    )

    {:reply, recovery_result, %{state | recovery_stats: updated_stats}}
  end

  @impl true
  def handle_call(:get_recovery_stats, _from, state) do
    {:reply, state.recovery_stats, state}
  end

  @impl true
  def handle_call(:cleanup_orphaned_sagas, _from, state) do
    result = cleanup_orphaned_sagas_internal()
    {:reply, result, state}
  end

  @impl true
  def handle_call({:recover_saga, saga_id}, _from, state) do
    result = recover_single_saga(saga_id)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup_orphans, state) do
    Logger.debug("Running scheduled orphan cleanup")
    cleanup_orphaned_sagas_internal()

    # Schedule next cleanup
    timer_ref = Process.send_after(self(), :cleanup_orphans, @orphan_cleanup_interval)

    {:noreply, %{state | orphan_timer_ref: timer_ref}}
  end

  # Private functions

  defp perform_full_recovery do
    active_sagas = get_active_sagas()

    Logger.info("Found #{length(active_sagas)} active sagas to recover")

    results = %{recovered: 0, paused: 0, failed: 0, total: length(active_sagas)}

    Enum.reduce(active_sagas, results, fn saga, acc ->
      case recover_single_saga(saga.id) do
        {:ok, :recovered} ->
          %{acc | recovered: acc.recovered + 1}

        {:ok, :paused} ->
          %{acc | paused: acc.paused + 1}

        {:error, _reason} ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp get_active_sagas do
    from(s in Saga,
      where: s.status in ["running", "paused", "compensating"],
      preload: [:saga_steps, :workflow_definition]
    )
    |> Repo.all()
  end

  defp recover_single_saga(saga_id) do
    Logger.debug("Recovering saga #{saga_id}")

    with {:ok, saga} <- get_saga_with_context(saga_id),
         {:ok, reconstructed_state} <- reconstruct_saga_state(saga),
         {:ok, recovery_action} <- determine_recovery_action(saga),
         {:ok, _result} <- execute_recovery_action(saga, reconstructed_state, recovery_action) do
      {:ok, recovery_action}
    else
      {:error, reason} ->
        Logger.error("Failed to recover saga #{saga_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_saga_with_context(saga_id) do
    case Repo.get(Saga, saga_id) |> Repo.preload([:saga_steps, :workflow_definition]) do
      nil -> {:error, :saga_not_found}
      saga -> {:ok, saga}
    end
  end

  defp reconstruct_saga_state(saga) do
    # Get all events for this saga ordered by sequence
    events =
      from(e in SagaEvent,
        where: e.saga_id == ^saga.id,
        order_by: [asc: e.sequence_number]
      )
      |> Repo.all()

    # Rebuild state from events
    initial_state = %{
      saga_id: saga.id,
      status: saga.status,
      current_step: nil,
      completed_steps: [],
      failed_steps: [],
      context: saga.context || %{}
    }

    reconstructed_state = Enum.reduce(events, initial_state, &apply_event_to_state/2)

    Logger.debug("Reconstructed saga state",
      saga_id: saga.id,
      completed_steps: length(reconstructed_state.completed_steps),
      failed_steps: length(reconstructed_state.failed_steps),
      current_step: reconstructed_state.current_step
    )

    {:ok, reconstructed_state}
  end

  defp apply_event_to_state(event, state) do
    case event.event_type do
      "step_started" ->
        step_id = get_in(event.payload, ["step_id"])
        %{state | current_step: step_id}

      "step_completed" ->
        step_id = get_in(event.payload, ["step_id"])
        completed_steps = [step_id | state.completed_steps] |> Enum.uniq()
        %{state | completed_steps: completed_steps, current_step: nil}

      "step_failed" ->
        step_id = get_in(event.payload, ["step_id"])
        failed_steps = [step_id | state.failed_steps] |> Enum.uniq()
        %{state | failed_steps: failed_steps, current_step: nil}

      "saga_completed" ->
        %{state | status: "completed", current_step: nil}

      "saga_failed" ->
        %{state | status: "failed", current_step: nil}

      "compensation_started" ->
        %{state | status: "compensating"}

      "compensation_completed" ->
        %{state | status: "compensated"}

      "saga_paused" ->
        %{state | status: "paused"}

      "saga_resumed" ->
        %{state | status: "running"}

      _ ->
        state
    end
  end

  defp determine_recovery_action(saga) do
    case ClientRegistry.client_connected?(saga.client_id) do
      true ->
        Logger.debug("Client #{saga.client_id} is connected, will recover saga")
        {:ok, :recovered}

      false ->
        Logger.debug("Client #{saga.client_id} is not connected, will pause saga")
        {:ok, :paused}
    end
  end

  defp execute_recovery_action(saga, _reconstructed_state, :recovered) do
    # Client is available, start saga server and resume
    case SagaSupervisor.start_saga(saga.id) do
      {:ok, _pid} ->
        update_saga_status_to_running(saga)
        Logger.info("Successfully recovered and resumed saga #{saga.id}")
        {:ok, :recovered}

      {:error, {:already_started, _pid}} ->
        update_saga_status_to_running(saga)
        Logger.debug("Saga #{saga.id} already running")
        {:ok, :recovered}

      {:error, :already_running} ->
        update_saga_status_to_running(saga)
        Logger.debug("Saga #{saga.id} already running")
        {:ok, :recovered}

      {:error, reason} ->
        Logger.error("Failed to start saga server for #{saga.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_recovery_action(saga, _reconstructed_state, :paused) do
    # Client not available, update saga status to paused
    changeset =
      Ecto.Changeset.change(saga,
        status: "paused",
        paused_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

    case Repo.update(changeset) do
      {:ok, _updated_saga} ->
        Logger.info("Marked saga #{saga.id} as paused due to missing client")
        {:ok, :paused}

      {:error, reason} ->
        Logger.error("Failed to pause saga #{saga.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp cleanup_orphaned_sagas_internal do
    cutoff_time =
      DateTime.utc_now()
      |> DateTime.add(-@max_orphan_age, :millisecond)

    orphaned_sagas =
      from(s in Saga,
        where: s.status == "paused" and s.paused_at < ^cutoff_time
      )
      |> Repo.all()

    Logger.info("Found #{length(orphaned_sagas)} orphaned sagas for cleanup")

    cleanup_results =
      Enum.map(orphaned_sagas, fn saga ->
        case ClientRegistry.client_connected?(saga.client_id) do
          true ->
            # Client reconnected, attempt recovery
            recover_single_saga(saga.id)

          false ->
            # Still orphaned, mark as failed
            mark_saga_as_failed(saga, "orphaned_timeout")
        end
      end)

    cleaned_up = cleanup_results |> Enum.count(&match?({:ok, _}, &1))
    failed_cleanup = cleanup_results |> Enum.count(&match?({:error, _}, &1))

    %{
      total_checked: length(orphaned_sagas),
      cleaned_up: cleaned_up,
      failed_cleanup: failed_cleanup
    }
  end

  defp mark_saga_as_failed(saga, reason) do
    changeset =
      Ecto.Changeset.change(saga,
        status: "failed",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

    case Repo.update(changeset) do
      {:ok, _updated_saga} ->
        Logger.info("Marked orphaned saga #{saga.id} as failed due to #{reason}")
        {:ok, :failed}

      {:error, error} ->
        Logger.error("Failed to mark saga #{saga.id} as failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp initialize_stats do
    %{
      last_recovery_at: nil,
      total_recoveries: 0,
      last_recovery_duration_ms: 0,
      total_sagas_recovered: 0,
      total_sagas_paused: 0,
      total_recovery_failures: 0
    }
  end

  defp update_recovery_stats(stats, recovery_result, duration_ms) do
    %{
      stats
      | last_recovery_at: DateTime.utc_now(),
        total_recoveries: stats.total_recoveries + 1,
        last_recovery_duration_ms: duration_ms,
        total_sagas_recovered: stats.total_sagas_recovered + recovery_result.recovered,
        total_sagas_paused: stats.total_sagas_paused + recovery_result.paused,
        total_recovery_failures: stats.total_recovery_failures + recovery_result.failed
    }
  end

  defp update_saga_status_to_running(saga) do
    changeset =
      Ecto.Changeset.change(saga,
        status: "running",
        paused_at: nil
      )

    case Repo.update(changeset) do
      {:ok, _updated_saga} ->
        Logger.debug("Updated saga #{saga.id} status to running")
        :ok

      {:error, reason} ->
        Logger.error("Failed to update saga #{saga.id} status to running: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
