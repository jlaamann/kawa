defmodule Kawa.SagaExecutionTest do
  use ExUnit.Case, async: false
  use Kawa.DataCase

  alias Kawa.{
    SagaServer,
    SagaSupervisor,
    StepDependencyResolver,
    StepStateMachine,
    StepExecutionProtocol,
    StepResultValidator,
    StepExecutionTracker
  }

  alias Kawa.Contexts.SagaContext

  alias Kawa.Schemas.{Saga, WorkflowDefinition, Client}

  @moduletag :integration

  setup do
    # Create test client
    client_attrs = %{
      name: "test-client",
      environment: "dev",
      capabilities: %{},
      connection_metadata: %{}
    }

    {:ok, client} =
      %Client{}
      |> Client.create_changeset(client_attrs)
      |> Repo.insert()

    # Create test workflow definition
    workflow_definition = %{
      "steps" => [
        %{
          "id" => "step1",
          "depends_on" => [],
          "timeout" => 5000,
          "input" => %{"action" => "initialize"},
          "result_schema" => %{
            "type" => "object",
            "required" => ["user_id"]
          }
        },
        %{
          "id" => "step2",
          "depends_on" => ["step1"],
          "timeout" => 3000,
          "input" => %{"action" => "process"},
          "result_schema" => %{
            "type" => "object",
            "required" => ["result"]
          }
        },
        %{
          "id" => "step3",
          "depends_on" => ["step1", "step2"],
          "timeout" => 2000,
          "input" => %{"action" => "finalize"}
        }
      ]
    }

    {:ok, workflow_def} =
      %WorkflowDefinition{}
      |> WorkflowDefinition.changeset(%{
        name: "test-workflow",
        version: "1.0.0",
        module_name: "TestWorkflow",
        definition: workflow_definition,
        definition_checksum: "test-checksum",
        client_id: client.id
      })
      |> Repo.insert()

    # Create test saga
    {:ok, saga} =
      %Saga{}
      |> Saga.create_changeset(%{
        correlation_id: "test-saga-#{System.unique_integer()}",
        workflow_definition_id: workflow_def.id,
        client_id: client.id,
        input: %{"initial_data" => "test"},
        context: %{}
      })
      |> Repo.insert()

    # Clean up any running sagas
    on_exit(fn ->
      try do
        if SagaSupervisor.saga_running?(saga.id) do
          SagaSupervisor.stop_saga(saga.id)
        end
      rescue
        _ -> :ok
      end

      # Clean up client registry entries
      try do
        Kawa.ClientRegistry.unregister_client(client.id)
      rescue
        _ -> :ok
      end
    end)

    {:ok,
     %{
       client: client,
       workflow_definition: workflow_def,
       saga: saga
     }}
  end

  describe "StepDependencyResolver" do
    test "resolves dependencies correctly" do
      steps = [
        %{"id" => "step1", "depends_on" => []},
        %{"id" => "step2", "depends_on" => ["step1"]},
        %{"id" => "step3", "depends_on" => ["step1", "step2"]}
      ]

      assert {:ok, ["step1", "step2", "step3"]} = StepDependencyResolver.topological_sort(steps)
    end

    test "detects circular dependencies" do
      steps = [
        %{"id" => "step1", "depends_on" => ["step2"]},
        %{"id" => "step2", "depends_on" => ["step1"]}
      ]

      assert {:error, :circular_dependency} = StepDependencyResolver.topological_sort(steps)
    end

    test "finds ready steps" do
      steps = [
        %{"id" => "step1", "depends_on" => []},
        %{"id" => "step2", "depends_on" => ["step1"]},
        %{"id" => "step3", "depends_on" => ["step1"]}
      ]

      completed = MapSet.new(["step1"])
      ready_steps = StepDependencyResolver.find_ready_to_execute_steps(steps, completed)

      assert "step2" in ready_steps
      assert "step3" in ready_steps
      refute "step1" in ready_steps
    end
  end

  describe "StepStateMachine" do
    test "validates valid state transitions" do
      assert :ok = StepStateMachine.validate_transition("pending", "running")
      assert :ok = StepStateMachine.validate_transition("running", "completed")
      assert :ok = StepStateMachine.validate_transition("running", "failed")
      assert :ok = StepStateMachine.validate_transition("completed", "compensating")
    end

    test "rejects invalid state transitions" do
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("pending", "completed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("completed", "running")
    end

    test "identifies terminal states" do
      assert StepStateMachine.is_terminal_state?("compensated")
      assert StepStateMachine.is_terminal_state?("skipped")
      refute StepStateMachine.is_terminal_state?("running")
    end
  end

  describe "SagaContext" do
    test "manages step results" do
      context = SagaContext.new()

      # Add step result
      context = SagaContext.add_step_result(context, "step1", %{user_id: 123})

      # Retrieve step result
      assert %{user_id: 123} = SagaContext.get_step_result(context, "step1")
      assert nil == SagaContext.get_step_result(context, "nonexistent")
    end

    test "builds step input from context and dependencies" do
      context = %{
        "step1" => %{user_id: 123, name: "Alice"}
      }

      step_definition = %{
        "input" => %{"action" => "process"},
        "depends_on" => ["step1"]
      }

      input = SagaContext.build_step_input(context, step_definition)

      # Should include base input and dependency data
      assert input["action"] == "process"
      assert input["step1_user_id"] == 123
      assert input["step1_name"] == "Alice"
    end
  end

  describe "StepExecutionProtocol" do
    test "creates valid execution request" do
      message =
        StepExecutionProtocol.create_execution_request(
          "saga-123",
          "step1",
          %{input: "data"},
          timeout_ms: 5000
        )

      assert message.type == "execute_step"
      assert message.saga_id == "saga-123"
      assert message.step_id == "step1"
      assert message.timeout_ms == 5000
      assert is_binary(message.correlation_id)
    end

    test "validates message format" do
      valid_message = %{
        "type" => "execute_step",
        "saga_id" => Ecto.UUID.generate(),
        "step_id" => "test_step",
        "input" => %{}
      }

      assert :ok = StepExecutionProtocol.validate_message(valid_message)

      invalid_message = %{
        "type" => "execute_step",
        "step_id" => "test_step"
        # Missing required saga_id
      }

      assert {:error, _} = StepExecutionProtocol.validate_message(invalid_message)
    end
  end

  describe "StepResultValidator" do
    test "validates step results against schema" do
      result = %{"user_id" => 123, "name" => "Alice"}

      schema = %{
        "type" => "object",
        "required" => ["user_id"]
      }

      assert :ok = StepResultValidator.validate_result(result, schema)

      invalid_result = %{"name" => "Alice"}
      assert {:error, _errors} = StepResultValidator.validate_result(invalid_result, schema)
    end

    test "validates error responses" do
      valid_error = %{
        "type" => "validation_error",
        "message" => "Invalid input",
        "retryable" => false
      }

      assert :ok = StepResultValidator.validate_error_response(valid_error)

      invalid_error = %{
        "message" => "Error occurred"
        # Missing required type field
      }

      assert {:error, _} = StepResultValidator.validate_error_response(invalid_error)
    end

    test "classifies errors as retryable or not" do
      timeout_error = %{"type" => "timeout_error", "message" => "Timed out"}
      assert {:retryable, _} = StepResultValidator.classify_error(timeout_error)

      validation_error = %{"type" => "validation_error", "message" => "Invalid data"}
      assert {:non_retryable, _} = StepResultValidator.classify_error(validation_error)
    end
  end

  describe "SagaSupervisor integration" do
    test "starts and manages saga processes", %{saga: saga} do
      # Start a saga process
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga.id)

      # Verify it's running
      assert SagaSupervisor.saga_running?(saga.id)

      # Get process info
      assert {:ok, pid} = SagaSupervisor.get_saga_pid(saga.id)
      assert Process.alive?(pid)

      # Stop the saga
      assert :ok = SagaSupervisor.stop_saga(saga.id)

      # Wait a bit for the process to terminate
      Process.sleep(50)
      refute SagaSupervisor.saga_running?(saga.id)
    end

    test "prevents duplicate saga processes", %{saga: saga} do
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga.id)
      assert {:error, :already_running} = SagaSupervisor.start_saga(saga.id)

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end
  end

  describe "SagaServer state management" do
    test "initializes with correct step states", %{saga: saga} do
      {:ok, _pid} = SagaSupervisor.start_saga(saga.id)

      # Get saga status
      status = SagaServer.get_status(saga.id)

      assert status.saga_id == saga.id
      assert status.status == "pending"
      assert "step1" in status.pending_steps
      assert "step2" in status.pending_steps
      assert "step3" in status.pending_steps
      assert status.running_steps == []
      assert status.completed_steps == []

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end
  end

  describe "Step execution flow" do
    test "executes steps in dependency order", %{saga: saga, client: client} do
      # Mock client process to receive step execution requests
      test_pid = self()

      # Register a mock client
      Kawa.ClientRegistry.register_client(client.id, test_pid)

      # Start saga
      {:ok, _pid} = SagaSupervisor.start_saga(saga.id)

      # Start execution
      SagaServer.start_execution(saga.id)

      # Should receive execution request for step1 first (no dependencies)
      assert_receive {:execute_step, message}, 1000
      assert message.step_id == "step1"
      assert message.saga_id == saga.id

      # Complete step1
      step1_result = %{"user_id" => 123}
      SagaServer.step_completed(saga.id, "step1", step1_result)

      # Should now receive requests for step2 (depends on step1)
      assert_receive {:execute_step, message2}, 1000
      assert message2.step_id == "step2"

      # Complete step2
      step2_result = %{"result" => "processed"}
      SagaServer.step_completed(saga.id, "step2", step2_result)

      # Should now receive request for step3 (depends on step1 and step2)
      assert_receive {:execute_step, message3}, 1000
      assert message3.step_id == "step3"

      # Complete step3
      step3_result = %{"final" => "done"}
      SagaServer.step_completed(saga.id, "step3", step3_result)

      # Verify saga is completed
      status = SagaServer.get_status(saga.id)
      assert status.status == "completed"

      assert MapSet.equal?(
               MapSet.new(status.completed_steps),
               MapSet.new(["step1", "step2", "step3"])
             )

      # Verify context contains all results
      context = status.context
      assert context["step1"] == step1_result
      assert context["step2"] == step2_result
      assert context["step3"] == step3_result

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end

    test "handles step failures and triggers compensation", %{saga: saga, client: client} do
      # Register mock client
      Kawa.ClientRegistry.register_client(client.id, self())

      # Start saga
      {:ok, _pid} = SagaSupervisor.start_saga(saga.id)
      SagaServer.start_execution(saga.id)

      # Receive and complete step1
      assert_receive {:execute_step, message1}, 1000
      assert message1.step_id == "step1"

      step1_result = %{"user_id" => 123}
      SagaServer.step_completed(saga.id, "step1", step1_result)

      # Receive step2 execution request
      assert_receive {:execute_step, message2}, 1000
      assert message2.step_id == "step2"

      # Fail step2
      error = %{
        "type" => "business_error",
        "message" => "Processing failed",
        "retryable" => false
      }

      SagaServer.step_failed(saga.id, "step2", error)

      # Verify saga enters compensating state
      status = SagaServer.get_status(saga.id)
      assert status.status in ["compensating", "compensated"]
      assert "step2" in status.failed_steps

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end
  end

  describe "Step execution tracking" do
    test "tracks step execution metrics" do
      saga_id = Ecto.UUID.generate()
      step_id = "test_step"

      # Track step start
      StepExecutionTracker.track_step_started(saga_id, step_id)

      # Verify it's in active executions
      active = StepExecutionTracker.get_active_executions()

      assert Enum.any?(active, fn exec ->
               exec.saga_id == saga_id && exec.step_id == step_id
             end)

      # Track completion
      StepExecutionTracker.track_step_completed(saga_id, step_id, 1500)

      # Verify it's no longer active
      active_after = StepExecutionTracker.get_active_executions()

      refute Enum.any?(active_after, fn exec ->
               exec.saga_id == saga_id && exec.step_id == step_id
             end)

      # Verify metrics were recorded
      {:ok, metrics} = StepExecutionTracker.get_step_metrics(saga_id, step_id)
      assert metrics.status == "completed"
      assert metrics.execution_time_ms == 1500
    end
  end

  describe "Error handling and validation" do
    test "validates step results before marking complete", %{saga: saga, client: client} do
      # Register mock client
      Kawa.ClientRegistry.register_client(client.id, self())

      # Start saga
      {:ok, _pid} = SagaSupervisor.start_saga(saga.id)
      SagaServer.start_execution(saga.id)

      # Receive step1 execution request
      assert_receive {:execute_step, _message}, 1000

      # Complete step1 with invalid result (missing required user_id)
      invalid_result = %{"name" => "Alice"}
      SagaServer.step_completed(saga.id, "step1", invalid_result)

      # Should be treated as step failure due to validation
      status = SagaServer.get_status(saga.id)
      assert "step1" in status.failed_steps

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end
  end
end
