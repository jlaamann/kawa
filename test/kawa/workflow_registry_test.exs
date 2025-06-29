defmodule Kawa.Core.WorkflowRegistryTest do
  use ExUnit.Case, async: true
  alias Kawa.Core.WorkflowRegistry
  alias Kawa.Core.WorkflowRegistry.WorkflowDefinition

  setup do
    registry_name = :"test_registry_#{System.unique_integer()}"
    {:ok, pid} = WorkflowRegistry.start_link(name: registry_name)
    {:ok, registry: pid, registry_name: registry_name}
  end

  defp call_registry(registry_name, message) do
    GenServer.call(registry_name, message)
  end

  defp cast_registry(registry_name, message) do
    GenServer.cast(registry_name, message)
  end

  defp valid_workflow_definition(name \\ "test-workflow", version \\ "1.0.0") do
    %{
      "name" => name,
      "version" => version,
      "steps" => [
        %{
          "id" => "step1",
          "type" => "http",
          "action" => %{"method" => "POST", "url" => "http://example.com"}
        }
      ]
    }
  end

  defp valid_definition_params(workflow_name \\ "test-workflow", client_id \\ "test-client") do
    %{
      definition: valid_workflow_definition(workflow_name),
      client_id: client_id,
      metadata: %{}
    }
  end

  defp valid_definition_params_with_version(
         workflow_name \\ "test-workflow",
         version \\ "1.0.0",
         client_id \\ "test-client"
       ) do
    definition = valid_workflow_definition(workflow_name) |> Map.put("version", version)

    %{
      definition: definition,
      client_id: client_id,
      metadata: %{}
    }
  end

  describe "register_workflow/2" do
    test "registers a new workflow successfully", %{registry_name: registry_name} do
      definition_params = valid_definition_params()

      assert {:ok, "1.0.0"} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params}
               )
    end

    test "creates new version when registering existing workflow", %{registry_name: registry_name} do
      definition_params_v1 = valid_definition_params()

      assert {:ok, "1.0.0"} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params_v1}
               )

      definition_params_v2 = %{
        definition: valid_workflow_definition("test-workflow", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      assert {:ok, "2.0.0"} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params_v2}
               )
    end

    test "returns error for missing required fields", %{registry_name: registry_name} do
      assert {:error, {:missing_required_field, :definition}} =
               call_registry(registry_name, {:register_workflow, "test", %{client_id: "test"}})

      assert {:error, {:missing_required_field, :client_id}} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test", %{definition: valid_workflow_definition()}}
               )
    end

    test "returns error for invalid workflow definition", %{registry_name: registry_name} do
      invalid_definition_params = %{
        definition: %{"invalid" => "workflow"},
        client_id: "test-client"
      }

      assert {:error, {:invalid_workflow_definition, _errors}} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test", invalid_definition_params}
               )
    end

    test "deactivates previous versions when registering new version", %{
      registry_name: registry_name
    } do
      definition_params_v1 = %{
        definition: valid_workflow_definition("test-workflow", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v2 = %{
        definition: valid_workflow_definition("test-workflow", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v3 = %{
        definition: valid_workflow_definition("test-workflow", "3.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v1})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v2})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v3})

      {:ok, workflow_v1} = call_registry(registry_name, {:get_workflow, "test-workflow", "1.0.0"})
      {:ok, workflow_v2} = call_registry(registry_name, {:get_workflow, "test-workflow", "2.0.0"})
      {:ok, workflow_v3} = call_registry(registry_name, {:get_workflow, "test-workflow", "3.0.0"})

      refute workflow_v1.is_active
      refute workflow_v2.is_active
      assert workflow_v3.is_active
    end

    test "returns error when registering workflow with same version but different content", %{
      registry_name: registry_name
    } do
      # Register initial workflow with version 1.0.0
      definition_params_v1 = valid_definition_params_with_version("test-workflow", "1.0.0")

      assert {:ok, "1.0.0"} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params_v1}
               )

      # Try to register different workflow with same version 1.0.0
      different_definition = %{
        "name" => "test-workflow",
        "version" => "1.0.0",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "PUT", "url" => "http://different.com"}
          }
        ]
      }

      definition_params_different = %{
        definition: different_definition,
        client_id: "test-client",
        metadata: %{}
      }

      assert {:error, :version_already_exists} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params_different}
               )
    end

    test "allows re-registering workflow with same version and same content", %{
      registry_name: registry_name
    } do
      # Register initial workflow with version 1.0.0
      definition_params_v1 = valid_definition_params_with_version("test-workflow", "1.0.0")

      assert {:ok, "1.0.0"} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params_v1}
               )

      # Register same workflow with same version and same content (should succeed)
      definition_params_same =
        valid_definition_params_with_version("test-workflow", "1.0.0", "different-client")

      assert {:ok, "1.0.0"} =
               call_registry(
                 registry_name,
                 {:register_workflow, "test-workflow", definition_params_same}
               )

      # Verify the workflow was updated with new client_id but same definition
      {:ok, workflow} = call_registry(registry_name, {:get_workflow, "test-workflow", "1.0.0"})
      assert workflow.client_id == "different-client"
      assert workflow.definition == definition_params_v1.definition
    end
  end

  describe "get_workflow/1" do
    test "returns active workflow", %{registry_name: registry_name} do
      definition_params = valid_definition_params()

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params})

      assert {:ok, %WorkflowDefinition{name: "test-workflow", version: "1.0.0", is_active: true}} =
               call_registry(registry_name, {:get_workflow, "test-workflow"})
    end

    test "returns error for non-existent workflow", %{registry_name: registry_name} do
      assert {:error, :not_found} = call_registry(registry_name, {:get_workflow, "non-existent"})
    end
  end

  describe "get_workflow/2" do
    test "returns specific version of workflow", %{registry_name: registry_name} do
      definition_params_v1 = %{
        definition: valid_workflow_definition("test-workflow", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v2 = %{
        definition: valid_workflow_definition("test-workflow", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v1})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v2})

      assert {:ok, %WorkflowDefinition{version: "1.0.0", is_active: false}} =
               call_registry(registry_name, {:get_workflow, "test-workflow", "1.0.0"})

      assert {:ok, %WorkflowDefinition{version: "2.0.0", is_active: true}} =
               call_registry(registry_name, {:get_workflow, "test-workflow", "2.0.0"})
    end

    test "returns error for non-existent version", %{registry_name: registry_name} do
      assert {:error, :not_found} =
               call_registry(registry_name, {:get_workflow, "test-workflow", "999.0.0"})
    end
  end

  describe "list_workflows/0" do
    test "returns empty list when no workflows registered", %{registry_name: registry_name} do
      assert [] = call_registry(registry_name, :list_workflows)
    end

    test "returns only active workflows", %{registry_name: registry_name} do
      definition_params_1 = valid_definition_params("workflow-1")
      definition_params_2 = valid_definition_params("workflow-2")

      call_registry(registry_name, {:register_workflow, "workflow-1", definition_params_1})
      call_registry(registry_name, {:register_workflow, "workflow-2", definition_params_2})
      call_registry(registry_name, {:register_workflow, "workflow-1", definition_params_1})

      workflows = call_registry(registry_name, :list_workflows)

      assert length(workflows) == 2
      assert Enum.all?(workflows, & &1.is_active)
      assert Enum.map(workflows, & &1.name) |> Enum.sort() == ["workflow-1", "workflow-2"]
    end
  end

  describe "list_workflow_versions/1" do
    test "returns all versions of a workflow", %{registry_name: registry_name} do
      definition_params_v1 = %{
        definition: valid_workflow_definition("test-workflow", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v2 = %{
        definition: valid_workflow_definition("test-workflow", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v3 = %{
        definition: valid_workflow_definition("test-workflow", "3.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v1})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v2})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v3})

      {:ok, versions} = call_registry(registry_name, {:list_workflow_versions, "test-workflow"})

      assert length(versions) == 3
      assert Enum.map(versions, & &1.version) == ["3.0.0", "2.0.0", "1.0.0"]
    end

    test "returns error for non-existent workflow", %{registry_name: registry_name} do
      assert {:error, :not_found} =
               call_registry(registry_name, {:list_workflow_versions, "non-existent"})
    end
  end

  describe "update_workflow/3" do
    test "creates new version and makes it active by default", %{registry_name: registry_name} do
      definition_params = valid_definition_params()

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params})

      updated_params = %{
        definition: %{
          "name" => "test-workflow",
          "version" => "2.0.0",
          "steps" => [
            %{
              "id" => "step1",
              "type" => "http",
              "action" => %{"method" => "PUT", "url" => "http://example.com/updated"}
            }
          ]
        },
        client_id: "test-client"
      }

      assert {:ok, "2.0.0"} =
               call_registry(
                 registry_name,
                 {:update_workflow, "test-workflow", updated_params, true}
               )

      {:ok, active_workflow} = call_registry(registry_name, {:get_workflow, "test-workflow"})
      assert active_workflow.version == "2.0.0"
      assert active_workflow.definition == updated_params.definition
    end

    test "can create new version without making it active", %{registry_name: registry_name} do
      definition_params = valid_definition_params()

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params})

      updated_params = %{
        definition: %{
          "name" => "test-workflow",
          "version" => "2.0.0",
          "steps" => [
            %{
              "id" => "step1",
              "type" => "http",
              "action" => %{"method" => "PUT", "url" => "http://example.com/updated"}
            }
          ]
        },
        client_id: "test-client"
      }

      assert {:ok, "2.0.0"} =
               call_registry(
                 registry_name,
                 {:update_workflow, "test-workflow", updated_params, false}
               )

      {:ok, active_workflow} = call_registry(registry_name, {:get_workflow, "test-workflow"})
      assert active_workflow.version == "1.0.0"

      {:ok, new_version} = call_registry(registry_name, {:get_workflow, "test-workflow", "2.0.0"})
      refute new_version.is_active
    end

    test "returns error for non-existent workflow", %{registry_name: registry_name} do
      updated_params = valid_definition_params()

      assert {:error, :workflow_not_found} =
               call_registry(
                 registry_name,
                 {:update_workflow, "non-existent", updated_params, true}
               )
    end
  end

  describe "set_active_version/2" do
    test "changes active version successfully", %{registry_name: registry_name} do
      definition_params_v1 = %{
        definition: valid_workflow_definition("test-workflow", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v2 = %{
        definition: valid_workflow_definition("test-workflow", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v1})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v2})

      assert :ok = call_registry(registry_name, {:set_active_version, "test-workflow", "1.0.0"})

      {:ok, active_workflow} = call_registry(registry_name, {:get_workflow, "test-workflow"})
      assert active_workflow.version == "1.0.0"
    end

    test "returns error for non-existent version", %{registry_name: registry_name} do
      assert {:error, :version_not_found} =
               call_registry(registry_name, {:set_active_version, "test-workflow", "999.0.0"})
    end
  end

  describe "record_usage/1" do
    test "increments usage counter for active version", %{registry_name: registry_name} do
      definition_params = valid_definition_params()

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params})

      {:ok, workflow_before} = call_registry(registry_name, {:get_workflow, "test-workflow"})
      assert workflow_before.usage_count == 0
      assert workflow_before.last_used_at == nil

      cast_registry(registry_name, {:record_usage, "test-workflow", nil})
      # Allow cast to process
      :timer.sleep(10)

      {:ok, workflow_after} = call_registry(registry_name, {:get_workflow, "test-workflow"})
      assert workflow_after.usage_count == 1
      assert workflow_after.last_used_at != nil
    end

    test "increments usage counter for specific version", %{registry_name: registry_name} do
      definition_params_v1 = %{
        definition: valid_workflow_definition("test-workflow", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_v2 = %{
        definition: valid_workflow_definition("test-workflow", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v1})
      call_registry(registry_name, {:register_workflow, "test-workflow", definition_params_v2})

      cast_registry(registry_name, {:record_usage, "test-workflow", "1.0.0"})
      # Allow cast to process
      :timer.sleep(10)

      {:ok, workflow_v1} = call_registry(registry_name, {:get_workflow, "test-workflow", "1.0.0"})
      {:ok, workflow_v2} = call_registry(registry_name, {:get_workflow, "test-workflow", "2.0.0"})

      assert workflow_v1.usage_count == 1
      assert workflow_v2.usage_count == 0
    end
  end

  describe "get_stats/0" do
    test "returns correct statistics", %{registry_name: registry_name} do
      definition_params_1 = %{
        definition: valid_workflow_definition("workflow-1", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_2 = %{
        definition: valid_workflow_definition("workflow-2", "1.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      definition_params_1_v2 = %{
        definition: valid_workflow_definition("workflow-1", "2.0.0"),
        client_id: "test-client",
        metadata: %{}
      }

      call_registry(registry_name, {:register_workflow, "workflow-1", definition_params_1})
      call_registry(registry_name, {:register_workflow, "workflow-2", definition_params_2})
      call_registry(registry_name, {:register_workflow, "workflow-1", definition_params_1_v2})

      cast_registry(registry_name, {:record_usage, "workflow-1", nil})
      cast_registry(registry_name, {:record_usage, "workflow-2", nil})
      # Allow casts to process
      :timer.sleep(10)

      stats = call_registry(registry_name, :get_stats)

      assert stats.total_workflows == 2
      assert stats.total_versions == 3
      assert stats.total_usage == 2
      assert stats.unique_clients == 1
    end
  end

  # DEV-TODO: no automatic version incremental implemented at the moment, so client provided version will always be returned
  # this means that concurrency is not handled properly at the moment.
  # Will be fixed in issue #49
  # describe "concurrent operations" do
  #   test "handles concurrent registrations safely", %{registry_name: registry_name} do
  #     definition_params = valid_definition_params("concurrent-workflow")

  #     tasks =
  #       for _i <- 1..10 do
  #         Task.async(fn ->
  #           call_registry(
  #             registry_name,
  #             {:register_workflow, "concurrent-workflow", definition_params}
  #           )
  #         end)
  #       end

  #     results = Task.await_many(tasks)

  #     versions =
  #       results
  #       |> Enum.map(fn {:ok, version} -> version end)
  #       |> Enum.sort()

  #     assert versions == Enum.to_list(1..10)

  #     {:ok, all_versions} =
  #       call_registry(registry_name, {:list_workflow_versions, "concurrent-workflow"})

  #     assert length(all_versions) == 10

  #     active_versions = Enum.filter(all_versions, & &1.is_active)
  #     assert length(active_versions) == 1
  #     assert hd(active_versions).version == 10
  #   end
  # end
end
