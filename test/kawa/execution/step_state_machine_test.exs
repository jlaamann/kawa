defmodule Kawa.Execution.StepStateMachineTest do
  use ExUnit.Case, async: true
  alias Kawa.Execution.StepStateMachine
  alias Kawa.Execution.StepStateMachine.StateTransition

  describe "validate_transition/2" do
    test "allows valid transitions from pending" do
      assert :ok = StepStateMachine.validate_transition("pending", "running")
      assert :ok = StepStateMachine.validate_transition("pending", "skipped")
    end

    test "allows valid transitions from running" do
      assert :ok = StepStateMachine.validate_transition("running", "completed")
      assert :ok = StepStateMachine.validate_transition("running", "failed")
    end

    test "allows valid transitions from completed" do
      assert :ok = StepStateMachine.validate_transition("completed", "compensating")
    end

    test "allows valid transitions from failed" do
      assert :ok = StepStateMachine.validate_transition("failed", "compensating")
    end

    test "allows valid transitions from compensating" do
      assert :ok = StepStateMachine.validate_transition("compensating", "compensated")
      assert :ok = StepStateMachine.validate_transition("compensating", "failed")
    end

    test "rejects invalid transitions from pending" do
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("pending", "completed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("pending", "failed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("pending", "compensating")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("pending", "compensated")
    end

    test "rejects invalid transitions from running" do
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("running", "pending")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("running", "skipped")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("running", "compensating")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("running", "compensated")
    end

    test "rejects invalid transitions from completed" do
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("completed", "pending")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("completed", "running")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("completed", "failed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("completed", "skipped")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("completed", "compensated")
    end

    test "rejects invalid transitions from failed" do
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("failed", "pending")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("failed", "running")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("failed", "completed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("failed", "skipped")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("failed", "compensated")
    end

    test "rejects transitions from terminal states" do
      # compensated is terminal
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("compensated", "pending")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("compensated", "running")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("compensated", "completed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("compensated", "failed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("compensated", "compensating")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("compensated", "skipped")

      # skipped is terminal
      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("skipped", "pending")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("skipped", "running")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("skipped", "completed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("skipped", "failed")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("skipped", "compensating")

      assert {:error, :invalid_transition} =
               StepStateMachine.validate_transition("skipped", "compensated")
    end

    test "rejects transitions with invalid states" do
      assert {:error, {:invalid_state, "invalid_state"}} =
               StepStateMachine.validate_transition("invalid_state", "running")

      assert {:error, {:invalid_state, "invalid_target"}} =
               StepStateMachine.validate_transition("pending", "invalid_target")

      assert {:error, {:invalid_state, "bad_from"}} =
               StepStateMachine.validate_transition("bad_from", "bad_to")
    end

    test "rejects same state transitions" do
      assert {:error, :same_state} = StepStateMachine.validate_transition("pending", "pending")
      assert {:error, :same_state} = StepStateMachine.validate_transition("running", "running")

      assert {:error, :same_state} =
               StepStateMachine.validate_transition("completed", "completed")

      assert {:error, :same_state} = StepStateMachine.validate_transition("failed", "failed")

      assert {:error, :same_state} =
               StepStateMachine.validate_transition("compensating", "compensating")

      assert {:error, :same_state} =
               StepStateMachine.validate_transition("compensated", "compensated")

      assert {:error, :same_state} = StepStateMachine.validate_transition("skipped", "skipped")
    end
  end

  describe "create_transition/3" do
    test "creates valid transition with minimal options" do
      assert {:ok, transition} = StepStateMachine.create_transition("pending", "running")

      assert transition.from_state == "pending"
      assert transition.to_state == "running"
      assert %DateTime{} = transition.timestamp
      assert transition.reason == nil
      assert transition.metadata == %{}
    end

    test "creates valid transition with reason" do
      reason = "step_execution_started"

      assert {:ok, transition} =
               StepStateMachine.create_transition("pending", "running", reason: reason)

      assert transition.from_state == "pending"
      assert transition.to_state == "running"
      assert transition.reason == reason
      assert transition.metadata == %{}
    end

    test "creates valid transition with metadata" do
      metadata = %{"execution_id" => "exec_123", "client_id" => "client_456"}

      assert {:ok, transition} =
               StepStateMachine.create_transition("running", "completed", metadata: metadata)

      assert transition.from_state == "running"
      assert transition.to_state == "completed"
      assert transition.metadata == metadata
    end

    test "creates valid transition with both reason and metadata" do
      reason = "step_completed_successfully"
      metadata = %{"execution_time_ms" => 1500, "result" => %{"status" => "ok"}}

      assert {:ok, transition} =
               StepStateMachine.create_transition(
                 "running",
                 "completed",
                 reason: reason,
                 metadata: metadata
               )

      assert transition.from_state == "running"
      assert transition.to_state == "completed"
      assert transition.reason == reason
      assert transition.metadata == metadata
      assert %DateTime{} = transition.timestamp
    end

    test "rejects invalid transitions" do
      assert {:error, :invalid_transition} =
               StepStateMachine.create_transition("completed", "pending")

      assert {:error, :same_state} = StepStateMachine.create_transition("running", "running")

      assert {:error, {:invalid_state, "invalid"}} =
               StepStateMachine.create_transition("invalid", "running")
    end

    test "sets timestamp automatically" do
      before_transition = DateTime.utc_now()
      assert {:ok, transition} = StepStateMachine.create_transition("pending", "running")
      after_transition = DateTime.utc_now()

      assert DateTime.compare(transition.timestamp, before_transition) in [:gt, :eq]
      assert DateTime.compare(transition.timestamp, after_transition) in [:lt, :eq]
    end
  end

  describe "valid_next_states/1" do
    test "returns correct next states for pending" do
      assert StepStateMachine.valid_next_states("pending") == ["running", "skipped"]
    end

    test "returns correct next states for running" do
      assert StepStateMachine.valid_next_states("running") == ["completed", "failed"]
    end

    test "returns correct next states for completed" do
      assert StepStateMachine.valid_next_states("completed") == ["compensating"]
    end

    test "returns correct next states for failed" do
      assert StepStateMachine.valid_next_states("failed") == ["compensating"]
    end

    test "returns correct next states for compensating" do
      next_states = StepStateMachine.valid_next_states("compensating")
      assert Enum.sort(next_states) == ["compensated", "failed"]
    end

    test "returns empty list for terminal states" do
      assert StepStateMachine.valid_next_states("compensated") == []
      assert StepStateMachine.valid_next_states("skipped") == []
    end

    test "returns empty list for invalid states" do
      assert StepStateMachine.valid_next_states("invalid_state") == []
    end
  end

  describe "is_terminal_state?/1" do
    test "identifies terminal states correctly" do
      assert StepStateMachine.is_terminal_state?("compensated") == true
      assert StepStateMachine.is_terminal_state?("skipped") == true
    end

    test "identifies non-terminal states correctly" do
      assert StepStateMachine.is_terminal_state?("pending") == false
      assert StepStateMachine.is_terminal_state?("running") == false
      assert StepStateMachine.is_terminal_state?("completed") == false
      assert StepStateMachine.is_terminal_state?("failed") == false
      assert StepStateMachine.is_terminal_state?("compensating") == false
    end

    test "handles invalid states" do
      assert StepStateMachine.is_terminal_state?("invalid_state") == true
    end
  end

  describe "is_success_state?/1" do
    test "identifies success states correctly" do
      assert StepStateMachine.is_success_state?("completed") == true
      assert StepStateMachine.is_success_state?("compensated") == true
      assert StepStateMachine.is_success_state?("skipped") == true
    end

    test "identifies non-success states correctly" do
      assert StepStateMachine.is_success_state?("pending") == false
      assert StepStateMachine.is_success_state?("running") == false
      assert StepStateMachine.is_success_state?("failed") == false
      assert StepStateMachine.is_success_state?("compensating") == false
    end

    test "handles invalid states" do
      assert StepStateMachine.is_success_state?("invalid_state") == false
    end
  end

  describe "is_failure_state?/1" do
    test "identifies failure state correctly" do
      assert StepStateMachine.is_failure_state?("failed") == true
    end

    test "identifies non-failure states correctly" do
      assert StepStateMachine.is_failure_state?("pending") == false
      assert StepStateMachine.is_failure_state?("running") == false
      assert StepStateMachine.is_failure_state?("completed") == false
      assert StepStateMachine.is_failure_state?("compensating") == false
      assert StepStateMachine.is_failure_state?("compensated") == false
      assert StepStateMachine.is_failure_state?("skipped") == false
    end

    test "handles invalid states" do
      assert StepStateMachine.is_failure_state?("invalid_state") == false
    end
  end

  describe "is_active_state?/1" do
    test "identifies active states correctly" do
      assert StepStateMachine.is_active_state?("running") == true
      assert StepStateMachine.is_active_state?("compensating") == true
    end

    test "identifies non-active states correctly" do
      assert StepStateMachine.is_active_state?("pending") == false
      assert StepStateMachine.is_active_state?("completed") == false
      assert StepStateMachine.is_active_state?("failed") == false
      assert StepStateMachine.is_active_state?("compensated") == false
      assert StepStateMachine.is_active_state?("skipped") == false
    end

    test "handles invalid states" do
      assert StepStateMachine.is_active_state?("invalid_state") == false
    end
  end

  describe "get_compensation_state/1" do
    test "returns compensating for completed state" do
      assert StepStateMachine.get_compensation_state("completed") == "compensating"
    end

    test "returns compensating for failed state" do
      assert StepStateMachine.get_compensation_state("failed") == "compensating"
    end

    test "returns nil for non-compensable states" do
      assert StepStateMachine.get_compensation_state("pending") == nil
      assert StepStateMachine.get_compensation_state("running") == nil
      assert StepStateMachine.get_compensation_state("compensating") == nil
      assert StepStateMachine.get_compensation_state("compensated") == nil
      assert StepStateMachine.get_compensation_state("skipped") == nil
    end

    test "handles invalid states" do
      assert StepStateMachine.get_compensation_state("invalid_state") == nil
    end
  end

  describe "get_transition_path/1" do
    test "returns successful execution path" do
      path = StepStateMachine.get_transition_path(:successful_execution)

      assert path == [
               {"pending", "running"},
               {"running", "completed"}
             ]
    end

    test "returns failed execution path" do
      path = StepStateMachine.get_transition_path(:failed_execution)

      assert path == [
               {"pending", "running"},
               {"running", "failed"}
             ]
    end

    test "returns successful compensation path" do
      path = StepStateMachine.get_transition_path(:successful_compensation)

      assert path == [
               {"completed", "compensating"},
               {"compensating", "compensated"}
             ]
    end

    test "returns failed compensation path" do
      path = StepStateMachine.get_transition_path(:failed_compensation)

      assert path == [
               {"completed", "compensating"},
               {"compensating", "failed"}
             ]
    end

    test "returns skip execution path" do
      path = StepStateMachine.get_transition_path(:skip_execution)

      assert path == [
               {"pending", "skipped"}
             ]
    end

    test "returns full saga rollback path" do
      path = StepStateMachine.get_transition_path(:full_saga_rollback)

      assert path == [
               {"completed", "compensating"},
               {"compensating", "compensated"}
             ]
    end

    test "returns empty list for unknown scenarios" do
      assert StepStateMachine.get_transition_path(:unknown_scenario) == []
      assert StepStateMachine.get_transition_path("invalid") == []
      assert StepStateMachine.get_transition_path(nil) == []
    end
  end

  describe "validate_transition_sequence/1" do
    test "validates successful execution sequence" do
      transitions = [
        {"pending", "running"},
        {"running", "completed"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)
    end

    test "validates successful execution with compensation sequence" do
      transitions = [
        {"pending", "running"},
        {"running", "completed"},
        {"completed", "compensating"},
        {"compensating", "compensated"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)
    end

    test "validates failed execution sequence" do
      transitions = [
        {"pending", "running"},
        {"running", "failed"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)
    end

    test "validates failed execution with compensation sequence" do
      transitions = [
        {"pending", "running"},
        {"running", "failed"},
        {"failed", "compensating"},
        {"compensating", "compensated"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)
    end

    test "validates skip execution sequence" do
      transitions = [
        {"pending", "skipped"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)
    end

    test "validates failed compensation sequence" do
      transitions = [
        {"pending", "running"},
        {"running", "completed"},
        {"completed", "compensating"},
        {"compensating", "failed"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)
    end

    test "rejects sequence with invalid transition" do
      transitions = [
        {"pending", "running"},
        # Invalid: can't go back to pending
        {"running", "pending"}
      ]

      assert {:error, {:invalid_transition, 1, {"running", "pending"}}} =
               StepStateMachine.validate_transition_sequence(transitions)
    end

    test "rejects sequence with invalid state" do
      transitions = [
        {"pending", "running"},
        # Invalid state
        {"running", "invalid_state"}
      ]

      assert {:error, {{:invalid_state, "invalid_state"}, 1, {"running", "invalid_state"}}} =
               StepStateMachine.validate_transition_sequence(transitions)
    end

    test "rejects sequence with same state transition" do
      transitions = [
        {"pending", "running"},
        # Same state
        {"running", "running"}
      ]

      assert {:error, {:same_state, 1, {"running", "running"}}} =
               StepStateMachine.validate_transition_sequence(transitions)
    end

    test "handles empty transition sequence" do
      assert :ok = StepStateMachine.validate_transition_sequence([])
    end

    test "identifies first invalid transition in sequence" do
      transitions = [
        # Valid
        {"pending", "running"},
        # Invalid - this should be caught
        {"running", "pending"},
        # Also invalid but won't be reached
        {"pending", "completed"}
      ]

      assert {:error, {:invalid_transition, 1, {"running", "pending"}}} =
               StepStateMachine.validate_transition_sequence(transitions)
    end
  end

  describe "StateTransition struct" do
    test "has correct fields" do
      transition = %StateTransition{}

      assert Map.has_key?(transition, :from_state)
      assert Map.has_key?(transition, :to_state)
      assert Map.has_key?(transition, :timestamp)
      assert Map.has_key?(transition, :reason)
      assert Map.has_key?(transition, :metadata)
    end

    test "can be created with all fields" do
      timestamp = DateTime.utc_now()
      reason = "test_reason"
      metadata = %{"test" => "data"}

      transition = %StateTransition{
        from_state: "pending",
        to_state: "running",
        timestamp: timestamp,
        reason: reason,
        metadata: metadata
      }

      assert transition.from_state == "pending"
      assert transition.to_state == "running"
      assert transition.timestamp == timestamp
      assert transition.reason == reason
      assert transition.metadata == metadata
    end
  end

  describe "comprehensive workflow scenarios" do
    test "complete successful saga execution with compensation" do
      # Simulate a complete saga step lifecycle
      transitions = [
        # Start execution
        {"pending", "running"},
        # Complete successfully
        {"running", "completed"},
        # Start compensation due to saga failure
        {"completed", "compensating"},
        # Complete compensation
        {"compensating", "compensated"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)

      # Verify state checks throughout the lifecycle
      assert StepStateMachine.is_active_state?("running") == true
      assert StepStateMachine.is_success_state?("completed") == true
      assert StepStateMachine.is_active_state?("compensating") == true
      assert StepStateMachine.is_success_state?("compensated") == true
      assert StepStateMachine.is_terminal_state?("compensated") == true
    end

    test "failed execution with failed compensation" do
      transitions = [
        # Start execution
        {"pending", "running"},
        # Execution fails
        {"running", "failed"},
        # Start compensation
        {"failed", "compensating"},
        # Compensation also fails
        {"compensating", "failed"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)

      # Verify state checks
      assert StepStateMachine.is_failure_state?("failed") == true
      assert StepStateMachine.is_active_state?("compensating") == true
      # Note: failed compensation results in "failed" state, which is terminal
      assert StepStateMachine.valid_next_states("failed") == ["compensating"]
    end

    test "step skipped scenario" do
      transitions = [
        # Step skipped due to conditional logic
        {"pending", "skipped"}
      ]

      assert :ok = StepStateMachine.validate_transition_sequence(transitions)

      # Verify state checks
      assert StepStateMachine.is_success_state?("skipped") == true
      assert StepStateMachine.is_terminal_state?("skipped") == true
    end

    test "invalid complex scenario" do
      transitions = [
        # Valid
        {"pending", "running"},
        # Valid
        {"running", "completed"},
        # Invalid: can't go back to running
        {"completed", "running"}
      ]

      assert {:error, {:invalid_transition, 2, {"completed", "running"}}} =
               StepStateMachine.validate_transition_sequence(transitions)
    end
  end

  describe "edge cases and error handling" do
    test "handles nil states" do
      assert {:error, {:invalid_state, nil}} =
               StepStateMachine.validate_transition(nil, "running")

      assert {:error, {:invalid_state, nil}} =
               StepStateMachine.validate_transition("pending", nil)
    end

    test "handles empty string states" do
      assert {:error, {:invalid_state, ""}} = StepStateMachine.validate_transition("", "running")
      assert {:error, {:invalid_state, ""}} = StepStateMachine.validate_transition("pending", "")
    end

    test "handles atom states (should be strings)" do
      assert {:error, {:invalid_state, :pending}} =
               StepStateMachine.validate_transition(:pending, "running")

      assert {:error, {:invalid_state, :running}} =
               StepStateMachine.validate_transition("pending", :running)
    end

    test "create_transition handles all error cases" do
      # Invalid from state
      assert {:error, {:invalid_state, "invalid"}} =
               StepStateMachine.create_transition("invalid", "running")

      # Invalid to state
      assert {:error, {:invalid_state, "invalid"}} =
               StepStateMachine.create_transition("pending", "invalid")

      # Same state
      assert {:error, :same_state} =
               StepStateMachine.create_transition("pending", "pending")

      # Invalid transition
      assert {:error, :invalid_transition} =
               StepStateMachine.create_transition("completed", "pending")
    end
  end
end
