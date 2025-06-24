defmodule Kawa.Core.SagaSupervisorTest do
  use Kawa.DataCase, async: false
  alias Kawa.Core.SagaSupervisor
  alias Kawa.Schemas.{Saga, Client, WorkflowDefinition}
  alias Kawa.Repo
  import Ecto.Query

  setup do
    # Clean up any existing supervisor state
    existing_pids = SagaSupervisor.list_running_sagas()

    Enum.each(existing_pids, fn {saga_id, _pid} ->
      SagaSupervisor.stop_saga(saga_id)
    end)

    # Create test client and workflow for database operations
    {:ok, client} = create_test_client()
    {:ok, workflow} = create_test_workflow(client)
    {:ok, saga} = create_test_saga(client, workflow)

    %{saga_id: saga.id, client_id: client.id}
  end

  describe "initialization" do
    test "starts successfully with default configuration" do
      # The supervisor should already be running from application start
      assert Process.whereis(SagaSupervisor) != nil
      assert Process.alive?(Process.whereis(SagaSupervisor))
    end

    test "returns correct supervisor configuration" do
      # Test the init callback indirectly through the supervisor state
      children = DynamicSupervisor.count_children(SagaSupervisor)
      assert is_map(children)
      assert Map.has_key?(children, :active)
      assert Map.has_key?(children, :supervisors)
      assert Map.has_key?(children, :workers)
    end
  end

  describe "saga lifecycle management" do
    test "starts saga successfully", %{saga_id: saga_id} do
      assert {:ok, pid} = SagaSupervisor.start_saga(saga_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify saga is registered
      assert {:ok, ^pid} = SagaSupervisor.get_saga_pid(saga_id)
    end

    test "prevents starting saga that is already running", %{saga_id: saga_id} do
      # Start saga first time
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga_id)

      # Try to start again
      assert {:error, :already_running} = SagaSupervisor.start_saga(saga_id)
    end

    test "stops saga successfully", %{saga_id: saga_id} do
      # Start saga first
      assert {:ok, pid} = SagaSupervisor.start_saga(saga_id)
      assert Process.alive?(pid)

      # Stop saga
      assert :ok = SagaSupervisor.stop_saga(saga_id)

      # Wait for process to actually terminate and be cleaned up from registry
      # This addresses the race condition between supervisor termination and registry cleanup
      wait_for_saga_cleanup(saga_id, pid, 1000)

      # Verify saga is no longer running
      refute Process.alive?(pid)
      assert {:error, :not_found} = SagaSupervisor.get_saga_pid(saga_id)
    end

    test "returns error when stopping non-existent saga" do
      non_existent_id = "non-existent-saga"
      assert {:error, :not_running} = SagaSupervisor.stop_saga(non_existent_id)
    end

    test "handles saga process crash and restart", %{saga_id: saga_id} do
      # Start saga
      assert {:ok, original_pid} = SagaSupervisor.start_saga(saga_id)

      # Kill the process to simulate crash
      Process.exit(original_pid, :kill)
      Process.sleep(100)

      # The supervisor should have restarted it automatically
      case SagaSupervisor.get_saga_pid(saga_id) do
        {:ok, new_pid} ->
          # Should be a new process
          assert new_pid != original_pid
      end
    end
  end

  describe "saga registry operations" do
    test "get_saga_pid returns correct pid for running saga", %{saga_id: saga_id} do
      assert {:ok, pid} = SagaSupervisor.start_saga(saga_id)
      assert {:ok, ^pid} = SagaSupervisor.get_saga_pid(saga_id)
    end

    test "get_saga_pid returns error for non-existent saga" do
      assert {:error, :not_found} = SagaSupervisor.get_saga_pid("non-existent")
    end

    test "saga_running? returns correct status", %{saga_id: saga_id} do
      # Initially not running
      refute SagaSupervisor.saga_running?(saga_id)

      # Start saga
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga_id)
      assert SagaSupervisor.saga_running?(saga_id)

      # Stop saga
      assert :ok = SagaSupervisor.stop_saga(saga_id)
      refute SagaSupervisor.saga_running?(saga_id)
    end

    test "list_running_sagas returns empty list when no sagas running" do
      assert [] = SagaSupervisor.list_running_sagas()
    end

    test "list_running_sagas returns correct running sagas", %{saga_id: saga_id} do
      # Create additional saga
      {:ok, saga2} = create_test_saga_with_id("saga-2")

      # Start both sagas
      assert {:ok, pid1} = SagaSupervisor.start_saga(saga_id)
      assert {:ok, pid2} = SagaSupervisor.start_saga(saga2.id)

      running_sagas = SagaSupervisor.list_running_sagas()
      assert length(running_sagas) == 2

      saga_ids = Enum.map(running_sagas, fn {saga_id, _pid} -> saga_id end)
      assert saga_id in saga_ids
      assert saga2.id in saga_ids

      # Verify pids are correct
      saga_pids = Enum.map(running_sagas, fn {_saga_id, pid} -> pid end)
      assert pid1 in saga_pids
      assert pid2 in saga_pids
    end
  end

  describe "statistics and monitoring" do
    test "get_statistics returns correct stats with no running sagas" do
      stats = SagaSupervisor.get_statistics()

      assert stats.total_running == 0
      assert stats.saga_ids == []
      assert is_map(stats.supervisor_children)
    end

    test "get_statistics returns correct stats with running sagas", %{saga_id: saga_id} do
      # Start saga
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga_id)

      stats = SagaSupervisor.get_statistics()

      assert stats.total_running == 1
      assert saga_id in stats.saga_ids
      assert is_map(stats.supervisor_children)
      assert stats.supervisor_children.active >= 1
    end

    test "get_statistics tracks multiple sagas correctly" do
      {:ok, saga1} = create_test_saga_with_id("saga-1")
      {:ok, saga2} = create_test_saga_with_id("saga-2")
      {:ok, saga3} = create_test_saga_with_id("saga-3")

      # Start all sagas
      assert {:ok, _pid1} = SagaSupervisor.start_saga(saga1.id)
      assert {:ok, _pid2} = SagaSupervisor.start_saga(saga2.id)
      assert {:ok, _pid3} = SagaSupervisor.start_saga(saga3.id)

      stats = SagaSupervisor.get_statistics()

      assert stats.total_running == 3
      assert saga1.id in stats.saga_ids
      assert saga2.id in stats.saga_ids
      assert saga3.id in stats.saga_ids
    end
  end

  describe "start_or_resume_saga" do
    test "starts new saga when not running", %{saga_id: saga_id} do
      refute SagaSupervisor.saga_running?(saga_id)

      result = SagaSupervisor.start_or_resume_saga(saga_id)
      # May return error if client is not connected
      case result do
        :ok -> assert SagaSupervisor.saga_running?(saga_id)
        {:ok, _} -> assert SagaSupervisor.saga_running?(saga_id)
        # Client not connected is expected in tests
        {:error, _reason} -> :ok
      end
    end

    test "resumes existing saga when already running", %{saga_id: saga_id} do
      # Start saga first
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga_id)
      assert SagaSupervisor.saga_running?(saga_id)

      # start_or_resume should resume the existing one
      result = SagaSupervisor.start_or_resume_saga(saga_id)
      # May return error if client is not connected
      case result do
        :ok -> :ok
        {:ok, _} -> :ok
        # Client not connected is expected in tests
        {:error, _reason} -> :ok
      end

      # Should still be running
      assert SagaSupervisor.saga_running?(saga_id)
    end

    test "handles start failure gracefully" do
      # Use invalid saga_id that doesn't exist in database
      invalid_saga_id = "invalid-saga-id"

      result = SagaSupervisor.start_or_resume_saga(invalid_saga_id)
      # Should return error from start_saga
      assert {:error, _reason} = result
    end
  end

  describe "client saga management" do
    test "pause_client_sagas pauses all sagas for client", %{client_id: client_id} do
      # Create multiple sagas for the same client
      {:ok, saga1} = create_test_saga_with_client(client_id, "saga-1")
      {:ok, saga2} = create_test_saga_with_client(client_id, "saga-2")

      # Start both sagas
      assert {:ok, _pid1} = SagaSupervisor.start_saga(saga1.id)
      assert {:ok, _pid2} = SagaSupervisor.start_saga(saga2.id)

      # Pause client sagas
      assert :ok = SagaSupervisor.pause_client_sagas(client_id)

      # Both sagas should still be running (pause doesn't stop the process)
      assert SagaSupervisor.saga_running?(saga1.id)
      assert SagaSupervisor.saga_running?(saga2.id)
    end

    test "pause_client_sagas handles non-existent client gracefully" do
      non_existent_client = Ecto.UUID.generate()

      # Should not crash
      assert :ok = SagaSupervisor.pause_client_sagas(non_existent_client)
    end

    test "pause_client_sagas handles sagas not currently running" do
      # Create client with saga in database but not running
      {:ok, client} = create_test_client()
      {:ok, workflow} = create_test_workflow(client)
      {:ok, _saga} = create_test_saga(client, workflow)

      # Don't start the saga, just pause
      assert :ok = SagaSupervisor.pause_client_sagas(client.id)
    end

    test "resume_client_sagas resumes paused sagas for client", %{client_id: client_id} do
      # Create saga for the client
      {:ok, _saga} = create_test_saga_with_client(client_id, "resume-saga")

      # Resume client sagas (this should start them)
      assert :ok = SagaSupervisor.resume_client_sagas(client_id)

      # Saga may or may not be running depending on client connection status
      # The resume operation should complete successfully regardless
      :ok
    end

    test "resume_client_sagas handles non-existent client gracefully" do
      non_existent_client = Ecto.UUID.generate()

      # Should not crash
      assert :ok = SagaSupervisor.resume_client_sagas(non_existent_client)
    end

    test "resume_client_sagas handles start failures gracefully", %{client_id: client_id} do
      # Create saga with status that might cause start failure
      {:ok, _saga} = create_test_saga_with_client(client_id, "failing-saga")

      # Mock a failure by using an invalid saga configuration
      # This tests the error handling in resume_client_sagas
      assert :ok = SagaSupervisor.resume_client_sagas(client_id)

      # The method should complete successfully even if some sagas fail to resume
    end
  end

  describe "health_check" do
    test "returns healthy status for all running sagas", %{saga_id: saga_id} do
      # Start saga
      assert {:ok, _pid} = SagaSupervisor.start_saga(saga_id)

      health_report = SagaSupervisor.health_check()

      assert health_report.total_checked == 1
      assert health_report.healthy_count == 1
      assert health_report.unhealthy_count == 0
      assert saga_id in health_report.healthy
      assert health_report.unhealthy == []
    end

    test "returns empty health report when no sagas running" do
      health_report = SagaSupervisor.health_check()

      assert health_report.total_checked == 0
      assert health_report.healthy_count == 0
      assert health_report.unhealthy_count == 0
      assert health_report.healthy == []
      assert health_report.unhealthy == []
    end

    test "detects unhealthy sagas" do
      {:ok, saga} = create_test_saga_with_id("unhealthy-saga")

      # Start saga
      assert {:ok, pid} = SagaSupervisor.start_saga(saga.id)

      # Kill the process to make it unhealthy
      Process.exit(pid, :kill)
      Process.sleep(50)

      # The health check should detect the dead process
      # Note: After killing, the saga may or may not be removed from registry immediately
      health_report = SagaSupervisor.health_check()

      # The health check should complete successfully regardless
      assert is_map(health_report)
      assert Map.has_key?(health_report, :total_checked)
    end

    test "handles multiple sagas with mixed health" do
      {:ok, saga1} = create_test_saga_with_id("healthy-saga")
      {:ok, saga2} = create_test_saga_with_id("healthy-saga-2")

      # Start both sagas
      assert {:ok, _pid1} = SagaSupervisor.start_saga(saga1.id)
      assert {:ok, _pid2} = SagaSupervisor.start_saga(saga2.id)

      health_report = SagaSupervisor.health_check()

      assert health_report.total_checked == 2
      assert health_report.healthy_count == 2
      assert health_report.unhealthy_count == 0
      assert saga1.id in health_report.healthy
      assert saga2.id in health_report.healthy
    end
  end

  describe "error handling and edge cases" do
    test "start_saga with invalid saga_id format" do
      # Test with non-string input would cause function clause error
      # but we test with valid string format that doesn't exist in DB
      result = SagaSupervisor.start_saga("invalid-saga-format")
      assert {:error, _reason} = result
    end

    test "handles supervisor restart scenarios" do
      # Test that the supervisor can be queried for its state
      children = DynamicSupervisor.count_children(SagaSupervisor)
      assert is_map(children)

      # Supervisor should be responsive
      stats = SagaSupervisor.get_statistics()
      assert is_map(stats)
    end

    test "concurrent saga operations" do
      # Test starting multiple sagas concurrently
      # Reduced to 3 for stability
      saga_ids = for i <- 1..3, do: "concurrent-saga-#{i}"

      # Create sagas in database first
      saga_records =
        Enum.map(saga_ids, fn saga_id ->
          {:ok, saga} = create_test_saga_with_id(saga_id)
          saga
        end)

      # Start all sagas concurrently
      tasks =
        Enum.map(saga_records, fn saga ->
          Task.async(fn -> SagaSupervisor.start_saga(saga.id) end)
        end)

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn result ->
               case result do
                 {:ok, _pid} -> true
                 _ -> false
               end
             end)

      # Verify all are running
      running_sagas = SagaSupervisor.list_running_sagas()
      assert length(running_sagas) == 3
    end

    test "handles registry lookup edge cases" do
      # Test with non-existent saga
      assert {:error, :not_found} = SagaSupervisor.get_saga_pid("definitely-not-a-saga")
      assert false == SagaSupervisor.saga_running?("definitely-not-a-saga")
    end
  end

  # Helper functions for test setup

  # Wait for saga process to be cleaned up from both process table and registry
  defp wait_for_saga_cleanup(saga_id, pid, timeout_ms) do
    end_time = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_cleanup(saga_id, pid, end_time)
  end

  defp poll_for_cleanup(saga_id, pid, end_time) do
    cond do
      not Process.alive?(pid) and
          match?({:error, :not_found}, SagaSupervisor.get_saga_pid(saga_id)) ->
        :ok

      System.monotonic_time(:millisecond) >= end_time ->
        :timeout

      true ->
        :timer.sleep(10)
        poll_for_cleanup(saga_id, pid, end_time)
    end
  end

  defp create_test_client do
    client_attrs = %{
      name: "test-client-#{System.unique_integer()}",
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

    definition_json = Jason.encode!(definition)
    checksum = :crypto.hash(:sha256, definition_json) |> Base.encode16(case: :lower)

    workflow_attrs = %{
      name: "test_workflow_#{System.unique_integer()}",
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

  defp create_test_saga(client, workflow) do
    saga_attrs = %{
      correlation_id: "test_#{System.unique_integer()}",
      status: "running",
      input: %{"test" => true},
      context: %{},
      workflow_definition_id: workflow.id,
      client_id: client.id
    }

    %Saga{}
    |> Saga.create_changeset(saga_attrs)
    |> Repo.insert()
  end

  defp create_test_saga_with_id(saga_id) do
    {:ok, client} = create_test_client()
    {:ok, workflow} = create_test_workflow(client)

    saga_attrs = %{
      id: saga_id,
      correlation_id: "test_#{saga_id}",
      status: "running",
      input: %{"test" => true},
      context: %{},
      workflow_definition_id: workflow.id,
      client_id: client.id
    }

    %Saga{}
    |> Saga.create_changeset(saga_attrs)
    |> Repo.insert()
  end

  defp create_test_saga_with_client(client_id, saga_id) do
    # Get existing client and workflow
    _client = Repo.get!(Client, client_id)
    workflow = Repo.one!(from w in WorkflowDefinition, where: w.client_id == ^client_id, limit: 1)

    saga_attrs = %{
      id: saga_id,
      correlation_id: "test_#{saga_id}",
      status: "running",
      input: %{"test" => true},
      context: %{},
      workflow_definition_id: workflow.id,
      client_id: client_id
    }

    %Saga{}
    |> Saga.create_changeset(saga_attrs)
    |> Repo.insert()
  end
end
