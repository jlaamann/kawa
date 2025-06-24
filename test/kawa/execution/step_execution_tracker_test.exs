defmodule Kawa.Execution.StepExecutionTrackerTest do
  use ExUnit.Case, async: true
  alias Kawa.Execution.StepExecutionTracker
  alias Kawa.Execution.StepExecutionTracker.{ExecutionMetrics, State}

  setup do
    # Start a test tracker for each test
    {:ok, tracker_pid} =
      start_supervised({StepExecutionTracker, name: :"tracker_#{System.unique_integer()}"})

    %{tracker: tracker_pid}
  end

  describe "initialization" do
    test "starts with empty state", %{tracker: tracker} do
      state = :sys.get_state(tracker)
      assert state.active_executions == %{}
      assert state.execution_history == []
      assert state.performance_metrics.total_executions == 0
      assert state.error_patterns == %{}
    end

    test "initializes with correct performance metrics structure", %{tracker: tracker} do
      state = :sys.get_state(tracker)
      metrics = state.performance_metrics

      assert metrics.total_executions == 0
      assert metrics.successful_executions == 0
      assert metrics.failed_executions == 0
      assert metrics.average_execution_time_ms == 0
      assert metrics.fastest_execution_ms == nil
      assert metrics.slowest_execution_ms == nil
    end
  end

  describe "step lifecycle tracking" do
    test "tracks step start correctly", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"
      correlation_id = "corr-789"

      GenServer.cast(tracker, {:step_started, saga_id, step_id, correlation_id})
      # Allow cast to process
      Process.sleep(10)

      state = :sys.get_state(tracker)
      execution_key = "#{saga_id}:#{step_id}"

      assert Map.has_key?(state.active_executions, execution_key)
      metrics = state.active_executions[execution_key]

      assert metrics.saga_id == saga_id
      assert metrics.step_id == step_id
      assert metrics.status == "running"
      assert metrics.correlation_id == correlation_id
      assert metrics.started_at != nil
      assert metrics.completed_at == nil
      assert metrics.execution_time_ms == nil
      assert metrics.retry_count == 0
      assert metrics.error_details == %{}
    end

    test "tracks step completion correctly", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"
      execution_time = 1500

      # Start step first
      GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
      Process.sleep(10)

      # Complete step
      GenServer.cast(tracker, {:step_completed, saga_id, step_id, execution_time})
      Process.sleep(10)

      state = :sys.get_state(tracker)
      execution_key = "#{saga_id}:#{step_id}"

      # Should be removed from active executions
      refute Map.has_key?(state.active_executions, execution_key)

      # Should be in history
      assert length(state.execution_history) == 1
      [metrics] = state.execution_history

      assert metrics.saga_id == saga_id
      assert metrics.step_id == step_id
      assert metrics.status == "completed"
      assert metrics.execution_time_ms == execution_time
      assert metrics.completed_at != nil

      # Performance metrics should be updated
      perf = state.performance_metrics
      assert perf.total_executions == 1
      assert perf.successful_executions == 1
      assert perf.failed_executions == 0
      assert perf.fastest_execution_ms == execution_time
      assert perf.slowest_execution_ms == execution_time
    end

    test "tracks step failure correctly", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"
      execution_time = 800
      error = %{"type" => "timeout", "code" => "STEP_TIMEOUT", "message" => "Step timed out"}

      # Start step first
      GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
      Process.sleep(10)

      # Fail step
      GenServer.cast(tracker, {:step_failed, saga_id, step_id, error, execution_time})
      Process.sleep(10)

      state = :sys.get_state(tracker)
      execution_key = "#{saga_id}:#{step_id}"

      # Should be removed from active executions
      refute Map.has_key?(state.active_executions, execution_key)

      # Should be in history
      assert length(state.execution_history) == 1
      [metrics] = state.execution_history

      assert metrics.saga_id == saga_id
      assert metrics.step_id == step_id
      assert metrics.status == "failed"
      assert metrics.execution_time_ms == execution_time
      assert metrics.error_details == error
      assert metrics.completed_at != nil

      # Performance metrics should be updated
      perf = state.performance_metrics
      assert perf.total_executions == 1
      assert perf.successful_executions == 0
      assert perf.failed_executions == 1

      # Error patterns should be updated
      assert state.error_patterns[{:type, "timeout"}] == 1
      assert state.error_patterns[{:code, "STEP_TIMEOUT"}] == 1
    end

    test "calculates execution time when not provided", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"

      # Start step
      GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
      # Wait a bit
      Process.sleep(50)

      # Complete without explicit execution time
      GenServer.cast(tracker, {:step_completed, saga_id, step_id, nil})
      Process.sleep(10)

      state = :sys.get_state(tracker)
      [metrics] = state.execution_history

      # Should have calculated execution time
      assert metrics.execution_time_ms != nil
      # Should be at least the sleep time
      assert metrics.execution_time_ms >= 40
    end

    test "handles completion of non-existent step gracefully", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"

      # Try to complete step that was never started
      GenServer.cast(tracker, {:step_completed, saga_id, step_id, 100})
      Process.sleep(10)

      state = :sys.get_state(tracker)

      # Should not add anything to history
      assert state.execution_history == []
      assert state.performance_metrics.total_executions == 0
    end

    test "handles failure of non-existent step gracefully", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"
      error = %{"type" => "test_error"}

      # Try to fail step that was never started
      GenServer.cast(tracker, {:step_failed, saga_id, step_id, error, 100})
      Process.sleep(10)

      state = :sys.get_state(tracker)

      # Should not add anything to history or error patterns
      assert state.execution_history == []
      assert state.error_patterns == %{}
      assert state.performance_metrics.total_executions == 0
    end
  end

  describe "API functions" do
    test "get_step_metrics returns active step metrics", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"
      correlation_id = "corr-789"

      GenServer.cast(tracker, {:step_started, saga_id, step_id, correlation_id})
      Process.sleep(10)

      {:ok, metrics} = GenServer.call(tracker, {:get_step_metrics, saga_id, step_id})

      assert metrics.saga_id == saga_id
      assert metrics.step_id == step_id
      assert metrics.status == "running"
      assert metrics.correlation_id == correlation_id
    end

    test "get_step_metrics returns historical metrics", %{tracker: tracker} do
      saga_id = "saga-123"
      step_id = "step-456"

      # Start and complete step
      GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, saga_id, step_id, 100})
      Process.sleep(10)

      {:ok, metrics} = GenServer.call(tracker, {:get_step_metrics, saga_id, step_id})

      assert metrics.saga_id == saga_id
      assert metrics.step_id == step_id
      assert metrics.status == "completed"
      assert metrics.execution_time_ms == 100
    end

    test "get_step_metrics returns error for non-existent step", %{tracker: tracker} do
      result = GenServer.call(tracker, {:get_step_metrics, "non-existent", "step"})
      assert result == {:error, :not_found}
    end

    test "get_active_executions returns all active steps", %{tracker: tracker} do
      # Start multiple steps
      GenServer.cast(tracker, {:step_started, "saga-1", "step-1", "corr-1"})
      GenServer.cast(tracker, {:step_started, "saga-2", "step-2", "corr-2"})
      Process.sleep(10)

      active_executions = GenServer.call(tracker, :get_active_executions)

      assert length(active_executions) == 2

      # Check that all required fields are present
      Enum.each(active_executions, fn execution ->
        assert Map.has_key?(execution, :saga_id)
        assert Map.has_key?(execution, :step_id)
        assert Map.has_key?(execution, :status)
        assert Map.has_key?(execution, :started_at)
        assert Map.has_key?(execution, :running_time_ms)
        assert Map.has_key?(execution, :correlation_id)
        assert execution.status == "running"
        assert execution.running_time_ms >= 0
      end)
    end

    test "get_performance_stats returns comprehensive statistics", %{tracker: tracker} do
      # Execute some steps to generate statistics
      GenServer.cast(tracker, {:step_started, "saga-1", "step-1", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, "saga-1", "step-1", 100})

      GenServer.cast(tracker, {:step_started, "saga-2", "step-2", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-2", "step-2", %{"type" => "error"}, 200})

      GenServer.cast(tracker, {:step_started, "saga-3", "step-3", nil})
      Process.sleep(20)

      stats = GenServer.call(tracker, :get_performance_stats)

      assert stats.total_executions == 2
      assert stats.successful_executions == 1
      assert stats.failed_executions == 1
      assert stats.active_executions_count == 1
      assert stats.recent_executions_count == 2
      assert stats.fastest_execution_ms == 100
      assert stats.slowest_execution_ms == 200
      assert stats.error_rate == 0.5
      assert Map.has_key?(stats, :longest_running_step)
      assert Map.has_key?(stats, :timestamp)
    end

    test "get_error_analysis returns error patterns and analysis", %{tracker: tracker} do
      # Generate some errors
      error1 = %{"type" => "timeout", "code" => "STEP_TIMEOUT"}
      error2 = %{"type" => "validation", "code" => "INVALID_INPUT"}
      error3 = %{"type" => "timeout", "code" => "NETWORK_TIMEOUT"}

      GenServer.cast(tracker, {:step_started, "saga-1", "step-1", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-1", "step-1", error1, 100})

      GenServer.cast(tracker, {:step_started, "saga-2", "step-2", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-2", "step-2", error2, 150})

      GenServer.cast(tracker, {:step_started, "saga-3", "step-3", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-3", "step-3", error3, 200})
      Process.sleep(10)

      analysis = GenServer.call(tracker, :get_error_analysis)

      assert Map.has_key?(analysis, :error_patterns)
      assert Map.has_key?(analysis, :recent_errors)
      assert Map.has_key?(analysis, :error_distribution)
      assert Map.has_key?(analysis, :most_common_errors)

      # Check error patterns
      assert analysis.error_patterns[{:type, "timeout"}] == 2
      assert analysis.error_patterns[{:type, "validation"}] == 1
      assert analysis.error_patterns[{:code, "STEP_TIMEOUT"}] == 1

      # Check recent errors
      assert length(analysis.recent_errors) == 3

      # Check error distribution
      assert analysis.error_distribution["timeout"] == 2 / 3
      assert analysis.error_distribution["validation"] == 1 / 3

      # Check most common errors
      assert Enum.any?(analysis.most_common_errors, fn {type, count} ->
               type == "timeout" && count == 2
             end)
    end

    test "get_saga_timeline returns timeline for specific saga", %{tracker: tracker} do
      saga_id = "saga-123"

      # Execute multiple steps for the saga
      GenServer.cast(tracker, {:step_started, saga_id, "step-1", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, saga_id, "step-1", 100})

      GenServer.cast(tracker, {:step_started, saga_id, "step-2", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, saga_id, "step-2", %{"type" => "error"}, 150})

      GenServer.cast(tracker, {:step_started, saga_id, "step-3", nil})
      Process.sleep(20)

      timeline = GenServer.call(tracker, {:get_saga_timeline, saga_id})

      assert length(timeline) == 3

      # Check that all timeline entries have required fields
      Enum.each(timeline, fn entry ->
        assert Map.has_key?(entry, :step_id)
        assert Map.has_key?(entry, :status)
        assert Map.has_key?(entry, :started_at)
        assert Map.has_key?(entry, :completed_at)
        assert Map.has_key?(entry, :execution_time_ms)
        assert Map.has_key?(entry, :error_details)
      end)

      # Check specific entries
      step_1_entry = Enum.find(timeline, fn entry -> entry.step_id == "step-1" end)
      assert step_1_entry.status == "completed"
      assert step_1_entry.execution_time_ms == 100

      step_2_entry = Enum.find(timeline, fn entry -> entry.step_id == "step-2" end)
      assert step_2_entry.status == "failed"
      assert step_2_entry.execution_time_ms == 150

      step_3_entry = Enum.find(timeline, fn entry -> entry.step_id == "step-3" end)
      assert step_3_entry.status == "running"
      assert step_3_entry.completed_at == nil
    end

    test "search_executions filters by criteria", %{tracker: tracker} do
      # Create diverse executions
      GenServer.cast(tracker, {:step_started, "saga-1", "validate", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, "saga-1", "validate", 50})

      GenServer.cast(tracker, {:step_started, "saga-2", "process", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, "saga-2", "process", 200})

      GenServer.cast(tracker, {:step_started, "saga-3", "validate", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-3", "validate", %{"type" => "validation"}, 75})
      Process.sleep(10)

      # Search by step_id
      results = GenServer.call(tracker, {:search_executions, [step_id: "validate"]})
      assert length(results) == 2
      assert Enum.all?(results, fn metrics -> metrics.step_id == "validate" end)

      # Search by status
      results = GenServer.call(tracker, {:search_executions, [status: "completed"]})
      assert length(results) == 2
      assert Enum.all?(results, fn metrics -> metrics.status == "completed" end)

      # Search by execution time range
      results = GenServer.call(tracker, {:search_executions, [min_execution_time: 100]})
      assert length(results) == 1
      assert hd(results).execution_time_ms == 200

      # Search by multiple criteria
      results =
        GenServer.call(tracker, {:search_executions, [step_id: "validate", status: "failed"]})

      assert length(results) == 1
      assert hd(results).step_id == "validate"
      assert hd(results).status == "failed"

      # Search by error type
      results = GenServer.call(tracker, {:search_executions, [error_type: "validation"]})
      assert length(results) == 1
      assert hd(results).error_details["type"] == "validation"
    end
  end

  describe "performance metrics calculations" do
    test "calculates average execution time correctly", %{tracker: tracker} do
      # Execute steps with different times
      execution_times = [100, 200, 300, 400, 500]
      expected_average = div(Enum.sum(execution_times), length(execution_times))

      Enum.with_index(execution_times, fn time, index ->
        saga_id = "saga-#{index}"
        step_id = "step-#{index}"

        GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
        Process.sleep(10)
        GenServer.cast(tracker, {:step_completed, saga_id, step_id, time})
      end)

      Process.sleep(10)

      stats = GenServer.call(tracker, :get_performance_stats)

      assert stats.total_executions == 5
      assert stats.successful_executions == 5
      assert stats.failed_executions == 0
      assert stats.average_execution_time_ms == expected_average
      assert stats.fastest_execution_ms == 100
      assert stats.slowest_execution_ms == 500
    end

    test "tracks error rate correctly", %{tracker: tracker} do
      # Execute 3 successful and 2 failed steps
      GenServer.cast(tracker, {:step_started, "saga-1", "step-1", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, "saga-1", "step-1", 100})

      GenServer.cast(tracker, {:step_started, "saga-2", "step-2", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, "saga-2", "step-2", 150})

      GenServer.cast(tracker, {:step_started, "saga-3", "step-3", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_completed, "saga-3", "step-3", 200})

      GenServer.cast(tracker, {:step_started, "saga-4", "step-4", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-4", "step-4", %{"type" => "error1"}, 50})

      GenServer.cast(tracker, {:step_started, "saga-5", "step-5", nil})
      Process.sleep(10)
      GenServer.cast(tracker, {:step_failed, "saga-5", "step-5", %{"type" => "error2"}, 75})
      Process.sleep(10)

      stats = GenServer.call(tracker, :get_performance_stats)

      assert stats.total_executions == 5
      assert stats.successful_executions == 3
      assert stats.failed_executions == 2
      # 40% error rate
      assert stats.error_rate == 2 / 5
    end

    test "handles empty metrics correctly", %{tracker: tracker} do
      stats = GenServer.call(tracker, :get_performance_stats)

      assert stats.total_executions == 0
      assert stats.successful_executions == 0
      assert stats.failed_executions == 0
      assert stats.average_execution_time_ms == 0
      assert stats.fastest_execution_ms == nil
      assert stats.slowest_execution_ms == nil
      assert stats.error_rate == 0.0
      assert stats.active_executions_count == 0
      assert stats.recent_executions_count == 0
      assert stats.longest_running_step == nil
    end
  end

  describe "execution history management" do
    test "limits execution history to 100 entries", %{tracker: tracker} do
      # Execute 105 steps to test history limit
      Enum.each(1..105, fn index ->
        saga_id = "saga-#{index}"
        step_id = "step-#{index}"

        GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
        Process.sleep(1)
        GenServer.cast(tracker, {:step_completed, saga_id, step_id, 100})
      end)

      Process.sleep(20)

      state = :sys.get_state(tracker)

      # Should keep only the most recent 100 executions
      assert length(state.execution_history) == 100

      # Performance metrics should still track all executions
      assert state.performance_metrics.total_executions == 105
    end

    test "maintains execution history in correct order", %{tracker: tracker} do
      # Execute steps in sequence
      step_ids = ["first", "second", "third"]

      Enum.each(step_ids, fn step_id ->
        GenServer.cast(tracker, {:step_started, "saga", step_id, nil})
        Process.sleep(10)
        GenServer.cast(tracker, {:step_completed, "saga", step_id, 100})
      end)

      Process.sleep(10)

      state = :sys.get_state(tracker)

      # History should be in reverse chronological order (most recent first)
      [first, second, third] = state.execution_history

      assert first.step_id == "third"
      assert second.step_id == "second"
      assert third.step_id == "first"
    end
  end

  describe "concurrent execution handling" do
    test "tracks multiple concurrent executions", %{tracker: tracker} do
      # Start multiple steps concurrently
      saga_steps = [
        {"saga-1", "step-1"},
        {"saga-1", "step-2"},
        {"saga-2", "step-1"},
        {"saga-3", "step-1"}
      ]

      Enum.each(saga_steps, fn {saga_id, step_id} ->
        GenServer.cast(tracker, {:step_started, saga_id, step_id, nil})
      end)

      Process.sleep(10)

      active_executions = GenServer.call(tracker, :get_active_executions)
      assert length(active_executions) == 4

      # Complete some and fail others
      GenServer.cast(tracker, {:step_completed, "saga-1", "step-1", 100})
      GenServer.cast(tracker, {:step_failed, "saga-1", "step-2", %{"type" => "error"}, 150})
      Process.sleep(10)

      active_executions = GenServer.call(tracker, :get_active_executions)
      assert length(active_executions) == 2

      state = :sys.get_state(tracker)
      assert length(state.execution_history) == 2
    end

    test "handles same step in different sagas", %{tracker: tracker} do
      step_id = "common_step"

      # Start same step in different sagas
      GenServer.cast(tracker, {:step_started, "saga-1", step_id, nil})
      GenServer.cast(tracker, {:step_started, "saga-2", step_id, nil})
      GenServer.cast(tracker, {:step_started, "saga-3", step_id, nil})
      Process.sleep(10)

      active_executions = GenServer.call(tracker, :get_active_executions)
      assert length(active_executions) == 3

      # All should be the same step_id but different saga_ids
      step_ids = Enum.map(active_executions, & &1.step_id)
      saga_ids = Enum.map(active_executions, & &1.saga_id)

      assert Enum.all?(step_ids, fn id -> id == step_id end)
      assert Enum.sort(saga_ids) == ["saga-1", "saga-2", "saga-3"]
    end
  end

  describe "module state structures" do
    test "ExecutionMetrics struct has correct fields" do
      metrics = %ExecutionMetrics{}

      assert Map.has_key?(metrics, :step_id)
      assert Map.has_key?(metrics, :saga_id)
      assert Map.has_key?(metrics, :status)
      assert Map.has_key?(metrics, :started_at)
      assert Map.has_key?(metrics, :completed_at)
      assert Map.has_key?(metrics, :execution_time_ms)
      assert Map.has_key?(metrics, :retry_count)
      assert Map.has_key?(metrics, :error_details)
      assert Map.has_key?(metrics, :correlation_id)
    end

    test "State struct has correct fields" do
      state = %State{}

      assert Map.has_key?(state, :active_executions)
      assert Map.has_key?(state, :execution_history)
      assert Map.has_key?(state, :performance_metrics)
      assert Map.has_key?(state, :error_patterns)
    end
  end
end
