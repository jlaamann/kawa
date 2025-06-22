defmodule KawaWeb.WorkflowLive.Index do
  use(KawaWeb, :live_view)

  require Logger

  alias Kawa.Core.WorkflowRegistry
  alias Kawa.Contexts.Workflows

  @impl true
  def mount(_params, _session, socket) do
    # Get workflows from both sources and create unified list
    registry_workflows = WorkflowRegistry.list_workflows()
    Logger.info("Workflows in registry: #{length(registry_workflows)}")

    Logger.info(
      "Registry workflows: #{inspect(Enum.map(registry_workflows, &{&1.name, &1.version}))}"
    )

    db_workflows = Workflows.list_workflow_definitions()
    Logger.info("Workflows in database: #{length(db_workflows)}")
    Logger.info("Database workflows: #{inspect(Enum.map(db_workflows, &{&1.name, &1.version}))}")

    unified_workflows = create_unified_workflow_list(registry_workflows, db_workflows)

    socket =
      socket
      |> assign(:workflows, unified_workflows)
      |> assign(:loading, false)
      |> assign(:selected_workflow, nil)
      |> assign(:show_workflow_modal, false)
      |> assign(:workflow_versions, [])
      |> assign(:selected_version, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Workflows")
  end

  @impl true
  def handle_event("show_workflow", %{"id" => workflow_id}, socket) do
    workflow = Enum.find(socket.assigns.workflows, &(&1.id == workflow_id))

    case workflow do
      nil ->
        {:noreply, put_flash(socket, :error, "Workflow not found")}

      workflow ->
        # Load all versions of this workflow
        versions = Workflows.list_workflow_versions(workflow.name)

        # Ensure definition is a map, handle string JSON or nil cases
        definition =
          case workflow.definition do
            nil ->
              %{}

            definition when is_map(definition) ->
              definition

            definition when is_binary(definition) ->
              case Jason.decode(definition) do
                {:ok, parsed} -> parsed
                {:error, _} -> %{"error" => "Invalid JSON definition"}
              end

            _ ->
              %{"error" => "Invalid definition format"}
          end

        updated_workflow = %{workflow | definition: definition}

        socket =
          socket
          |> assign(:selected_workflow, updated_workflow)
          |> assign(:workflow_versions, versions)
          |> assign(:selected_version, workflow.version)
          |> assign(:show_workflow_modal, true)

        {:noreply, socket}
    end
  end

  def handle_event("close_workflow_modal", _params, socket) do
    socket =
      socket
      |> assign(:selected_workflow, nil)
      |> assign(:show_workflow_modal, false)
      |> assign(:workflow_versions, [])
      |> assign(:selected_version, nil)

    {:noreply, socket}
  end

  def handle_event("switch_version", %{"version" => version}, socket) do
    case Enum.find(socket.assigns.workflow_versions, &(&1.version == version)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Version not found")}

      version_workflow ->
        # Process the definition like in show_workflow
        definition =
          case version_workflow.definition do
            nil ->
              %{}

            definition when is_map(definition) ->
              definition

            definition when is_binary(definition) ->
              case Jason.decode(definition) do
                {:ok, parsed} -> parsed
                {:error, _} -> %{"error" => "Invalid JSON definition"}
              end

            _ ->
              %{"error" => "Invalid definition format"}
          end

        # Create a unified workflow object similar to the original show_workflow logic
        updated_workflow = %{
          id: "db_#{version_workflow.id}",
          name: version_workflow.name,
          version: version_workflow.version,
          definition: definition,
          client_id: version_workflow.client_id,
          client_name: if(version_workflow.client, do: version_workflow.client.name, else: nil),
          is_active: version_workflow.is_active,
          in_memory: false,
          usage_count: 0,
          last_used_at: nil,
          registered_at: version_workflow.registered_at || version_workflow.inserted_at,
          source: "database",
          metadata: %{
            "database_id" => version_workflow.id,
            "module_name" => version_workflow.module_name,
            "definition_checksum" => version_workflow.definition_checksum
          }
        }

        socket =
          socket
          |> assign(:selected_workflow, updated_workflow)
          |> assign(:selected_version, version)

        {:noreply, socket}
    end
  end

  defp create_unified_workflow_list(registry_workflows, db_workflows) do
    # Create a map of registry workflows by name+version for quick lookup
    registry_map =
      registry_workflows
      |> Enum.reduce(%{}, fn workflow, acc ->
        key = {workflow.name, to_string(workflow.version)}
        Map.put(acc, key, workflow)
      end)

    # Convert all database workflows to unified format, checking if they're in memory
    db_workflows
    |> Enum.map(fn db_workflow ->
      key = {db_workflow.name, to_string(db_workflow.version)}
      registry_workflow = Map.get(registry_map, key)

      %{
        id: "db_#{db_workflow.id}",
        name: db_workflow.name,
        version: db_workflow.version,
        definition: db_workflow.definition,
        client_id: db_workflow.client_id,
        client_name: if(db_workflow.client, do: db_workflow.client.name, else: nil),
        is_active: db_workflow.is_active,
        in_memory: not is_nil(registry_workflow),
        usage_count: if(registry_workflow, do: registry_workflow.usage_count, else: 0),
        last_used_at: if(registry_workflow, do: registry_workflow.last_used_at, else: nil),
        registered_at: db_workflow.registered_at || db_workflow.inserted_at,
        source: "database",
        metadata: %{
          "database_id" => db_workflow.id,
          "module_name" => db_workflow.module_name,
          "definition_checksum" => db_workflow.definition_checksum
        }
      }
    end)
    |> Enum.sort_by(&{&1.name, &1.version})
  end

  defp workflow_definition_display(assigns) do
    ~H"""
    <div class="bg-gray-50 rounded-lg p-4 space-y-4">
      <%= if Map.has_key?(@definition, "name") do %>
        <div>
          <span class="text-sm font-medium text-gray-700">Name:</span>
          <span class="ml-2 text-sm text-gray-900">{@definition["name"]}</span>
        </div>
      <% end %>

      <%= if Map.has_key?(@definition, "description") do %>
        <div>
          <span class="text-sm font-medium text-gray-700">Description:</span>
          <p class="mt-1 text-sm text-gray-900">{@definition["description"]}</p>
        </div>
      <% end %>

      <%= if Map.has_key?(@definition, "steps") and is_list(@definition["steps"]) do %>
        <div>
          <span class="text-sm font-medium text-gray-700">
            Steps ({length(@definition["steps"])}):
          </span>
          <div class="mt-2 space-y-3">
            <div
              :for={{step, index} <- Enum.with_index(@definition["steps"], 1)}
              class="border-l-2 border-blue-200 pl-4"
            >
              <div class="flex items-center space-x-2">
                <span class="inline-flex items-center justify-center w-6 h-6 text-xs font-medium text-blue-600 bg-blue-100 rounded-full">
                  {index}
                </span>
                <span class="text-sm font-medium text-gray-900">
                  {Map.get(step, "name", "Step #{index}")}
                </span>
              </div>

              <%= if Map.has_key?(step, "type") do %>
                <div class="mt-1 ml-8">
                  <span class="text-xs text-gray-500">Type:</span>
                  <span class="ml-1 text-xs font-medium text-blue-700">{step["type"]}</span>
                </div>
              <% end %>

              <%= if Map.has_key?(step, "action") do %>
                <div class="mt-1 ml-8">
                  <span class="text-xs text-gray-500">Action:</span>
                  <span class="ml-1 text-xs text-gray-700">{format_step_field(step["action"])}</span>
                </div>
              <% end %>

              <%= if Map.has_key?(step, "compensation") do %>
                <div class="mt-1 ml-8">
                  <span class="text-xs text-gray-500">Compensation:</span>
                  <span class="ml-1 text-xs text-gray-700">
                    {format_step_field(step["compensation"])}
                  </span>
                </div>
              <% end %>

              <%= if Map.has_key?(step, "timeout_ms") do %>
                <div class="mt-1 ml-8">
                  <span class="text-xs text-gray-500">Timeout:</span>
                  <span class="ml-1 text-xs text-gray-700">{step["timeout_ms"]}ms</span>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
      
    <!-- Fallback: show raw JSON if structure is unexpected -->
      <%= if not (Map.has_key?(@definition, "steps") and is_list(@definition["steps"])) do %>
        <div>
          <span class="text-sm font-medium text-gray-700">Raw Definition:</span>
          <pre class="mt-2 text-xs text-gray-800 whitespace-pre-wrap bg-white p-3 rounded border"><%= Jason.encode!(@definition, pretty: true) %></pre>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_step_field(value) when is_map(value) do
    Jason.encode!(value)
  end

  defp format_step_field(value) when is_binary(value) do
    value
  end

  defp format_step_field(value) do
    inspect(value)
  end
end
