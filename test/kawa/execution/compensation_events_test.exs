defmodule Kawa.Execution.CompensationEventsTest do
  use Kawa.DataCase, async: true
  alias Kawa.Execution.CompensationEngine
  alias Kawa.Schemas.{Saga, SagaStep, SagaEvent, Client, WorkflowDefinition}
  alias Kawa.Repo

  describe "compensation request events" do
    test "creates compensation_requested event when sending compensation request" do
      # Create test saga and steps
      {:ok, saga} = create_test_saga()
      {:ok, step1} = create_test_step(saga, "step1", "completed")
      {:ok, step2} = create_test_step(saga, "step2", "completed")

      # Start compensation
      {:ok, _result} = CompensationEngine.start_compensation(saga.id)

      # Check that compensation_requested events were created
      compensation_requested_events =
        from(e in SagaEvent,
          where: e.saga_id == ^saga.id and e.event_type == "step_compensation_requested",
          order_by: [asc: e.sequence_number]
        )
        |> Repo.all()

      assert length(compensation_requested_events) == 2

      # Verify event details
      [event1, event2] = compensation_requested_events
      # step2 compensated first
      assert event1.step_id == step2.step_id
      # step1 compensated second
      assert event2.step_id == step1.step_id
      assert event1.event_type == "step_compensation_requested"
      assert event2.event_type == "step_compensation_requested"
    end
  end

  describe "compensation response events via WebSocket" do
    setup do
      # Create test saga and step
      {:ok, saga} = create_test_saga()
      {:ok, step} = create_test_step(saga, "validate_payment", "compensating")

      %{saga: saga, step: step}
    end

    test "creates compensation_completed event when client reports success", %{
      saga: saga,
      step: step
    } do
      # Simulate compensation completion response
      payload = %{
        "saga_id" => saga.id,
        "step_id" => step.step_id,
        "result" => %{
          "refund_id" => "REF_123456",
          "refund_amount" => 99.99,
          "status" => "completed"
        }
      }

      # Create compensation response event for testing
      result =
        create_compensation_response_event(
          saga.id,
          step.step_id,
          "compensation_completed",
          payload["result"]
        )

      assert {:ok, _event} = result

      # Verify event was created
      event =
        from(e in SagaEvent,
          where:
            e.saga_id == ^saga.id and e.step_id == ^step.step_id and
              e.event_type == "step_compensation_completed"
        )
        |> Repo.one()

      assert event
      assert event.event_type == "step_compensation_completed"
      assert event.payload["compensation_result"] == payload["result"]
      assert Map.has_key?(event.payload, "received_at")
    end

    test "creates compensation_failed event when client reports failure", %{
      saga: saga,
      step: step
    } do
      # Simulate compensation failure response
      error_details = %{
        "type" => "refund_failed",
        "message" => "Payment gateway unavailable",
        "code" => "GATEWAY_ERROR",
        "retryable" => true
      }

      payload = %{
        "saga_id" => saga.id,
        "step_id" => step.step_id,
        "error" => error_details
      }

      # Create compensation response event for testing
      result =
        create_compensation_response_event(
          saga.id,
          step.step_id,
          "compensation_failed",
          error_details
        )

      assert {:ok, _event} = result

      # Verify event was created
      event =
        from(e in SagaEvent,
          where:
            e.saga_id == ^saga.id and e.step_id == ^step.step_id and
              e.event_type == "step_compensation_failed"
        )
        |> Repo.one()

      assert event
      assert event.event_type == "step_compensation_failed"
      assert event.payload["compensation_result"] == error_details
      assert Map.has_key?(event.payload, "received_at")
    end
  end

  describe "compensation event sequencing" do
    test "events maintain proper chronological order throughout compensation process" do
      # Create test saga with multiple steps
      {:ok, saga} = create_test_saga()
      {:ok, step1} = create_test_step(saga, "validate_payment", "completed")
      {:ok, step2} = create_test_step(saga, "charge_card", "completed")
      {:ok, step3} = create_test_step(saga, "update_inventory", "completed")

      # Start compensation (this will create compensation_requested events)
      {:ok, _result} = CompensationEngine.start_compensation(saga.id)

      # Simulate client responses (these create compensation response events)
      # Compensation happens in reverse order: step3, step2, step1
      {:ok, _} =
        create_compensation_response_event(
          saga.id,
          step3.step_id,
          "compensation_completed",
          %{"status" => "compensated"}
        )

      {:ok, _} =
        create_compensation_response_event(
          saga.id,
          step2.step_id,
          "compensation_completed",
          %{"refund_id" => "REF_789"}
        )

      {:ok, _} =
        create_compensation_response_event(
          saga.id,
          step1.step_id,
          "compensation_completed",
          %{"validation_cleared" => true}
        )

      # Get all compensation events in chronological order
      compensation_events =
        from(e in SagaEvent,
          where:
            e.saga_id == ^saga.id and
              e.event_type in [
                "step_compensation_requested",
                "step_compensation_completed",
                "step_compensation_failed"
              ],
          order_by: [asc: e.sequence_number]
        )
        |> Repo.all()

      # Should have 6 events total: 3 requests + 3 completions
      assert length(compensation_events) == 6

      # Verify proper sequence: requests come before their corresponding completions
      event_types = Enum.map(compensation_events, &{&1.step_id, &1.event_type})

      # Should see pattern like:
      # [{step3, requested}, {step2, requested}, {step1, requested}, 
      #  {step3, completed}, {step2, completed}, {step1, completed}]

      requested_events =
        Enum.filter(compensation_events, &(&1.event_type == "step_compensation_requested"))

      completed_events =
        Enum.filter(compensation_events, &(&1.event_type == "step_compensation_completed"))

      assert length(requested_events) == 3
      assert length(completed_events) == 3

      # All request events should have lower sequence numbers than completion events
      max_request_seq = requested_events |> Enum.map(& &1.sequence_number) |> Enum.max()
      min_completion_seq = completed_events |> Enum.map(& &1.sequence_number) |> Enum.min()

      assert max_request_seq < min_completion_seq
    end
  end

  describe "legacy compensation format support" do
    test "creates events for legacy compensation_result messages" do
      # Create test saga and step
      {:ok, saga} = create_test_saga()
      {:ok, step} = create_test_step(saga, "charge_card", "compensating")

      # Test legacy success format
      result =
        create_compensation_response_event(
          saga.id,
          step.step_id,
          "compensation_completed",
          %{"transaction_id" => "TXN_123", "status" => "refunded"}
        )

      assert {:ok, _event} = result

      # Verify event was created with correct type
      event =
        from(e in SagaEvent,
          where:
            e.saga_id == ^saga.id and e.step_id == ^step.step_id and
              e.event_type == "step_compensation_completed"
        )
        |> Repo.one()

      assert event
      assert event.event_type == "step_compensation_completed"
    end
  end

  # Helper functions
  defp create_test_saga do
    # Create test client
    {:ok, client} = create_test_client()

    # Create test workflow definition  
    {:ok, workflow} = create_test_workflow(client)

    saga_attrs = %{
      correlation_id: "test_" <> Ecto.UUID.generate(),
      status: "compensating",
      input: %{"amount" => 100.0},
      context: %{"test" => true},
      workflow_definition_id: workflow.id,
      client_id: client.id
    }

    %Saga{}
    |> Saga.create_changeset(saga_attrs)
    |> Repo.insert()
  end

  defp create_test_client do
    client_attrs = %{
      name: "test-client-" <> String.slice(Ecto.UUID.generate(), 0, 8),
      environment: "dev",
      status: "connected"
    }

    %Client{}
    |> Client.create_changeset(client_attrs)
    |> Repo.insert()
  end

  defp create_test_workflow(client) do
    definition = %{
      "name" => "test_workflow",
      "steps" => [
        %{"id" => "step1", "type" => "action"},
        %{"id" => "step2", "type" => "action"}
      ]
    }

    # Generate checksum
    definition_json = Jason.encode!(definition)
    checksum = :crypto.hash(:sha256, definition_json) |> Base.encode16(case: :lower)

    workflow_attrs = %{
      name: "test_workflow",
      version: "1.0.0",
      module_name: "TestWorkflow",
      definition: definition,
      definition_checksum: checksum,
      client_id: client.id,
      is_active: true
    }

    %WorkflowDefinition{}
    |> WorkflowDefinition.changeset(workflow_attrs)
    |> Repo.insert()
  end

  defp create_test_step(saga, step_id, status \\ "pending") do
    step_attrs = %{
      saga_id: saga.id,
      step_id: step_id,
      step_type: "action",
      status: status,
      execution_metadata: %{
        "step_definition" => %{"id" => step_id, "type" => "elixir"},
        "compensation" => %{"available" => true}
      },
      retry_count: 0
    }

    %SagaStep{}
    |> SagaStep.changeset(step_attrs)
    |> Repo.insert()
  end

  # Helper function to create compensation response events for testing
  defp create_compensation_response_event(saga_id, step_id, result_type, result_or_error) do
    event_type =
      case result_type do
        "compensation_completed" -> "step_compensation_completed"
        "compensation_failed" -> "step_compensation_failed"
      end

    event_data = %{
      saga_id: saga_id,
      step_id: step_id,
      event_type: event_type,
      payload: %{
        compensation_result: result_or_error,
        received_at: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    # Use atomic sequence generation to avoid race conditions
    Kawa.Utils.SequenceGenerator.create_saga_event_with_sequence(event_data)
  end
end
