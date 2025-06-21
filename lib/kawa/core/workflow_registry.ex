defmodule Kawa.Core.WorkflowRegistry do
  use GenServer
  require Logger

  defmodule WorkflowDefinition do
    @moduledoc """
    Represents a workflow definition with versioning and metadata.
    """
    defstruct [
      :name,
      :version,
      :definition,
      :client_id,
      :is_active,
      :registered_at,
      :updated_at,
      :usage_count,
      :last_used_at,
      :metadata
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            version: non_neg_integer(),
            definition: map(),
            client_id: String.t(),
            is_active: boolean(),
            registered_at: DateTime.t(),
            updated_at: DateTime.t(),
            usage_count: non_neg_integer(),
            last_used_at: DateTime.t() | nil,
            metadata: map()
          }
  end

  defmodule State do
    @moduledoc false
    defstruct workflows: %{},
              version_counters: %{}

    @type t :: %__MODULE__{
            workflows: %{String.t() => %{non_neg_integer() => WorkflowDefinition.t()}},
            version_counters: %{String.t() => non_neg_integer()}
          }
  end

  @doc """
  Starts the WorkflowRegistry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %State{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Registers a new workflow or creates a new version of an existing workflow.

  Returns `{:ok, version}` on success or `{:error, reason}` on failure.
  """
  def register_workflow(name, definition_params)
      when is_binary(name) and is_map(definition_params) do
    GenServer.call(__MODULE__, {:register_workflow, name, definition_params})
  end

  @doc """
  Gets the active version of a workflow by name.

  Returns `{:ok, workflow_definition}` if found, `{:error, :not_found}` otherwise.
  """
  def get_workflow(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get_workflow, name})
  end

  @doc """
  Gets a specific version of a workflow by name and version.

  Returns `{:ok, workflow_definition}` if found, `{:error, :not_found}` otherwise.
  """
  def get_workflow(name, version) when is_binary(name) and is_integer(version) do
    GenServer.call(__MODULE__, {:get_workflow, name, version})
  end

  @doc """
  Lists all workflows with their active versions.

  Returns a list of workflow definitions.
  """
  def list_workflows do
    GenServer.call(__MODULE__, :list_workflows)
  end

  @doc """
  Lists all versions of a specific workflow.

  Returns `{:ok, [workflow_definition]}` if workflow exists, `{:error, :not_found}` otherwise.
  """
  def list_workflow_versions(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:list_workflow_versions, name})
  end

  @doc """
  Updates a workflow, creating a new version and optionally making it active.

  Returns `{:ok, version}` on success or `{:error, reason}` on failure.
  """
  def update_workflow(name, definition_params, opts \\ [])
      when is_binary(name) and is_map(definition_params) do
    make_active = Keyword.get(opts, :make_active, true)
    GenServer.call(__MODULE__, {:update_workflow, name, definition_params, make_active})
  end

  @doc """
  Sets a specific version of a workflow as the active version.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def set_active_version(name, version) when is_binary(name) and is_integer(version) do
    GenServer.call(__MODULE__, {:set_active_version, name, version})
  end

  @doc """
  Records usage of a workflow, incrementing its usage counter.
  """
  def record_usage(name, version \\ nil) when is_binary(name) do
    GenServer.cast(__MODULE__, {:record_usage, name, version})
  end

  @doc """
  Gets workflow statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    Logger.info("WorkflowRegistry started")
    {:ok, state}
  end

  @impl true
  def handle_call({:register_workflow, name, definition_params}, _from, state) do
    case validate_definition_params(definition_params) do
      {:ok, validated_params} ->
        register_workflow_impl(name, validated_params, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_workflow, name}, _from, state) do
    case get_active_workflow(name, state) do
      {:ok, workflow} ->
        {:reply, {:ok, workflow}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_workflow, name, version}, _from, state) do
    case get_workflow_version(name, version, state) do
      {:ok, workflow} ->
        {:reply, {:ok, workflow}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_workflows, _from, state) do
    workflows = list_active_workflows(state)
    {:reply, workflows, state}
  end

  @impl true
  def handle_call({:list_workflow_versions, name}, _from, state) do
    case Map.get(state.workflows, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      versions ->
        workflow_list =
          versions
          |> Map.values()
          |> Enum.sort_by(& &1.version, :desc)

        {:reply, {:ok, workflow_list}, state}
    end
  end

  @impl true
  def handle_call({:update_workflow, name, definition_params, make_active}, _from, state) do
    case validate_definition_params(definition_params) do
      {:ok, validated_params} ->
        update_workflow_impl(name, validated_params, make_active, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_active_version, name, version}, _from, state) do
    case set_active_version_impl(name, version, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = calculate_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:record_usage, name, version}, state) do
    new_state = record_usage_impl(name, version, state)
    {:noreply, new_state}
  end

  # Private functions

  defp validate_definition_params(params) do
    required_fields = [:definition, :client_id]

    case Enum.find(required_fields, &(not Map.has_key?(params, &1))) do
      nil ->
        definition = Map.get(params, :definition)

        case Kawa.Validation.WorkflowValidator.validate(definition) do
          {:ok, validated_definition} ->
            validated = %{
              definition: validated_definition,
              client_id: Map.get(params, :client_id),
              metadata: Map.get(params, :metadata, %{})
            }

            {:ok, validated}

          {:error, validation_errors} ->
            {:error, {:invalid_workflow_definition, validation_errors}}
        end

      missing_field ->
        {:error, {:missing_required_field, missing_field}}
    end
  end

  defp register_workflow_impl(name, definition_params, state) do
    now = DateTime.utc_now()
    current_version = Map.get(state.version_counters, name, 0)
    new_version = current_version + 1

    workflow_def = %WorkflowDefinition{
      name: name,
      version: new_version,
      definition: definition_params.definition,
      client_id: definition_params.client_id,
      is_active: true,
      registered_at: now,
      updated_at: now,
      usage_count: 0,
      last_used_at: nil,
      metadata: definition_params.metadata
    }

    # Deactivate previous versions
    updated_workflows =
      case Map.get(state.workflows, name) do
        nil ->
          %{new_version => workflow_def}

        existing_versions ->
          deactivated_versions =
            existing_versions
            |> Enum.map(fn {v, def} -> {v, %{def | is_active: false}} end)
            |> Map.new()

          Map.put(deactivated_versions, new_version, workflow_def)
      end

    new_state = %{
      state
      | workflows: Map.put(state.workflows, name, updated_workflows),
        version_counters: Map.put(state.version_counters, name, new_version)
    }

    Logger.info(
      "Registered workflow '#{name}' version #{new_version} for client '#{definition_params.client_id}'"
    )

    {:reply, {:ok, new_version}, new_state}
  end

  defp update_workflow_impl(name, definition_params, make_active, state) do
    case Map.get(state.workflows, name) do
      nil ->
        {:reply, {:error, :workflow_not_found}, state}

      _existing_versions ->
        now = DateTime.utc_now()
        current_version = Map.get(state.version_counters, name, 0)
        new_version = current_version + 1

        workflow_def = %WorkflowDefinition{
          name: name,
          version: new_version,
          definition: definition_params.definition,
          client_id: definition_params.client_id,
          is_active: make_active,
          registered_at: now,
          updated_at: now,
          usage_count: 0,
          last_used_at: nil,
          metadata: definition_params.metadata
        }

        # Update existing versions
        updated_workflows =
          state.workflows[name]
          |> (fn versions ->
                if make_active do
                  # Deactivate all existing versions
                  deactivated =
                    versions
                    |> Enum.map(fn {v, def} -> {v, %{def | is_active: false}} end)
                    |> Map.new()

                  Map.put(deactivated, new_version, workflow_def)
                else
                  Map.put(versions, new_version, workflow_def)
                end
              end).()

        new_state = %{
          state
          | workflows: Map.put(state.workflows, name, updated_workflows),
            version_counters: Map.put(state.version_counters, name, new_version)
        }

        Logger.info(
          "Updated workflow '#{name}' to version #{new_version} for client '#{definition_params.client_id}' (active: #{make_active})"
        )

        {:reply, {:ok, new_version}, new_state}
    end
  end

  defp get_active_workflow(name, state) do
    case Map.get(state.workflows, name) do
      nil ->
        {:error, :not_found}

      versions ->
        case Enum.find(versions, fn {_v, def} -> def.is_active end) do
          {_version, workflow_def} ->
            {:ok, workflow_def}

          nil ->
            {:error, :not_found}
        end
    end
  end

  defp get_workflow_version(name, version, state) do
    case get_in(state.workflows, [name, version]) do
      nil ->
        {:error, :not_found}

      workflow_def ->
        {:ok, workflow_def}
    end
  end

  defp list_active_workflows(state) do
    state.workflows
    |> Enum.flat_map(fn {_name, versions} ->
      Enum.filter(versions, fn {_v, def} -> def.is_active end)
    end)
    |> Enum.map(fn {_version, def} -> def end)
    |> Enum.sort_by(& &1.name)
  end

  defp set_active_version_impl(name, version, state) do
    case get_in(state.workflows, [name, version]) do
      nil ->
        {:error, :version_not_found}

      _workflow_def ->
        # Deactivate all versions and activate the specified one
        updated_versions =
          state.workflows[name]
          |> Enum.map(fn {v, def} ->
            {v, %{def | is_active: v == version}}
          end)
          |> Map.new()

        new_state = put_in(state.workflows[name], updated_versions)

        Logger.info("Set workflow '#{name}' version #{version} as active")
        {:ok, new_state}
    end
  end

  defp record_usage_impl(name, version, state) do
    target_version = version || get_active_version_number(name, state)

    case target_version do
      nil ->
        state

      v ->
        now = DateTime.utc_now()

        case get_in(state.workflows, [name, v]) do
          nil ->
            state

          workflow_def ->
            updated_def = %{
              workflow_def
              | usage_count: workflow_def.usage_count + 1,
                last_used_at: now
            }

            put_in(state.workflows[name][v], updated_def)
        end
    end
  end

  defp get_active_version_number(name, state) do
    case get_active_workflow(name, state) do
      {:ok, workflow_def} -> workflow_def.version
      {:error, :not_found} -> nil
    end
  end

  defp calculate_stats(state) do
    total_workflows = map_size(state.workflows)

    total_versions =
      state.workflows
      |> Map.values()
      |> Enum.map(&map_size/1)
      |> Enum.sum()

    total_usage =
      state.workflows
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.map(& &1.usage_count)
      |> Enum.sum()

    clients =
      state.workflows
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.map(& &1.client_id)
      |> Enum.uniq()
      |> length()

    %{
      total_workflows: total_workflows,
      total_versions: total_versions,
      total_usage: total_usage,
      unique_clients: clients
    }
  end
end
