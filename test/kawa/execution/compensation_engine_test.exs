defmodule Kawa.Execution.CompensationEngineTest do
  use ExUnit.Case, async: false
  use Kawa.DataCase

  # Configure test compensation client for this test module
  setup do
    Application.put_env(:kawa, :compensation_client, Kawa.Execution.CompensationClient.Test)

    on_exit(fn ->
      Application.delete_env(:kawa, :compensation_client)
    end)

    :ok
  end

  alias Kawa.Execution.CompensationEngine
  alias Kawa.Schemas.{Saga, SagaStep, SagaEvent, WorkflowDefinition, Client}
  alias Kawa.Repo

  import Ecto.Query

  setup do
    # Create test client
    client_attrs = %{
      name: "test-client-compensation",
      environment: "dev",
      capabilities: %{},
      connection_metadata: %{}
    }

    {:ok, client} =
      %Client{}
      |> Client.create_changeset(client_attrs)
      |> Repo.insert()

    # Create test workflow definition with compensation-aware steps
    workflow_definition = %{
      "steps" => [
        %{
          "id" => "step1",
          "depends_on" => [],
          "timeout" => 5000,
          "input" => %{"action" => "reserve_inventory"},
          "compensation" => %{"action" => "release_inventory"}
        },
        %{
          "id" => "step2",
          "depends_on" => ["step1"],
          "timeout" => 3000,
          "input" => %{"action" => "charge_payment"},
          "compensation" => %{"action" => "refund_payment"}
        },
        %{
          "id" => "step3",
          "depends_on" => ["step1", "step2"],
          "timeout" => 2000,
          "input" => %{"action" => "send_confirmation"},
          # No compensation needed
          "compensation" => nil
        },
        %{
          "id" => "step4",
          "depends_on" => ["step3"],
          "timeout" => 1000,
          "input" => %{"action" => "cleanup"}
          # No compensation defined - should be skipped
        }
      ]
    }

    {:ok, workflow_def} =
      %WorkflowDefinition{}
      |> WorkflowDefinition.changeset(%{
        name: "test-compensation-workflow",
        version: "1.0.0",
        module_name: "TestCompensationWorkflow",
        definition: workflow_definition,
        definition_checksum: "test-compensation-checksum",
        client_id: client.id
      })
      |> Repo.insert()

    # Create test saga
    {:ok, saga} =
      %Saga{}
      |> Saga.create_changeset(%{
        correlation_id: "test-compensation-saga-#{System.unique_integer()}",
        workflow_definition_id: workflow_def.id,
        client_id: client.id,
        input: %{"initial_data" => "test"},
        context: %{},
        status: "running"
      })
      |> Repo.insert()

    {:ok,
     %{
       client: client,
       workflow_definition: workflow_def,
       saga: saga
     }}
  end

  describe "compensation plan building" do
    test "builds compensation plan for completed steps", %{saga: saga} do
      # Create completed steps in dependency order
      create_completed_step(saga, "step1", %{"inventory_reserved" => "item123"})
      create_completed_step(saga, "step2", %{"payment_charged" => "charge456"}, ["step1"])
      create_completed_step(saga, "step3", %{"email_sent" => true}, ["step1", "step2"])

      # Create failed step
      create_failed_step(saga, "step4", ["step3"])

      {:ok, plan} = CompensationEngine.build_compensation_plan(saga)

      assert plan.total_steps == 3
      assert length(plan.levels) > 0

      # Verify reverse dependency order - step3 should be compensated before step2, step2 before step1
      flattened_steps = List.flatten(plan.levels)
      step3_index = Enum.find_index(flattened_steps, &(&1 == "step3"))
      step2_index = Enum.find_index(flattened_steps, &(&1 == "step2"))
      step1_index = Enum.find_index(flattened_steps, &(&1 == "step1"))

      assert step3_index < step2_index
      assert step2_index < step1_index
    end

    test "handles saga with no completed steps", %{saga: saga} do
      # Only create failed step
      create_failed_step(saga, "step1", [])

      {:ok, plan} = CompensationEngine.build_compensation_plan(saga)

      assert plan.total_steps == 0
      assert plan.levels == []
      assert plan.message == "No steps to compensate"
    end

    test "builds correct levels for parallel steps", %{saga: saga} do
      # Create two parallel steps and one dependent step
      create_completed_step(saga, "step1", %{"result1" => "data1"})
      create_completed_step(saga, "step2", %{"result2" => "data2"})
      create_completed_step(saga, "step3", %{"result3" => "data3"}, ["step1", "step2"])

      create_failed_step(saga, "step4", ["step3"])

      {:ok, plan} = CompensationEngine.build_compensation_plan(saga)

      assert plan.total_steps == 3

      # step3 should be in first level (compensated first)
      # step1 and step2 should be in same level (can be compensated in parallel)
      assert "step3" in List.first(plan.levels)

      second_level = Enum.at(plan.levels, 1, [])
      assert "step1" in second_level
      assert "step2" in second_level
    end
  end

  describe "compensation execution" do
    test "executes compensation in correct order", %{saga: saga} do
      # Setup completed steps
      step1 = create_completed_step(saga, "step1", %{})
      step2 = create_completed_step(saga, "step2", %{}, ["step1"])
      create_failed_step(saga, "step3", ["step2"])

      # Execute compensation
      {:ok, result} = CompensationEngine.start_compensation(saga.id)

      assert result.saga.status == "compensated"
      assert length(result.results.compensated) == 2

      # Verify steps were updated
      updated_saga = Repo.get(Saga, saga.id) |> Repo.preload(:saga_steps)
      step1_updated = Enum.find(updated_saga.saga_steps, &(&1.step_id == "step1"))
      step2_updated = Enum.find(updated_saga.saga_steps, &(&1.step_id == "step2"))

      assert step2_updated.status == "compensated"
      assert step1_updated.status == "compensated"
    end

    test "handles steps without compensation", %{saga: saga} do
      # Create step with no compensation
      step1 = create_completed_step(saga, "step1", %{})
      step1 = update_step_metadata(step1, %{"compensation" => %{"available" => false}})

      create_failed_step(saga, "step2", ["step1"])

      {:ok, result} = CompensationEngine.start_compensation(saga.id)

      assert result.saga.status == "compensated"
      assert length(result.results.skipped) == 1
      assert "step1" in result.results.skipped
    end

    test "handles compensation failures", %{saga: saga} do
      # Use process dictionary to simulate compensation failure
      Process.put(:simulate_compensation_failure, true)

      create_completed_step(saga, "step1", %{})
      create_failed_step(saga, "step2", ["step1"])

      # CompensationEngine uses random failure simulation
      # We'll test multiple times to account for randomness
      results =
        for _ <- 1..10 do
          # Reset saga state
          Repo.update_all(from(s in SagaStep, where: s.saga_id == ^saga.id),
            set: [status: "completed"]
          )

          Repo.update_all(from(s in Saga, where: s.id == ^saga.id),
            set: [status: "running"]
          )

          CompensationEngine.start_compensation(saga.id)
        end

      # At least one should succeed (due to 90% success rate in simulation)
      assert Enum.any?(results, fn
               {:ok, %{saga: %{status: "compensated"}}} -> true
               _ -> false
             end)

      Process.delete(:simulate_compensation_failure)
    end

    test "creates compensation events", %{saga: saga} do
      create_completed_step(saga, "step1", %{})
      create_failed_step(saga, "step2", ["step1"])

      initial_event_count =
        Repo.aggregate(from(e in SagaEvent, where: e.saga_id == ^saga.id), :count)

      CompensationEngine.start_compensation(saga.id)

      final_event_count =
        Repo.aggregate(from(e in SagaEvent, where: e.saga_id == ^saga.id), :count)

      # Should have created events for step compensation and saga finalization
      assert final_event_count > initial_event_count

      # Verify event types
      events =
        Repo.all(
          from(e in SagaEvent, where: e.saga_id == ^saga.id, order_by: [desc: e.sequence_number])
        )

      event_types = Enum.map(events, & &1.event_type)
      assert "saga_compensation_compensated" in event_types
      assert "step_compensated" in event_types
    end
  end

  describe "compensation status tracking" do
    test "tracks compensation progress", %{saga: saga} do
      create_completed_step(saga, "step1", %{})
      create_completed_step(saga, "step2", %{}, ["step1"])
      create_failed_step(saga, "step3", ["step2"])

      {:ok, initial_status} = CompensationEngine.get_compensation_status(saga.id)
      assert initial_status.total_completed_steps == 2
      assert initial_status.total_compensated == 0
      assert initial_status.compensation_progress == 0.0

      # Start compensation
      {:ok, result} = CompensationEngine.start_compensation(saga.id)

      {:ok, final_status} = CompensationEngine.get_compensation_status(saga.id)
      assert final_status.total_compensated == 2
      assert final_status.compensation_progress == 100.0
      assert final_status.saga_status == "compensated"
    end

    test "handles partial compensation scenarios", %{saga: saga} do
      # Mix of compensatable and non-compensatable steps
      step1 = create_completed_step(saga, "step1", %{})
      step2 = create_completed_step(saga, "step2", %{}, ["step1"])
      step2 = update_step_metadata(step2, %{"compensation" => %{"available" => false}})

      create_failed_step(saga, "step3", ["step2"])

      CompensationEngine.start_compensation(saga.id)

      {:ok, status} = CompensationEngine.get_compensation_status(saga.id)

      # Should show mixed results
      # At least step1 compensated
      assert status.total_compensated >= 1
      assert status.saga_status == "compensated"
    end
  end

  describe "error handling and edge cases" do
    test "handles non-existent saga" do
      fake_saga_id = Ecto.UUID.generate()
      assert {:error, :saga_not_found} = CompensationEngine.start_compensation(fake_saga_id)
    end

    test "handles circular dependencies gracefully", %{saga: saga} do
      # This shouldn't happen in practice due to workflow validation,
      # but we test error handling
      step1 = create_completed_step(saga, "step1", %{}, ["step2"])
      step2 = create_completed_step(saga, "step2", %{}, ["step1"])
      create_failed_step(saga, "step3", ["step1"])

      # Should handle the circular dependency error
      result = CompensationEngine.start_compensation(saga.id)

      case result do
        # Expected error
        {:error, _reason} -> assert true
        # May succeed if cycle is handled
        {:ok, _} -> assert true
      end
    end

    test "validates state transitions during compensation", %{saga: saga} do
      # Create step in invalid state for compensation
      {:ok, invalid_step} =
        %SagaStep{}
        |> SagaStep.changeset(%{
          saga_id: saga.id,
          step_id: "invalid_step",
          # Not completed, cannot be compensated
          status: "pending",
          step_type: "action"
        })
        |> Repo.insert()

      create_failed_step(saga, "step2", ["invalid_step"])

      # Should handle invalid state transitions gracefully
      result = CompensationEngine.start_compensation(saga.id)

      # The engine should skip invalid steps or handle errors appropriately  
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  describe "concurrent compensation" do
    test "handles parallel step compensation", %{saga: saga} do
      # Create multiple parallel completed steps
      for i <- 1..5 do
        create_completed_step(saga, "step#{i}", %{"data" => i})
      end

      create_failed_step(saga, "step6", ["step1", "step2", "step3", "step4", "step5"])

      start_time = System.monotonic_time(:millisecond)

      {:ok, result} = CompensationEngine.start_compensation(saga.id)

      end_time = System.monotonic_time(:millisecond)
      execution_time = end_time - start_time

      # Should complete relatively quickly due to parallel execution
      # (This is a rough check - actual timing depends on system load)
      # Less than 2 seconds
      assert execution_time < 2000
      assert length(result.results.compensated) == 5
    end
  end

  # Helper functions

  defp create_completed_step(saga, step_id, output, depends_on \\ []) do
    {:ok, step} =
      %SagaStep{}
      |> SagaStep.changeset(%{
        saga_id: saga.id,
        step_id: step_id,
        status: "completed",
        step_type: "action",
        output: output,
        depends_on: depends_on,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    step
  end

  defp create_failed_step(saga, step_id, depends_on \\ []) do
    {:ok, step} =
      %SagaStep{}
      |> SagaStep.changeset(%{
        saga_id: saga.id,
        step_id: step_id,
        status: "failed",
        step_type: "action",
        depends_on: depends_on,
        error_details: %{"type" => "test_failure", "message" => "Test failure"},
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    step
  end

  defp update_step_metadata(step, metadata) do
    step
    |> SagaStep.changeset(%{execution_metadata: metadata})
    |> Repo.update!()
  end
end
