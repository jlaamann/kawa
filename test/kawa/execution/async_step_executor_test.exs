defmodule Kawa.Execution.AsyncStepExecutorTest do
  use ExUnit.Case, async: true
  alias Kawa.Execution.AsyncStepExecutor
  alias Kawa.Execution.AsyncStepExecutor.{ExecutionState, State}

  setup do
    # Start a test executor for each test
    {:ok, executor_pid} =
      start_supervised({AsyncStepExecutor, name: :"executor_#{System.unique_integer()}"})

    %{executor: executor_pid}
  end

  describe "initialization" do
    test "starts with empty state", %{executor: executor} do
      state = :sys.get_state(executor)
      assert state.executing_steps == %{}
      assert state.execution_stats.total_executions == 0
      assert state.execution_stats.successful_executions == 0
      assert state.execution_stats.failed_executions == 0
      assert state.execution_stats.timeout_executions == 0
      assert state.execution_stats.average_execution_time_ms == 0
    end

    test "initializes with correct statistics structure", %{executor: executor} do
      stats = GenServer.call(executor, :get_statistics)

      assert stats.total_executions == 0
      assert stats.successful_executions == 0
      assert stats.failed_executions == 0
      assert stats.timeout_executions == 0
      assert stats.average_execution_time_ms == 0
      assert stats.current_executions == 0
      assert stats.oldest_execution == nil
    end
  end

  describe "async step execution" do
    test "starts execution successfully", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()

      # Call the real GenServer method directly
      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          []
        })

      assert {:ok, correlation_id} = result
      assert is_binary(correlation_id)

      # Verify execution state was stored
      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:ok, execution_status} = status
      assert execution_status.saga_id == saga_id
      assert execution_status.step_id == step_id
      assert execution_status.correlation_id == correlation_id
      # default timeout
      assert execution_status.timeout_ms == 60_000
    end

    test "accepts custom correlation_id", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      custom_correlation_id = "custom-corr-123"

      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [correlation_id: custom_correlation_id]
        })

      assert {:ok, ^custom_correlation_id} = result
    end

    test "accepts custom timeout", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      custom_timeout = 30_000

      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [timeout_ms: custom_timeout]
        })

      assert {:ok, correlation_id} = result

      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:ok, execution_status} = status
      assert execution_status.timeout_ms == custom_timeout
    end

    test "accepts custom callback module", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      custom_module = CustomCallbackModule

      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [callback_module: custom_module]
        })

      assert {:ok, correlation_id} = result

      # Check that execution was stored with custom callback module
      state = :sys.get_state(executor)
      execution_state = Map.get(state.executing_steps, correlation_id)
      assert execution_state.callback_module == custom_module
    end

    test "accepts metadata", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      metadata = %{"custom_field" => "value", "priority" => "high"}

      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [metadata: metadata]
        })

      assert {:ok, correlation_id} = result

      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:ok, execution_status} = status
      assert execution_status.metadata == metadata
    end

    test "sends execution message to client", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      custom_correlation_id = "test-correlation-123"

      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [correlation_id: custom_correlation_id]
        })

      assert {:ok, correlation_id} = result
      assert correlation_id == custom_correlation_id

      # Check that we received the execution message
      assert_receive {:execute_step, message}
      assert message.saga_id == saga_id
      assert message.step_id == step_id
      # Note: StepExecutionProtocol.create_execution_request generates its own correlation_id
      # The message will have the protocol's correlation_id, not necessarily our custom one
      assert is_binary(message.correlation_id)
      assert message.input == input
    end
  end

  describe "step completion" do
    setup %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          []
        })

      # Clear the execute_step message from the mailbox
      receive do
        {:execute_step, _} -> :ok
      end

      %{correlation_id: correlation_id, saga_id: saga_id, step_id: step_id}
    end

    test "handles step completion correctly", %{
      executor: executor,
      correlation_id: correlation_id
    } do
      result = %{"output" => "success"}

      GenServer.cast(executor, {:step_completed, correlation_id, result})
      # Allow cast to process
      Process.sleep(10)

      # Verify execution was removed from active executions
      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:error, :not_found} = status

      # Verify statistics were updated
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 1
      assert stats.successful_executions == 1
      assert stats.failed_executions == 0
      assert stats.current_executions == 0
    end

    test "handles completion for non-existent correlation_id gracefully", %{executor: executor} do
      result = %{"output" => "success"}

      # This should not crash the server
      GenServer.cast(executor, {:step_completed, "non-existent", result})
      Process.sleep(10)

      # Verify nothing changed
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 0
    end
  end

  describe "step failure" do
    setup %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          []
        })

      # Clear the execute_step message from the mailbox
      receive do
        {:execute_step, _} -> :ok
      end

      %{correlation_id: correlation_id, saga_id: saga_id, step_id: step_id}
    end

    test "handles step failure correctly", %{executor: executor, correlation_id: correlation_id} do
      error = %{"type" => "validation_error", "message" => "Invalid input"}

      GenServer.cast(executor, {:step_failed, correlation_id, error})
      Process.sleep(10)

      # Verify execution was removed from active executions
      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:error, :not_found} = status

      # Verify statistics were updated
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 1
      assert stats.successful_executions == 0
      assert stats.failed_executions == 1
      assert stats.current_executions == 0
    end

    test "handles failure for non-existent correlation_id gracefully", %{executor: executor} do
      error = %{"type" => "test_error"}

      GenServer.cast(executor, {:step_failed, "non-existent", error})
      Process.sleep(10)

      # Verify nothing changed
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 0
    end
  end

  describe "step cancellation" do
    setup %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          []
        })

      # Clear the execute_step message from the mailbox
      receive do
        {:execute_step, _} -> :ok
      end

      %{correlation_id: correlation_id, saga_id: saga_id, step_id: step_id}
    end

    test "cancels step execution", %{executor: executor, correlation_id: correlation_id} do
      GenServer.cast(executor, {:cancel_step, correlation_id})
      Process.sleep(10)

      # Verify execution was removed from active executions
      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:error, :not_found} = status

      # Verify cancellation message was sent to client
      assert_receive {:execute_step, message}
      assert message.correlation_id == correlation_id
      assert message.type == "cancel_step"
    end

    test "handles cancellation of non-existent step gracefully", %{executor: executor} do
      GenServer.cast(executor, {:cancel_step, "non-existent"})
      Process.sleep(10)

      # Should not crash and no messages should be sent
      refute_receive _
    end
  end

  describe "timeout handling" do
    test "handles execution timeout", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      # 50ms timeout
      short_timeout = 50

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [timeout_ms: short_timeout]
        })

      # Clear the execute_step message
      receive do
        {:execute_step, _} -> :ok
      end

      # Wait for timeout
      Process.sleep(100)

      # Verify execution was removed due to timeout
      status = GenServer.call(executor, {:get_execution_status, correlation_id})
      assert {:error, :not_found} = status

      # Verify timeout statistics were updated
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 1
      assert stats.successful_executions == 0
      assert stats.failed_executions == 0
      assert stats.timeout_executions == 1
    end

    test "timeout is cancelled on successful completion", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      # 1 second
      timeout = 1000

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [timeout_ms: timeout]
        })

      # Clear the execute_step message
      receive do
        {:execute_step, _} -> :ok
      end

      # Complete the step before timeout
      result = %{"output" => "success"}
      GenServer.cast(executor, {:step_completed, correlation_id, result})
      Process.sleep(10)

      # Wait beyond the timeout period
      Process.sleep(1100)

      # Verify only completion was recorded, not timeout
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 1
      assert stats.successful_executions == 1
      assert stats.timeout_executions == 0
    end
  end

  describe "execution status queries" do
    test "returns execution status for active execution", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()
      timeout = 30_000
      metadata = %{"priority" => "high"}

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          [timeout_ms: timeout, metadata: metadata]
        })

      # Clear the execute_step message
      receive do
        {:execute_step, _} -> :ok
      end

      # Get status
      {:ok, status} = GenServer.call(executor, {:get_execution_status, correlation_id})

      assert status.saga_id == saga_id
      assert status.step_id == step_id
      assert status.correlation_id == correlation_id
      assert status.timeout_ms == timeout
      assert status.metadata == metadata
      assert is_struct(status.start_time, DateTime)
      assert status.elapsed_ms >= 0
    end

    test "returns error for non-existent execution", %{executor: executor} do
      result = GenServer.call(executor, {:get_execution_status, "non-existent"})
      assert {:error, :not_found} = result
    end
  end

  describe "list executing steps" do
    test "returns empty list when no executions", %{executor: executor} do
      result = GenServer.call(executor, :list_executing_steps)
      assert result == []
    end

    test "returns list of executing steps", %{executor: executor} do
      saga_id_1 = "saga-123"
      step_id_1 = "step-456"
      saga_id_2 = "saga-789"
      step_id_2 = "step-012"
      input = %{"data" => "test"}
      client_pid = self()

      # Start two executions
      {:ok, correlation_id_1} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id_1,
          step_id_1,
          input,
          client_pid,
          []
        })

      {:ok, correlation_id_2} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id_2,
          step_id_2,
          input,
          client_pid,
          []
        })

      # Clear the execute_step messages
      receive do
        {:execute_step, _} -> :ok
      end

      receive do
        {:execute_step, _} -> :ok
      end

      # Get executing steps
      executing_steps = GenServer.call(executor, :list_executing_steps)

      assert length(executing_steps) == 2
      correlation_ids = Enum.map(executing_steps, & &1.correlation_id)
      assert correlation_id_1 in correlation_ids
      assert correlation_id_2 in correlation_ids

      # Verify structure of returned data
      first_step = hd(executing_steps)
      assert Map.has_key?(first_step, :correlation_id)
      assert Map.has_key?(first_step, :saga_id)
      assert Map.has_key?(first_step, :step_id)
      assert Map.has_key?(first_step, :start_time)
      assert Map.has_key?(first_step, :elapsed_ms)
      assert Map.has_key?(first_step, :timeout_ms)
    end
  end

  describe "statistics" do
    test "tracks execution statistics correctly", %{executor: executor} do
      saga_id = "saga-123"
      input = %{"data" => "test"}
      client_pid = self()

      # Execute 3 successful steps
      successful_correlations =
        for i <- 1..3 do
          {:ok, correlation_id} =
            GenServer.call(executor, {
              :execute_step_async,
              saga_id,
              "step-#{i}",
              input,
              client_pid,
              []
            })

          # Clear message
          receive do
            {:execute_step, _} -> :ok
          end

          correlation_id
        end

      # Execute 2 failed steps
      failed_correlations =
        for i <- 4..5 do
          {:ok, correlation_id} =
            GenServer.call(executor, {
              :execute_step_async,
              saga_id,
              "step-#{i}",
              input,
              client_pid,
              []
            })

          # Clear message
          receive do
            {:execute_step, _} -> :ok
          end

          correlation_id
        end

      # Execute 1 step that will timeout
      {:ok, _timeout_correlation} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          "step-timeout",
          input,
          client_pid,
          [timeout_ms: 50]
        })

      # Clear message
      receive do
        {:execute_step, _} -> :ok
      end

      # Complete successful steps
      Enum.each(successful_correlations, fn correlation_id ->
        GenServer.cast(executor, {:step_completed, correlation_id, %{"result" => "success"}})
      end)

      # Fail the failed steps
      Enum.each(failed_correlations, fn correlation_id ->
        GenServer.cast(executor, {:step_failed, correlation_id, %{"error" => "failure"}})
      end)

      # Allow casts to process
      Process.sleep(10)

      # Wait for timeout
      Process.sleep(100)

      # Get final statistics
      stats = GenServer.call(executor, :get_statistics)

      assert stats.total_executions == 6
      assert stats.successful_executions == 3
      assert stats.failed_executions == 2
      assert stats.timeout_executions == 1
      assert stats.current_executions == 0
      assert stats.average_execution_time_ms >= 0
    end

    test "tracks oldest execution", %{executor: executor} do
      saga_id = "saga-123"
      input = %{"data" => "test"}
      client_pid = self()

      # Start first execution
      {:ok, correlation_id_1} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          "step-1",
          input,
          client_pid,
          []
        })

      # Clear message
      receive do
        {:execute_step, _} -> :ok
      end

      # Small delay
      Process.sleep(10)

      # Start second execution  
      {:ok, _correlation_id_2} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          "step-2",
          input,
          client_pid,
          []
        })

      # Clear message
      receive do
        {:execute_step, _} -> :ok
      end

      # Get statistics
      stats = GenServer.call(executor, :get_statistics)

      assert stats.current_executions == 2
      assert stats.oldest_execution != nil
      assert stats.oldest_execution.correlation_id == correlation_id_1
      assert stats.oldest_execution.step_id == "step-1"
      assert stats.oldest_execution.elapsed_ms >= 0
    end

    test "returns nil for oldest execution when no executions", %{executor: executor} do
      stats = GenServer.call(executor, :get_statistics)
      assert stats.oldest_execution == nil
    end

    test "calculates average execution time correctly", %{executor: executor} do
      saga_id = "saga-123"
      input = %{"data" => "test"}
      client_pid = self()

      # Start multiple executions with known timing
      correlations =
        for i <- 1..3 do
          {:ok, correlation_id} =
            GenServer.call(executor, {
              :execute_step_async,
              saga_id,
              "step-#{i}",
              input,
              client_pid,
              []
            })

          # Clear message
          receive do
            {:execute_step, _} -> :ok
          end

          correlation_id
        end

      # Complete them in sequence to control timing
      Process.sleep(10)

      GenServer.cast(
        executor,
        {:step_completed, Enum.at(correlations, 0), %{"result" => "success"}}
      )

      Process.sleep(10)

      GenServer.cast(
        executor,
        {:step_completed, Enum.at(correlations, 1), %{"result" => "success"}}
      )

      Process.sleep(10)

      GenServer.cast(
        executor,
        {:step_completed, Enum.at(correlations, 2), %{"result" => "success"}}
      )

      Process.sleep(10)

      # Get statistics
      stats = GenServer.call(executor, :get_statistics)

      assert stats.total_executions == 3
      assert stats.successful_executions == 3
      assert stats.average_execution_time_ms > 0
    end
  end

  describe "module state structures" do
    test "ExecutionState struct has correct fields" do
      state = %ExecutionState{}

      assert Map.has_key?(state, :saga_id)
      assert Map.has_key?(state, :step_id)
      assert Map.has_key?(state, :client_pid)
      assert Map.has_key?(state, :correlation_id)
      assert Map.has_key?(state, :start_time)
      assert Map.has_key?(state, :timeout_ms)
      assert Map.has_key?(state, :timeout_ref)
      assert Map.has_key?(state, :callback_module)
      assert Map.has_key?(state, :callback_pid)
      assert Map.has_key?(state, :metadata)
    end

    test "State struct has correct fields" do
      state = %State{}

      assert Map.has_key?(state, :executing_steps)
      assert Map.has_key?(state, :execution_stats)
    end
  end

  describe "error handling" do
    test "handles client send failure gracefully", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}

      # Use an atom as pid which will cause send to fail
      invalid_pid = :not_a_pid

      result =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          invalid_pid,
          []
        })

      # Should return error rather than crash
      assert {:error, _reason} = result
    end

    test "handles message to dead client gracefully during cancellation", %{executor: executor} do
      saga_id = "saga-123"
      step_id = "step-456"
      input = %{"data" => "test"}
      client_pid = self()

      {:ok, correlation_id} =
        GenServer.call(executor, {
          :execute_step_async,
          saga_id,
          step_id,
          input,
          client_pid,
          []
        })

      # Clear message
      receive do
        {:execute_step, _} -> :ok
      end

      # Mock a dead client by updating the state directly
      state = :sys.get_state(executor)
      dead_pid = spawn(fn -> :ok end)
      # Let it die
      Process.sleep(10)

      execution_state = Map.get(state.executing_steps, correlation_id)
      updated_execution_state = %{execution_state | client_pid: dead_pid}

      updated_state = %{
        state
        | executing_steps: Map.put(state.executing_steps, correlation_id, updated_execution_state)
      }

      :sys.replace_state(executor, fn _ -> updated_state end)

      # Cancellation should not crash the server
      GenServer.cast(executor, {:cancel_step, correlation_id})
      Process.sleep(10)

      # Server should still be alive
      assert Process.alive?(executor)
    end
  end

  describe "concurrent execution" do
    test "handles multiple concurrent executions", %{executor: executor} do
      saga_id = "saga-123"
      input = %{"data" => "test"}
      client_pid = self()

      # Start 5 concurrent executions
      correlations =
        for i <- 1..5 do
          {:ok, correlation_id} =
            GenServer.call(executor, {
              :execute_step_async,
              saga_id,
              "step-#{i}",
              input,
              client_pid,
              []
            })

          correlation_id
        end

      # Clear all messages
      for _ <- 1..5 do
        receive do
          {:execute_step, _} -> :ok
        end
      end

      # Verify all are executing
      executing_steps = GenServer.call(executor, :list_executing_steps)
      assert length(executing_steps) == 5

      # Complete them all
      Enum.each(correlations, fn correlation_id ->
        GenServer.cast(executor, {:step_completed, correlation_id, %{"result" => "success"}})
      end)

      Process.sleep(10)

      # Verify all completed
      executing_steps = GenServer.call(executor, :list_executing_steps)
      assert length(executing_steps) == 0

      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 5
      assert stats.successful_executions == 5
    end

    test "handles mixed outcomes for concurrent executions", %{executor: executor} do
      saga_id = "saga-123"
      input = %{"data" => "test"}
      client_pid = self()

      # Start 6 executions - 2 success, 2 failure, 2 timeout
      all_correlations =
        for i <- 1..6 do
          timeout_ms = if i > 4, do: 50, else: 30_000

          {:ok, correlation_id} =
            GenServer.call(executor, {
              :execute_step_async,
              saga_id,
              "step-#{i}",
              input,
              client_pid,
              [timeout_ms: timeout_ms]
            })

          correlation_id
        end

      # Clear all messages
      for _ <- 1..6 do
        receive do
          {:execute_step, _} -> :ok
        end
      end

      [success_1, success_2, fail_1, fail_2, _timeout_1, _timeout_2] = all_correlations

      # Complete successes
      GenServer.cast(executor, {:step_completed, success_1, %{"result" => "success"}})
      GenServer.cast(executor, {:step_completed, success_2, %{"result" => "success"}})

      # Fail failures
      GenServer.cast(executor, {:step_failed, fail_1, %{"error" => "failure"}})
      GenServer.cast(executor, {:step_failed, fail_2, %{"error" => "failure"}})

      Process.sleep(10)

      # Wait for timeouts
      Process.sleep(100)

      # Verify final statistics
      stats = GenServer.call(executor, :get_statistics)
      assert stats.total_executions == 6
      assert stats.successful_executions == 2
      assert stats.failed_executions == 2
      assert stats.timeout_executions == 2
      assert stats.current_executions == 0
    end
  end
end
