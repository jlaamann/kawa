defmodule Kawa.Execution.StepExecutionTracker do
  @moduledoc """
  Tracks step execution lifecycle and provides monitoring capabilities.

  This module provides a centralized view of step execution across all sagas,
  enabling monitoring, debugging, and performance analysis.
  """

  use GenServer
  require Logger

  alias Kawa.Repo
  alias Kawa.Schemas.{SagaStep}
  import Ecto.Query

  defmodule ExecutionMetrics do
    @moduledoc false
    defstruct [
      :step_id,
      :saga_id,
      :status,
      :started_at,
      :completed_at,
      :execution_time_ms,
      :retry_count,
      :error_details,
      :correlation_id
    ]

    @type t :: %__MODULE__{
            step_id: String.t(),
            saga_id: String.t(),
            status: String.t(),
            started_at: DateTime.t() | nil,
            completed_at: DateTime.t() | nil,
            execution_time_ms: non_neg_integer() | nil,
            retry_count: non_neg_integer(),
            error_details: map(),
            correlation_id: String.t() | nil
          }
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :active_executions,
      :execution_history,
      :performance_metrics,
      :error_patterns
    ]

    @type t :: %__MODULE__{
            active_executions: %{String.t() => ExecutionMetrics.t()},
            execution_history: list(ExecutionMetrics.t()),
            performance_metrics: map(),
            error_patterns: map()
          }
  end

  # Client API

  @doc """
  Starts the StepExecutionTracker.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %State{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Tracks the start of step execution.
  """
  def track_step_started(saga_id, step_id, correlation_id \\ nil) do
    GenServer.cast(__MODULE__, {:step_started, saga_id, step_id, correlation_id})
  end

  @doc """
  Tracks step completion.
  """
  def track_step_completed(saga_id, step_id, execution_time_ms \\ nil) do
    GenServer.cast(__MODULE__, {:step_completed, saga_id, step_id, execution_time_ms})
  end

  @doc """
  Tracks step failure.
  """
  def track_step_failed(saga_id, step_id, error, execution_time_ms \\ nil) do
    GenServer.cast(__MODULE__, {:step_failed, saga_id, step_id, error, execution_time_ms})
  end

  @doc """
  Gets execution metrics for a specific step.
  """
  def get_step_metrics(saga_id, step_id) do
    GenServer.call(__MODULE__, {:get_step_metrics, saga_id, step_id})
  end

  @doc """
  Gets all active (running) step executions.
  """
  def get_active_executions do
    GenServer.call(__MODULE__, :get_active_executions)
  end

  @doc """
  Gets performance statistics across all steps.
  """
  def get_performance_stats do
    GenServer.call(__MODULE__, :get_performance_stats)
  end

  @doc """
  Gets error analysis and patterns.
  """
  def get_error_analysis do
    GenServer.call(__MODULE__, :get_error_analysis)
  end

  @doc """
  Gets execution timeline for a saga.
  """
  def get_saga_timeline(saga_id) do
    GenServer.call(__MODULE__, {:get_saga_timeline, saga_id})
  end

  @doc """
  Searches execution history by criteria.
  """
  def search_executions(criteria) do
    GenServer.call(__MODULE__, {:search_executions, criteria})
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    state = %{
      state
      | active_executions: %{},
        execution_history: [],
        performance_metrics: %{
          total_executions: 0,
          successful_executions: 0,
          failed_executions: 0,
          average_execution_time_ms: 0,
          fastest_execution_ms: nil,
          slowest_execution_ms: nil
        },
        error_patterns: %{}
    }

    # Load recent execution state from database
    spawn(fn -> load_recent_executions() end)

    Logger.info("StepExecutionTracker started")
    {:ok, state}
  end

  @impl true
  def handle_cast({:step_started, saga_id, step_id, correlation_id}, state) do
    execution_key = "#{saga_id}:#{step_id}"

    metrics = %ExecutionMetrics{
      step_id: step_id,
      saga_id: saga_id,
      status: "running",
      started_at: DateTime.utc_now(),
      completed_at: nil,
      execution_time_ms: nil,
      retry_count: 0,
      error_details: %{},
      correlation_id: correlation_id
    }

    new_state = %{
      state
      | active_executions: Map.put(state.active_executions, execution_key, metrics)
    }

    Logger.debug("Tracking started: #{step_id} in saga #{saga_id}")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:step_completed, saga_id, step_id, execution_time_ms}, state) do
    execution_key = "#{saga_id}:#{step_id}"

    case Map.get(state.active_executions, execution_key) do
      nil ->
        Logger.warning("Completed step #{step_id} not found in active executions")
        {:noreply, state}

      metrics ->
        completed_at = DateTime.utc_now()

        calculated_time =
          execution_time_ms ||
            if metrics.started_at,
              do: DateTime.diff(completed_at, metrics.started_at, :millisecond),
              else: 0

        updated_metrics = %{
          metrics
          | status: "completed",
            completed_at: completed_at,
            execution_time_ms: calculated_time
        }

        # Move to history and update performance metrics
        new_state = %{
          state
          | active_executions: Map.delete(state.active_executions, execution_key),
            execution_history: [updated_metrics | Enum.take(state.execution_history, 99)],
            performance_metrics:
              update_performance_metrics(state.performance_metrics, updated_metrics)
        }

        Logger.debug("Tracking completed: #{step_id} in #{calculated_time}ms")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:step_failed, saga_id, step_id, error, execution_time_ms}, state) do
    execution_key = "#{saga_id}:#{step_id}"

    case Map.get(state.active_executions, execution_key) do
      nil ->
        Logger.warning("Failed step #{step_id} not found in active executions")
        {:noreply, state}

      metrics ->
        completed_at = DateTime.utc_now()

        calculated_time =
          execution_time_ms ||
            if metrics.started_at,
              do: DateTime.diff(completed_at, metrics.started_at, :millisecond),
              else: 0

        updated_metrics = %{
          metrics
          | status: "failed",
            completed_at: completed_at,
            execution_time_ms: calculated_time,
            error_details: error
        }

        # Move to history and update metrics
        new_state = %{
          state
          | active_executions: Map.delete(state.active_executions, execution_key),
            execution_history: [updated_metrics | Enum.take(state.execution_history, 99)],
            performance_metrics:
              update_performance_metrics(state.performance_metrics, updated_metrics),
            error_patterns: update_error_patterns(state.error_patterns, error)
        }

        Logger.debug("Tracking failed: #{step_id} after #{calculated_time}ms")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:get_step_metrics, saga_id, step_id}, _from, state) do
    execution_key = "#{saga_id}:#{step_id}"

    # Check active executions first
    case Map.get(state.active_executions, execution_key) do
      nil ->
        # Check recent history
        historical_metrics =
          Enum.find(state.execution_history, fn metrics ->
            metrics.saga_id == saga_id && metrics.step_id == step_id
          end)

        case historical_metrics do
          nil -> {:reply, {:error, :not_found}, state}
          metrics -> {:reply, {:ok, metrics}, state}
        end

      metrics ->
        {:reply, {:ok, metrics}, state}
    end
  end

  @impl true
  def handle_call(:get_active_executions, _from, state) do
    active_list =
      state.active_executions
      |> Map.values()
      |> Enum.map(fn metrics ->
        %{
          saga_id: metrics.saga_id,
          step_id: metrics.step_id,
          status: metrics.status,
          started_at: metrics.started_at,
          running_time_ms:
            if(metrics.started_at,
              do: DateTime.diff(DateTime.utc_now(), metrics.started_at, :millisecond),
              else: 0
            ),
          correlation_id: metrics.correlation_id
        }
      end)

    {:reply, active_list, state}
  end

  @impl true
  def handle_call(:get_performance_stats, _from, state) do
    current_time = DateTime.utc_now()

    enhanced_stats =
      Map.merge(state.performance_metrics, %{
        active_executions_count: map_size(state.active_executions),
        recent_executions_count: length(state.execution_history),
        longest_running_step: get_longest_running_step(state.active_executions),
        error_rate: calculate_error_rate(state.execution_history),
        timestamp: current_time
      })

    {:reply, enhanced_stats, state}
  end

  @impl true
  def handle_call(:get_error_analysis, _from, state) do
    analysis = %{
      error_patterns: state.error_patterns,
      recent_errors: get_recent_errors(state.execution_history),
      error_distribution: calculate_error_distribution(state.execution_history),
      most_common_errors: get_most_common_errors(state.error_patterns)
    }

    {:reply, analysis, state}
  end

  @impl true
  def handle_call({:get_saga_timeline, saga_id}, _from, state) do
    # Get all executions for this saga from active and history
    active_for_saga =
      state.active_executions
      |> Map.values()
      |> Enum.filter(fn metrics -> metrics.saga_id == saga_id end)

    historical_for_saga =
      state.execution_history
      |> Enum.filter(fn metrics -> metrics.saga_id == saga_id end)

    timeline =
      (active_for_saga ++ historical_for_saga)
      |> Enum.sort_by(fn metrics -> metrics.started_at end, {:desc, DateTime})
      |> Enum.map(fn metrics ->
        %{
          step_id: metrics.step_id,
          status: metrics.status,
          started_at: metrics.started_at,
          completed_at: metrics.completed_at,
          execution_time_ms: metrics.execution_time_ms,
          error_details: metrics.error_details
        }
      end)

    {:reply, timeline, state}
  end

  @impl true
  def handle_call({:search_executions, criteria}, _from, state) do
    all_executions = Map.values(state.active_executions) ++ state.execution_history

    filtered =
      Enum.filter(all_executions, fn metrics ->
        matches_criteria?(metrics, criteria)
      end)

    {:reply, filtered, state}
  end

  # Private functions

  defp load_recent_executions do
    # Load recent step executions from database to initialize state
    # This would typically load the last hour of executions
    try do
      one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

      _recent_steps =
        from(s in SagaStep,
          where: s.updated_at > ^one_hour_ago,
          order_by: [desc: s.updated_at],
          limit: 100
        )
        |> Repo.all()

      # Process and send to tracker
      # GenServer.cast(__MODULE__, {:load_historical_data, recent_steps})
    rescue
      error ->
        Logger.warning("Failed to load recent executions: #{inspect(error)}")
    end
  end

  defp update_performance_metrics(metrics, execution_metrics) do
    new_total = metrics.total_executions + 1

    new_successful =
      if execution_metrics.status == "completed" do
        metrics.successful_executions + 1
      else
        metrics.successful_executions
      end

    new_failed =
      if execution_metrics.status == "failed" do
        metrics.failed_executions + 1
      else
        metrics.failed_executions
      end

    # Update execution time statistics
    execution_time = execution_metrics.execution_time_ms || 0

    new_average =
      if new_total > 0 do
        current_total_time = metrics.average_execution_time_ms * metrics.total_executions
        div(current_total_time + execution_time, new_total)
      else
        0
      end

    new_fastest =
      case metrics.fastest_execution_ms do
        nil -> execution_time
        current -> min(current, execution_time)
      end

    new_slowest =
      case metrics.slowest_execution_ms do
        nil -> execution_time
        current -> max(current, execution_time)
      end

    %{
      metrics
      | total_executions: new_total,
        successful_executions: new_successful,
        failed_executions: new_failed,
        average_execution_time_ms: new_average,
        fastest_execution_ms: new_fastest,
        slowest_execution_ms: new_slowest
    }
  end

  defp update_error_patterns(patterns, error) do
    error_type = Map.get(error, "type", "unknown_error")
    error_code = Map.get(error, "code")

    # Update error type frequency
    patterns = Map.update(patterns, {:type, error_type}, 1, fn count -> count + 1 end)

    # Update error code frequency if present
    patterns =
      if error_code do
        Map.update(patterns, {:code, error_code}, 1, fn count -> count + 1 end)
      else
        patterns
      end

    patterns
  end

  defp get_longest_running_step(active_executions) do
    case Enum.max_by(
           active_executions,
           fn {_key, metrics} ->
             if metrics.started_at do
               DateTime.diff(DateTime.utc_now(), metrics.started_at, :millisecond)
             else
               0
             end
           end,
           fn -> nil end
         ) do
      nil ->
        nil

      {_key, metrics} ->
        %{
          saga_id: metrics.saga_id,
          step_id: metrics.step_id,
          running_time_ms: DateTime.diff(DateTime.utc_now(), metrics.started_at, :millisecond)
        }
    end
  end

  defp calculate_error_rate(execution_history) do
    if length(execution_history) == 0 do
      0.0
    else
      failed_count = Enum.count(execution_history, fn metrics -> metrics.status == "failed" end)
      failed_count / length(execution_history)
    end
  end

  defp get_recent_errors(execution_history) do
    execution_history
    |> Enum.filter(fn metrics -> metrics.status == "failed" end)
    |> Enum.take(10)
    |> Enum.map(fn metrics ->
      %{
        saga_id: metrics.saga_id,
        step_id: metrics.step_id,
        error: metrics.error_details,
        failed_at: metrics.completed_at
      }
    end)
  end

  defp calculate_error_distribution(execution_history) do
    errors = Enum.filter(execution_history, fn metrics -> metrics.status == "failed" end)

    total_errors = length(errors)

    if total_errors == 0 do
      %{}
    else
      errors
      |> Enum.group_by(fn metrics -> Map.get(metrics.error_details, "type", "unknown") end)
      |> Enum.into(%{}, fn {error_type, error_list} ->
        {error_type, length(error_list) / total_errors}
      end)
    end
  end

  defp get_most_common_errors(error_patterns) do
    error_patterns
    |> Enum.filter(fn {{type, _value}, _count} -> type == :type end)
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(5)
    |> Enum.map(fn {{:type, error_type}, count} -> {error_type, count} end)
  end

  defp matches_criteria?(metrics, criteria) do
    Enum.all?(criteria, fn {key, value} ->
      case key do
        :saga_id -> metrics.saga_id == value
        :step_id -> metrics.step_id == value
        :status -> metrics.status == value
        :min_execution_time -> (metrics.execution_time_ms || 0) >= value
        :max_execution_time -> (metrics.execution_time_ms || 0) <= value
        :error_type -> Map.get(metrics.error_details, "type") == value
        _ -> true
      end
    end)
  end
end
