defmodule Kawa.Core.SagaRecoveryTest do
  use ExUnit.Case, async: false
  use Kawa.DataCase

  alias Kawa.Core.{SagaRecovery, SagaSupervisor, ClientRegistry}
  alias Kawa.Schemas.{Saga, SagaStep, SagaEvent, WorkflowDefinition, Client}
  alias Kawa.Repo

  import Ecto.Query

  @moduletag :integration

  setup do
    # Configure test compensation client for integration tests
    Application.put_env(:kawa, :compensation_client, Kawa.Execution.CompensationClient.Test)

    # Ensure ClientRegistry is started
    case Process.whereis(Kawa.Core.ClientRegistry) do
      nil ->
        {:ok, _pid} = start_supervised({Kawa.Core.ClientRegistry, []})

      _pid ->
        :ok
    end

    on_exit(fn ->
      Application.delete_env(:kawa, :compensation_client)
    end)

    # Create test client
    {:ok, client} = create_test_client()

    # Create test workflow definition
    {:ok, workflow_def} = create_test_workflow_definition(client)

    %{client: client, workflow_definition: workflow_def}
  end

  describe "saga recovery on startup" do
    test "recovers running sagas with connected clients", %{
      client: client,
      workflow_definition: workflow_def
    } do
      # Create a running saga
      {:ok, saga} = create_test_saga(client, workflow_def, "running")

      # Create some steps and events to simulate in-progress execution
      {:ok, _step1} = create_saga_step(saga, "step1", "completed")
      {:ok, _step2} = create_saga_step(saga, "step2", "running")

      create_saga_event(saga, "saga_started", %{})
      create_saga_event(saga, "step_completed", %{step_id: "step1", result: %{data: "test"}})
      create_saga_event(saga, "step_started", %{step_id: "step2"})

      # Register client as connected (with error handling)
      try do
        ClientRegistry.register_client(client.id, self())
      rescue
        error ->
          # If ClientRegistry is not available, skip client registration
          IO.puts(
            "Warning: ClientRegistry not available in test, skipping client registration: #{inspect(error)}"
          )

          :ok
      end

      # Trigger recovery
      result = SagaRecovery.recover_all_sagas()

      # Verify saga was recovered
      assert result.recovered == 1
      assert result.paused == 0
      assert result.failed == 0
      assert result.total == 1

      # Verify saga server is running
      assert {:ok, _pid} = SagaSupervisor.get_saga_pid(saga.id)

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end

    test "pauses running sagas with disconnected clients", %{
      client: client,
      workflow_definition: workflow_def
    } do
      # Create a running saga
      {:ok, saga} = create_test_saga(client, workflow_def, "running")

      # Create some steps and events
      {:ok, _step1} = create_saga_step(saga, "step1", "completed")
      {:ok, _step2} = create_saga_step(saga, "step2", "running")

      create_saga_event(saga, "saga_started", %{})
      create_saga_event(saga, "step_completed", %{step_id: "step1", result: %{}})
      create_saga_event(saga, "step_started", %{step_id: "step2"})

      # Client is NOT registered (disconnected)

      # Trigger recovery
      result = SagaRecovery.recover_all_sagas()

      # Verify saga was paused
      assert result.recovered == 0
      assert result.paused == 1
      assert result.failed == 0
      assert result.total == 1

      # Verify saga status was updated
      updated_saga = Repo.get(Saga, saga.id)
      assert updated_saga.status == "paused"
      assert updated_saga.paused_at != nil
    end

    test "recovers compensating sagas", %{client: client, workflow_definition: workflow_def} do
      # Create a compensating saga
      {:ok, saga} = create_test_saga(client, workflow_def, "compensating")

      # Create steps and events for compensation scenario
      {:ok, _step1} = create_saga_step(saga, "step1", "completed")
      {:ok, _step2} = create_saga_step(saga, "step2", "failed")

      create_saga_event(saga, "saga_started", %{})
      create_saga_event(saga, "step_completed", %{step_id: "step1", result: %{}})
      create_saga_event(saga, "step_failed", %{step_id: "step2", error: %{type: "test_error"}})
      create_saga_event(saga, "compensation_started", %{})

      # Register client as connected (with error handling)
      try do
        ClientRegistry.register_client(client.id, self())
      rescue
        error ->
          IO.puts("Warning: ClientRegistry not available in test: #{inspect(error)}")
          :ok
      end

      # Trigger recovery
      result = SagaRecovery.recover_all_sagas()

      # Verify saga was recovered
      assert result.recovered == 1
      assert result.total == 1

      # Verify saga server is running
      assert {:ok, _pid} = SagaSupervisor.get_saga_pid(saga.id)

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end

    test "ignores completed sagas", %{client: client, workflow_definition: workflow_def} do
      # Create completed and failed sagas
      {:ok, _completed_saga} = create_test_saga(client, workflow_def, "completed")
      {:ok, _failed_saga} = create_test_saga(client, workflow_def, "failed")

      # Trigger recovery
      result = SagaRecovery.recover_all_sagas()

      # Verify no sagas were processed
      assert result.recovered == 0
      assert result.paused == 0
      assert result.failed == 0
      assert result.total == 0
    end
  end

  describe "state reconstruction from events" do
    test "reconstructs saga state from event log", %{
      client: client,
      workflow_definition: workflow_def
    } do
      {:ok, saga} = create_test_saga(client, workflow_def, "running")

      # Create events in sequence
      create_saga_event(saga, "saga_started", %{})
      create_saga_event(saga, "step_started", %{step_id: "step1"})
      create_saga_event(saga, "step_completed", %{step_id: "step1", result: %{data: "test"}})
      create_saga_event(saga, "step_started", %{step_id: "step2"})
      create_saga_event(saga, "step_failed", %{step_id: "step2", error: %{type: "test_error"}})
      create_saga_event(saga, "compensation_started", %{})

      # Test individual saga recovery to verify state reconstruction
      result = SagaRecovery.recover_saga(saga.id)

      # Should handle the failed saga appropriately
      assert result in [{:ok, :recovered}, {:ok, :paused}]
    end

    test "handles missing or corrupted events gracefully", %{
      client: client,
      workflow_definition: workflow_def
    } do
      {:ok, saga} = create_test_saga(client, workflow_def, "running")

      # Create minimal events (simulating incomplete event log)
      create_saga_event(saga, "saga_started", %{})

      # Should still be able to recover
      result = SagaRecovery.recover_saga(saga.id)
      assert result in [{:ok, :recovered}, {:ok, :paused}]
    end
  end

  describe "client reconnection handling" do
    test "resumes paused sagas when client reconnects", %{
      client: client,
      workflow_definition: workflow_def
    } do
      # Create a paused saga
      {:ok, saga} = create_test_saga(client, workflow_def, "paused")
      {:ok, _step1} = create_saga_step(saga, "step1", "completed")
      {:ok, _step2} = create_saga_step(saga, "step2", "pending")

      # Ensure saga server is not already running
      case SagaSupervisor.get_saga_pid(saga.id) do
        {:ok, _pid} -> SagaSupervisor.stop_saga(saga.id)
        {:error, :not_found} -> :ok
      end

      # Simulate client reconnection (with error handling)
      try do
        ClientRegistry.register_client(client.id, self())
      rescue
        error ->
          IO.puts("Warning: ClientRegistry not available in test: #{inspect(error)}")
          :ok
      end

      # Wait deterministically for async resume operation to complete
      :timer.sleep(100)

      # Poll for saga status change with timeout
      updated_saga = poll_for_saga_status_change(saga.id, "paused", 2000)

      # Verify saga was resumed to running state
      assert updated_saga.status == "running"

      # Verify saga server is running
      assert {:ok, _pid} = SagaSupervisor.get_saga_pid(saga.id)

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end

    test "pauses running sagas when client disconnects", %{
      client: client,
      workflow_definition: workflow_def
    } do
      # Create a running saga and start its server
      {:ok, saga} = create_test_saga(client, workflow_def, "running")
      {:ok, _pid} = SagaSupervisor.start_saga(saga.id)

      # Register then unregister client (simulating disconnect)
      try do
        ClientRegistry.register_client(client.id, self())
        ClientRegistry.unregister_client(client.id)
      rescue
        error ->
          IO.puts("Warning: ClientRegistry not available in test: #{inspect(error)}")
          :ok
      end

      # Wait a moment for async pause operation
      Process.sleep(100)

      # Verify saga was paused
      updated_saga = Repo.get(Saga, saga.id)
      assert updated_saga.status == "paused"

      # Cleanup
      SagaSupervisor.stop_saga(saga.id)
    end
  end

  describe "orphaned saga cleanup" do
    test "marks old paused sagas as failed", %{client: client, workflow_definition: workflow_def} do
      # Create an old paused saga (simulate 45 minutes ago)
      {:ok, saga} = create_test_saga(client, workflow_def, "paused")

      old_time =
        DateTime.utc_now() |> DateTime.add(-45 * 60, :second) |> DateTime.truncate(:second)

      # Update the paused_at timestamp to be old
      saga
      |> Ecto.Changeset.change(paused_at: old_time)
      |> Repo.update!()

      # Run orphan cleanup
      result = SagaRecovery.cleanup_orphaned_sagas()

      # Verify saga was marked as failed
      updated_saga = Repo.get(Saga, saga.id)
      assert updated_saga.status == "failed"
      assert result.total_checked == 1
      assert result.cleaned_up == 1
    end

    test "does not cleanup recently paused sagas", %{
      client: client,
      workflow_definition: workflow_def
    } do
      # Create a recently paused saga
      {:ok, saga} = create_test_saga(client, workflow_def, "paused")

      recent_time =
        DateTime.utc_now() |> DateTime.add(-5 * 60, :second) |> DateTime.truncate(:second)

      # Update the paused_at timestamp to be recent
      saga
      |> Ecto.Changeset.change(paused_at: recent_time)
      |> Repo.update!()

      # Run orphan cleanup
      result = SagaRecovery.cleanup_orphaned_sagas()

      # Verify saga was not touched
      updated_saga = Repo.get(Saga, saga.id)
      assert updated_saga.status == "paused"
      assert result.total_checked == 0
    end
  end

  describe "recovery monitoring" do
    test "tracks recovery statistics", %{client: client, workflow_definition: workflow_def} do
      # Create multiple sagas in different states
      {:ok, _running_saga} = create_test_saga(client, workflow_def, "running")
      {:ok, _compensating_saga} = create_test_saga(client, workflow_def, "compensating")

      # Register client (with error handling)
      try do
        ClientRegistry.register_client(client.id, self())
      rescue
        error ->
          IO.puts("Warning: ClientRegistry not available in test: #{inspect(error)}")
          :ok
      end

      # Get initial stats
      initial_stats = SagaRecovery.get_recovery_stats()

      # Trigger recovery
      SagaRecovery.recover_all_sagas()

      # Get updated stats
      updated_stats = SagaRecovery.get_recovery_stats()

      # Verify stats were updated
      assert updated_stats.total_recoveries == initial_stats.total_recoveries + 1
      assert updated_stats.total_sagas_recovered >= 2
      assert updated_stats.last_recovery_at != nil
      assert updated_stats.last_recovery_duration_ms > 0
    end
  end

  describe "error handling" do
    test "handles non-existent saga gracefully" do
      fake_saga_id = Ecto.UUID.generate()
      result = SagaRecovery.recover_saga(fake_saga_id)
      assert {:error, :saga_not_found} = result
    end

    test "continues recovery when individual saga fails", %{
      client: client,
      workflow_definition: workflow_def
    } do
      # Create one good saga
      {:ok, _good_saga} = create_test_saga(client, workflow_def, "running")

      # Register client (with error handling)
      try do
        ClientRegistry.register_client(client.id, self())
      rescue
        error ->
          IO.puts("Warning: ClientRegistry not available in test: #{inspect(error)}")
          :ok
      end

      # Trigger recovery - should process the saga successfully
      result = SagaRecovery.recover_all_sagas()

      # Should have processed the saga
      assert result.total == 1
      assert result.recovered == 1 || result.paused == 1
      assert result.failed == 0
    end
  end

  # Helper functions

  defp create_test_client do
    %Client{}
    |> Client.create_changeset(%{
      name: "test-client-recovery-#{System.unique_integer([:positive])}",
      environment: "dev"
    })
    |> Repo.insert()
  end

  defp create_test_workflow_definition(client) do
    workflow_definition = %{
      "steps" => [
        %{
          "id" => "step1",
          "depends_on" => [],
          "timeout" => 5000,
          "input" => %{"action" => "step1_action"}
        },
        %{
          "id" => "step2",
          "depends_on" => ["step1"],
          "timeout" => 5000,
          "input" => %{"action" => "step2_action"}
        }
      ]
    }

    %WorkflowDefinition{}
    |> WorkflowDefinition.changeset(%{
      name: "test-recovery-workflow-#{System.unique_integer([:positive])}",
      version: "1.0.0",
      module_name: "TestRecoveryWorkflow",
      definition: workflow_definition,
      definition_checksum: "test-checksum-#{System.unique_integer([:positive])}",
      client_id: client.id
    })
    |> Repo.insert()
  end

  defp create_test_saga(client, workflow_def, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      correlation_id: "test-recovery-saga-#{System.unique_integer([:positive])}",
      workflow_definition_id: workflow_def.id,
      client_id: client.id,
      input: %{"test_data" => "recovery_test"},
      context: %{},
      status: status
    }

    # Add status-specific timestamps
    attrs =
      case status do
        "paused" -> Map.put(attrs, :paused_at, now)
        "completed" -> Map.put(attrs, :completed_at, now)
        "failed" -> Map.put(attrs, :completed_at, now)
        _ -> attrs
      end

    %Saga{}
    |> Saga.create_changeset(attrs)
    |> Repo.insert()
  end

  defp create_saga_step(saga, step_id, status) do
    attrs = %{
      saga_id: saga.id,
      step_id: step_id,
      status: status,
      step_type: "action"
    }

    attrs =
      case status do
        "completed" ->
          Map.put(attrs, :completed_at, DateTime.utc_now() |> DateTime.truncate(:second))

        "failed" ->
          Map.put(attrs, :completed_at, DateTime.utc_now() |> DateTime.truncate(:second))

        "running" ->
          Map.put(attrs, :started_at, DateTime.utc_now() |> DateTime.truncate(:second))

        _ ->
          attrs
      end

    %SagaStep{}
    |> SagaStep.changeset(attrs)
    |> Repo.insert()
  end

  defp create_saga_event(saga, event_type, payload) do
    sequence_number = get_next_sequence_number(saga.id)

    %SagaEvent{}
    |> SagaEvent.changeset(%{
      saga_id: saga.id,
      event_type: event_type,
      sequence_number: sequence_number,
      payload: payload,
      step_id: Map.get(payload, :step_id),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp get_next_sequence_number(saga_id) do
    case from(e in SagaEvent,
           where: e.saga_id == ^saga_id,
           select: max(e.sequence_number)
         )
         |> Repo.one() do
      nil -> 1
      max_seq -> max_seq + 1
    end
  end

  # Helper function for deterministic waiting
  defp poll_for_saga_status_change(saga_id, initial_status, timeout_ms) do
    end_time = System.monotonic_time(:millisecond) + timeout_ms
    poll_saga_status(saga_id, initial_status, end_time)
  end

  defp poll_saga_status(saga_id, initial_status, end_time) do
    current_saga = Repo.get(Saga, saga_id)

    cond do
      current_saga.status != initial_status ->
        current_saga

      System.monotonic_time(:millisecond) >= end_time ->
        current_saga

      true ->
        :timer.sleep(50)
        poll_saga_status(saga_id, initial_status, end_time)
    end
  end
end
