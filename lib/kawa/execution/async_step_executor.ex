defmodule Kawa.Execution.AsyncStepExecutor do
  @moduledoc """
  Handles async step execution with timeout management and parallel processing.

  This module provides enhanced async execution capabilities for saga steps,
  including configurable timeouts, parallel execution control, and graceful
  timeout handling.
  """

  use GenServer
  require Logger

  alias Kawa.Execution.StepExecutionProtocol

  defmodule ExecutionState do
    @moduledoc false
    defstruct [
      :saga_id,
      :step_id,
      :client_pid,
      :correlation_id,
      :start_time,
      :timeout_ms,
      :timeout_ref,
      :callback_module,
      :callback_pid,
      :metadata
    ]

    @type t :: %__MODULE__{
            saga_id: String.t(),
            step_id: String.t(),
            client_pid: pid(),
            correlation_id: String.t(),
            start_time: DateTime.t(),
            timeout_ms: non_neg_integer(),
            timeout_ref: reference() | nil,
            callback_module: module(),
            callback_pid: pid(),
            metadata: map()
          }
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :executing_steps,
      :execution_stats
    ]

    @type t :: %__MODULE__{
            executing_steps: %{String.t() => ExecutionState.t()},
            execution_stats: map()
          }
  end

  # Client API

  @doc """
  Starts the AsyncStepExecutor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %State{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Executes a step asynchronously with timeout handling.

  Returns `{:ok, correlation_id}` if execution started successfully.
  """
  def execute_step_async(saga_id, step_id, input, client_pid, opts \\ []) do
    GenServer.call(__MODULE__, {
      :execute_step_async,
      saga_id,
      step_id,
      input,
      client_pid,
      opts
    })
  end

  @doc """
  Handles step completion notification.
  """
  def step_completed(correlation_id, result) do
    GenServer.cast(__MODULE__, {:step_completed, correlation_id, result})
  end

  @doc """
  Handles step failure notification.
  """
  def step_failed(correlation_id, error) do
    GenServer.cast(__MODULE__, {:step_failed, correlation_id, error})
  end

  @doc """
  Cancels a running step execution.
  """
  def cancel_step(correlation_id) do
    GenServer.cast(__MODULE__, {:cancel_step, correlation_id})
  end

  @doc """
  Gets the status of a step execution.
  """
  def get_execution_status(correlation_id) do
    GenServer.call(__MODULE__, {:get_execution_status, correlation_id})
  end

  @doc """
  Lists all currently executing steps.
  """
  def list_executing_steps do
    GenServer.call(__MODULE__, :list_executing_steps)
  end

  @doc """
  Gets execution statistics.
  """
  def get_statistics do
    GenServer.call(__MODULE__, :get_statistics)
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    state = %{
      state
      | executing_steps: %{},
        execution_stats: %{
          total_executions: 0,
          successful_executions: 0,
          failed_executions: 0,
          timeout_executions: 0,
          average_execution_time_ms: 0
        }
    }

    Logger.info("AsyncStepExecutor started")
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:execute_step_async, saga_id, step_id, input, client_pid, opts},
        {callback_pid, _},
        state
      ) do
    correlation_id = Keyword.get(opts, :correlation_id) || Ecto.UUID.generate()
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    callback_module = Keyword.get(opts, :callback_module, Kawa.Core.SagaServer)
    metadata = Keyword.get(opts, :metadata, %{})

    # Create execution state
    execution_state = %ExecutionState{
      saga_id: saga_id,
      step_id: step_id,
      client_pid: client_pid,
      correlation_id: correlation_id,
      start_time: DateTime.utc_now(),
      timeout_ms: timeout_ms,
      timeout_ref: nil,
      callback_module: callback_module,
      callback_pid: callback_pid,
      metadata: metadata
    }

    # Send execution request to client
    message =
      StepExecutionProtocol.create_execution_request(
        saga_id,
        step_id,
        input,
        timeout_ms: timeout_ms,
        correlation_id: correlation_id,
        metadata: metadata
      )

    case send_to_client(client_pid, message) do
      :ok ->
        # Set timeout
        timeout_ref = Process.send_after(self(), {:execution_timeout, correlation_id}, timeout_ms)
        execution_state = %{execution_state | timeout_ref: timeout_ref}

        # Store execution state
        new_state = %{
          state
          | executing_steps: Map.put(state.executing_steps, correlation_id, execution_state)
        }

        Logger.debug("Started async execution for step #{step_id} in saga #{saga_id}")
        {:reply, {:ok, correlation_id}, new_state}

      {:error, reason} ->
        Logger.error("Failed to send execution request to client: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_execution_status, correlation_id}, _from, state) do
    case Map.get(state.executing_steps, correlation_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      execution_state ->
        status = %{
          saga_id: execution_state.saga_id,
          step_id: execution_state.step_id,
          correlation_id: correlation_id,
          start_time: execution_state.start_time,
          elapsed_ms: DateTime.diff(DateTime.utc_now(), execution_state.start_time, :millisecond),
          timeout_ms: execution_state.timeout_ms,
          metadata: execution_state.metadata
        }

        {:reply, {:ok, status}, state}
    end
  end

  @impl true
  def handle_call(:list_executing_steps, _from, state) do
    executing_steps =
      state.executing_steps
      |> Enum.map(fn {correlation_id, execution_state} ->
        %{
          correlation_id: correlation_id,
          saga_id: execution_state.saga_id,
          step_id: execution_state.step_id,
          start_time: execution_state.start_time,
          elapsed_ms: DateTime.diff(DateTime.utc_now(), execution_state.start_time, :millisecond),
          timeout_ms: execution_state.timeout_ms
        }
      end)

    {:reply, executing_steps, state}
  end

  @impl true
  def handle_call(:get_statistics, _from, state) do
    current_executions = map_size(state.executing_steps)

    stats =
      Map.merge(state.execution_stats, %{
        current_executions: current_executions,
        oldest_execution: get_oldest_execution(state.executing_steps)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:step_completed, correlation_id, result}, state) do
    case Map.get(state.executing_steps, correlation_id) do
      nil ->
        Logger.warning("Received completion for unknown correlation_id: #{correlation_id}")
        {:noreply, state}

      execution_state ->
        # Calculate execution time
        execution_time_ms =
          DateTime.diff(DateTime.utc_now(), execution_state.start_time, :millisecond)

        # Cancel timeout
        if execution_state.timeout_ref do
          Process.cancel_timer(execution_state.timeout_ref)
        end

        # Notify callback
        notify_callback(execution_state, {:completed, result, execution_time_ms})

        # Update statistics
        new_stats = update_stats(state.execution_stats, :success, execution_time_ms)

        # Remove from executing steps
        new_state = %{
          state
          | executing_steps: Map.delete(state.executing_steps, correlation_id),
            execution_stats: new_stats
        }

        Logger.debug("Step #{execution_state.step_id} completed in #{execution_time_ms}ms")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:step_failed, correlation_id, error}, state) do
    case Map.get(state.executing_steps, correlation_id) do
      nil ->
        Logger.warning("Received failure for unknown correlation_id: #{correlation_id}")
        {:noreply, state}

      execution_state ->
        # Calculate execution time
        execution_time_ms =
          DateTime.diff(DateTime.utc_now(), execution_state.start_time, :millisecond)

        # Cancel timeout
        if execution_state.timeout_ref do
          Process.cancel_timer(execution_state.timeout_ref)
        end

        # Notify callback
        notify_callback(execution_state, {:failed, error, execution_time_ms})

        # Update statistics
        new_stats = update_stats(state.execution_stats, :failure, execution_time_ms)

        # Remove from executing steps
        new_state = %{
          state
          | executing_steps: Map.delete(state.executing_steps, correlation_id),
            execution_stats: new_stats
        }

        Logger.debug("Step #{execution_state.step_id} failed after #{execution_time_ms}ms")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:cancel_step, correlation_id}, state) do
    case Map.get(state.executing_steps, correlation_id) do
      nil ->
        Logger.warning("Attempted to cancel unknown correlation_id: #{correlation_id}")
        {:noreply, state}

      execution_state ->
        # Cancel timeout
        if execution_state.timeout_ref do
          Process.cancel_timer(execution_state.timeout_ref)
        end

        # Send cancellation request to client (if supported)
        cancellation_message = %{
          type: "cancel_step",
          correlation_id: correlation_id,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        send_to_client(execution_state.client_pid, cancellation_message)

        # Notify callback about cancellation
        notify_callback(execution_state, {:cancelled, %{reason: "manual_cancellation"}})

        # Remove from executing steps
        new_state = %{state | executing_steps: Map.delete(state.executing_steps, correlation_id)}

        Logger.debug("Cancelled step #{execution_state.step_id}")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:execution_timeout, correlation_id}, state) do
    case Map.get(state.executing_steps, correlation_id) do
      nil ->
        # Timeout already handled or step completed
        {:noreply, state}

      execution_state ->
        # Calculate execution time
        execution_time_ms =
          DateTime.diff(DateTime.utc_now(), execution_state.start_time, :millisecond)

        # Create timeout error
        timeout_error = %{
          type: "timeout_error",
          message: "Step execution timed out after #{execution_time_ms}ms",
          code: "EXECUTION_TIMEOUT",
          details: %{
            timeout_ms: execution_state.timeout_ms,
            actual_execution_ms: execution_time_ms
          },
          retryable: true
        }

        # Notify callback about timeout
        notify_callback(execution_state, {:timeout, timeout_error, execution_time_ms})

        # Update statistics
        new_stats = update_stats(state.execution_stats, :timeout, execution_time_ms)

        # Remove from executing steps
        new_state = %{
          state
          | executing_steps: Map.delete(state.executing_steps, correlation_id),
            execution_stats: new_stats
        }

        Logger.warning("Step #{execution_state.step_id} timed out after #{execution_time_ms}ms")
        {:noreply, new_state}
    end
  end

  # Private functions

  defp send_to_client(client_pid, message) do
    try do
      send(client_pid, {:execute_step, message})
      :ok
    rescue
      error ->
        {:error, error}
    end
  end

  defp notify_callback(execution_state, result) do
    try do
      case execution_state.callback_module do
        Kawa.Core.SagaServer ->
          case result do
            {:completed, step_result, _execution_time} ->
              Kawa.Core.SagaServer.step_completed(
                execution_state.saga_id,
                execution_state.step_id,
                step_result
              )

            {:failed, error, _execution_time} ->
              Kawa.Core.SagaServer.step_failed(
                execution_state.saga_id,
                execution_state.step_id,
                error
              )

            {:timeout, error, _execution_time} ->
              Kawa.Core.SagaServer.step_failed(
                execution_state.saga_id,
                execution_state.step_id,
                error
              )

            {:cancelled, error} ->
              Kawa.Core.SagaServer.step_failed(
                execution_state.saga_id,
                execution_state.step_id,
                error
              )
          end

        custom_module ->
          send(execution_state.callback_pid, {custom_module, result})
      end
    rescue
      error ->
        Logger.error("Failed to notify callback: #{inspect(error)}")
    end
  end

  defp update_stats(stats, outcome, execution_time_ms) do
    total = stats.total_executions + 1

    {successful, failed, timeout} =
      case outcome do
        :success ->
          {stats.successful_executions + 1, stats.failed_executions, stats.timeout_executions}

        :failure ->
          {stats.successful_executions, stats.failed_executions + 1, stats.timeout_executions}

        :timeout ->
          {stats.successful_executions, stats.failed_executions, stats.timeout_executions + 1}
      end

    # Calculate new average execution time
    current_total_time = stats.average_execution_time_ms * stats.total_executions
    new_average = div(current_total_time + execution_time_ms, total)

    %{
      stats
      | total_executions: total,
        successful_executions: successful,
        failed_executions: failed,
        timeout_executions: timeout,
        average_execution_time_ms: new_average
    }
  end

  defp get_oldest_execution(executing_steps) when map_size(executing_steps) == 0, do: nil

  defp get_oldest_execution(executing_steps) do
    executing_steps
    |> Enum.min_by(fn {_id, execution_state} -> execution_state.start_time end)
    |> elem(1)
    |> then(fn execution_state ->
      %{
        correlation_id: execution_state.correlation_id,
        saga_id: execution_state.saga_id,
        step_id: execution_state.step_id,
        start_time: execution_state.start_time,
        elapsed_ms: DateTime.diff(DateTime.utc_now(), execution_state.start_time, :millisecond)
      }
    end)
  end
end
