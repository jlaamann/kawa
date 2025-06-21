defmodule Kawa.Utils.TopologicalSort do
  @moduledoc """
  Shared topological sorting utilities using Kahn's algorithm.

  This module provides a unified implementation of topological sorting
  to avoid code duplication between different validation modules.
  """

  @doc """
  Performs topological sort using Kahn's algorithm.

  Returns `{:ok, sorted_nodes}` if successful, or `{:error, :circular_dependency}` 
  if a circular dependency is detected.

  ## Examples

      iex> graph = %{"a" => ["b"], "b" => ["c"], "c" => []}
      iex> Kawa.Utils.TopologicalSort.sort(graph)
      {:ok, ["c", "b", "a"]}
      
      iex> circular = %{"a" => ["b"], "b" => ["a"]}
      iex> Kawa.Utils.TopologicalSort.sort(circular)
      {:error, :circular_dependency}
  """
  def sort(graph) when is_map(graph) do
    in_degrees = calculate_in_degrees(graph)

    queue =
      graph
      |> Map.keys()
      |> Enum.filter(fn node -> Map.get(in_degrees, node, 0) == 0 end)
      |> :queue.from_list()

    process_nodes(queue, graph, in_degrees, [])
  end

  def sort(steps) when is_list(steps) do
    graph = build_dependency_graph(steps)
    sort(graph)
  end

  @doc """
  Detects cycles in a dependency graph.

  Returns a list of cycles found in the graph. Each cycle is represented
  as a list of nodes forming the cycle.

  ## Examples

      iex> graph = %{"a" => ["b"], "b" => ["a"]}
      iex> Kawa.Utils.TopologicalSort.detect_cycles(graph)
      [["a", "b"]]
  """
  def detect_cycles(graph) when is_map(graph) do
    case sort(graph) do
      {:ok, _sorted} -> []
      {:error, :circular_dependency} -> find_all_cycles(graph)
    end
  end

  def detect_cycles(steps) when is_list(steps) do
    graph = build_dependency_graph(steps)
    detect_cycles(graph)
  end

  @doc """
  Validates that a dependency graph has no circular dependencies.

  Returns `:ok` if valid, `{:error, cycles}` if cycles are found.
  """
  def validate_acyclic(graph) when is_map(graph) do
    case detect_cycles(graph) do
      [] -> :ok
      cycles -> {:error, cycles}
    end
  end

  def validate_acyclic(steps) when is_list(steps) do
    graph = build_dependency_graph(steps)
    validate_acyclic(graph)
  end

  # Private functions

  defp build_dependency_graph(steps) do
    steps
    |> Enum.reduce(%{}, fn step, acc ->
      step_id = step["id"]
      dependencies = Map.get(step, "depends_on", [])
      Map.put(acc, step_id, dependencies)
    end)
  end

  defp calculate_in_degrees(graph) do
    # Initialize all nodes with 0 in-degree
    initial_degrees = Map.new(graph, fn {node, _} -> {node, 0} end)

    # Count incoming edges
    Enum.reduce(graph, initial_degrees, fn {_node, deps}, acc ->
      Enum.reduce(deps, acc, fn dep, acc2 ->
        Map.update(acc2, dep, 1, &(&1 + 1))
      end)
    end)
  end

  defp process_nodes(queue, graph, in_degrees, sorted) do
    case :queue.out(queue) do
      {{:value, node}, new_queue} ->
        new_sorted = [node | sorted]
        dependencies = Map.get(graph, node, [])

        {updated_queue, updated_degrees} =
          Enum.reduce(dependencies, {new_queue, in_degrees}, fn dep, {q, degrees} ->
            new_degree = Map.get(degrees, dep, 0) - 1
            new_degrees = Map.put(degrees, dep, new_degree)

            if new_degree == 0 do
              {:queue.in(dep, q), new_degrees}
            else
              {q, new_degrees}
            end
          end)

        process_nodes(updated_queue, graph, updated_degrees, new_sorted)

      {:empty, _} ->
        if length(sorted) == map_size(graph) do
          {:ok, sorted}
        else
          {:error, :circular_dependency}
        end
    end
  end

  defp find_all_cycles(graph) do
    # Find all strongly connected components to identify cycles
    # This is a simplified implementation - in production you might want
    # to use Tarjan's algorithm for better cycle detection
    all_nodes = Map.keys(graph)
    find_cycles_dfs(graph, all_nodes, MapSet.new(), [])
  end

  defp find_cycles_dfs(_graph, [], _visited, cycles), do: cycles

  defp find_cycles_dfs(graph, [node | rest], global_visited, cycles) do
    if MapSet.member?(global_visited, node) do
      find_cycles_dfs(graph, rest, global_visited, cycles)
    else
      case find_cycle_from_node(graph, node, [node], MapSet.new([node])) do
        nil ->
          new_visited = MapSet.put(global_visited, node)
          find_cycles_dfs(graph, rest, new_visited, cycles)

        cycle ->
          new_visited = MapSet.union(global_visited, MapSet.new(cycle))
          find_cycles_dfs(graph, rest, new_visited, [cycle | cycles])
      end
    end
  end

  defp find_cycle_from_node(graph, current, path, visited) do
    deps = Map.get(graph, current, [])

    Enum.find_value(deps, fn dep ->
      cond do
        dep in path ->
          # Found cycle - return the cycle portion
          Enum.drop_while(path, &(&1 != dep))

        MapSet.member?(visited, dep) ->
          nil

        true ->
          new_visited = MapSet.put(visited, dep)
          find_cycle_from_node(graph, dep, [dep | path], new_visited)
      end
    end)
  end
end
