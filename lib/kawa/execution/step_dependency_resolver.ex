defmodule Kawa.Execution.StepDependencyResolver do
  @moduledoc """
  Resolves step dependencies using topological sorting to determine execution order.

  This module ensures that steps are executed in the correct order based on their
  dependencies, preventing deadlocks and ensuring data flow integrity.
  """

  alias Kawa.Utils.TopologicalSort

  @doc """
  Performs topological sort on workflow steps based on their dependencies.

  Returns `{:ok, sorted_steps}` if successful, or `{:error, :circular_dependency}`
  if a circular dependency is detected.

  ## Examples

      iex> steps = [
      ...>   %{"id" => "step1", "depends_on" => []},
      ...>   %{"id" => "step2", "depends_on" => ["step1"]},
      ...>   %{"id" => "step3", "depends_on" => ["step1", "step2"]}
      ...> ]
      iex> Kawa.StepDependencyResolver.topological_sort(steps)
      {:ok, ["step1", "step2", "step3"]}
  """
  def topological_sort(steps) when is_list(steps) do
    case TopologicalSort.sort(steps) do
      {:ok, sorted} -> {:ok, sorted}
      {:error, :circular_dependency} -> {:error, :circular_dependency}
    end
  end

  @doc """
  Finds all steps that are ready to execute given current completed steps.

  Returns a list of step IDs that have all their dependencies satisfied.

  ## Examples

      iex> steps = [
      ...>   %{"id" => "step1", "depends_on" => []},
      ...>   %{"id" => "step2", "depends_on" => ["step1"]},
      ...>   %{"id" => "step3", "depends_on" => ["step1"]}
      ...> ]
      iex> completed = MapSet.new(["step1"])
      iex> Kawa.StepDependencyResolver.find_ready_to_execute_steps(steps, completed)
      ["step2", "step3"]
  """
  def find_ready_to_execute_steps(steps, completed_steps) when is_list(steps) do
    completed_set =
      if is_list(completed_steps), do: MapSet.new(completed_steps), else: completed_steps

    steps
    |> Enum.filter(fn step ->
      step_id = step["id"]
      dependencies = Map.get(step, "depends_on", [])

      # Step is ready if not already completed and all dependencies are satisfied
      !MapSet.member?(completed_set, step_id) &&
        Enum.all?(dependencies, &MapSet.member?(completed_set, &1))
    end)
    |> Enum.map(fn step -> step["id"] end)
  end

  @doc """
  Validates workflow step dependencies for common issues.

  Returns `:ok` if valid, or `{:error, errors}` with a list of validation errors.
  """
  def validate_dependencies(steps) when is_list(steps) do
    errors = []

    # Check for circular dependencies
    errors =
      case TopologicalSort.validate_acyclic(steps) do
        :ok -> errors
        {:error, _cycles} -> ["Circular dependency detected" | errors]
      end

    # Check for missing dependencies
    step_ids = MapSet.new(steps, fn step -> step["id"] end)
    missing_deps = find_missing_dependencies(steps, step_ids)

    errors =
      if missing_deps == [],
        do: errors,
        else: ["Missing dependencies: #{Enum.join(missing_deps, ", ")}" | errors]

    # Check for duplicate step IDs
    duplicate_ids = find_duplicate_step_ids(steps)

    errors =
      if duplicate_ids == [],
        do: errors,
        else: ["Duplicate step IDs: #{Enum.join(duplicate_ids, ", ")}" | errors]

    # Check for self-dependencies
    self_deps = find_self_dependencies(steps)

    errors =
      if self_deps == [],
        do: errors,
        else: ["Self-referencing dependencies: #{Enum.join(self_deps, ", ")}" | errors]

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @doc """
  Builds an execution plan with parallel execution levels.

  Returns a list of lists, where each inner list contains steps that can be executed in parallel.

  ## Examples

      iex> steps = [
      ...>   %{"id" => "step1", "depends_on" => []},
      ...>   %{"id" => "step2", "depends_on" => []},
      ...>   %{"id" => "step3", "depends_on" => ["step1", "step2"]}
      ...> ]
      iex> Kawa.StepDependencyResolver.build_execution_levels(steps)
      {:ok, [["step1", "step2"], ["step3"]]}
  """
  def build_execution_levels(steps) when is_list(steps) do
    case validate_dependencies(steps) do
      :ok ->
        levels = build_levels(steps)
        {:ok, levels}

      {:error, _} = error ->
        error
    end
  end

  # Private functions

  defp find_missing_dependencies(steps, step_ids) do
    steps
    |> Enum.flat_map(fn step ->
      dependencies = Map.get(step, "depends_on", [])
      Enum.filter(dependencies, fn dep -> !MapSet.member?(step_ids, dep) end)
    end)
    |> Enum.uniq()
  end

  defp find_duplicate_step_ids(steps) do
    steps
    |> Enum.map(fn step -> step["id"] end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
  end

  defp find_self_dependencies(steps) do
    steps
    |> Enum.filter(fn step ->
      step_id = step["id"]
      dependencies = Map.get(step, "depends_on", [])
      step_id in dependencies
    end)
    |> Enum.map(fn step -> step["id"] end)
  end

  defp build_levels(steps) do
    # Use topological sort to determine execution levels
    case topological_sort(steps) do
      {:ok, sorted_steps} ->
        build_parallel_levels(steps, sorted_steps)

      {:error, _} ->
        []
    end
  end

  defp build_parallel_levels(steps, sorted_steps) do
    # Create dependency map for quick lookup
    dependency_map =
      steps
      |> Enum.into(%{}, fn step ->
        {step["id"], Map.get(step, "depends_on", [])}
      end)

    # Build execution levels
    {levels, _completed} =
      Enum.reduce(sorted_steps, {[], MapSet.new()}, fn step_id, {levels, completed} ->
        dependencies = Map.get(dependency_map, step_id, [])

        # Find the level this step should be in
        max_dep_level =
          dependencies
          |> Enum.map(fn dep -> find_step_level(dep, levels) end)
          |> Enum.max(fn -> -1 end)

        target_level = max_dep_level + 1

        # Add step to appropriate level
        levels = ensure_level_exists(levels, target_level)
        levels = add_step_to_level(levels, step_id, target_level)

        {levels, MapSet.put(completed, step_id)}
      end)

    levels
  end

  defp find_step_level(step_id, levels) do
    levels
    |> Enum.with_index()
    |> Enum.find_value(-1, fn {level_steps, index} ->
      if step_id in level_steps, do: index, else: nil
    end)
  end

  defp ensure_level_exists(levels, target_level) do
    current_levels = length(levels)

    if target_level >= current_levels do
      levels ++ List.duplicate([], target_level - current_levels + 1)
    else
      levels
    end
  end

  defp add_step_to_level(levels, step_id, level) do
    List.update_at(levels, level, fn level_steps -> [step_id | level_steps] end)
  end
end
