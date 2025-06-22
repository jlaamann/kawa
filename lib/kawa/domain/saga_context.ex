defmodule Kawa.Domain.SagaContext do
  @moduledoc """
  Manages saga execution context and data flow between steps.

  The context accumulates results from completed steps and provides
  input data for subsequent steps, enabling data flow through the saga.
  """

  @type t :: %{
          String.t() => any(),
          optional(:_metadata) => map()
        }

  @doc """
  Creates a new empty saga context.

  ## Examples

      iex> Kawa.Domain.SagaContext.new()
      %{}

      iex> Kawa.Domain.SagaContext.new(%{initial_data: "value"})
      %{initial_data: "value"}
  """
  def new(initial_data \\ %{}) when is_map(initial_data) do
    initial_data
  end

  @doc """
  Adds a step result to the context.

  Step results are stored with the step ID as the key.

  ## Examples

      iex> context = %{}
      iex> Kawa.Domain.SagaContext.add_step_result(context, "step1", %{result: "success"})
      %{"step1" => %{result: "success"}}
  """
  def add_step_result(context, step_id, result) when is_map(context) and is_binary(step_id) do
    Map.put(context, step_id, result)
  end

  @doc """
  Gets a step result from the context.

  Returns the result if found, `nil` otherwise.

  ## Examples

      iex> context = %{"step1" => %{result: "success"}}
      iex> Kawa.Domain.SagaContext.get_step_result(context, "step1")
      %{result: "success"}

      iex> Kawa.Domain.SagaContext.get_step_result(context, "nonexistent")
      nil
  """
  def get_step_result(context, step_id) when is_map(context) and is_binary(step_id) do
    Map.get(context, step_id)
  end

  @doc """
  Gets a step result with a default value.

  ## Examples

      iex> context = %{}
      iex> Kawa.Domain.SagaContext.get_step_result(context, "step1", %{default: true})
      %{default: true}
  """
  def get_step_result(context, step_id, default) when is_map(context) and is_binary(step_id) do
    Map.get(context, step_id, default)
  end

  @doc """
  Builds input for a step based on the context and step definition.

  Merges step-specific input with relevant context data based on dependencies.

  ## Examples

      iex> context = %{"step1" => %{user_id: 123}}
      iex> step_def = %{"input" => %{action: "create"}, "depends_on" => ["step1"]}
      iex> Kawa.Domain.SagaContext.build_step_input(context, step_def)
      %{action: "create", user_id: 123}
  """
  def build_step_input(context, step_definition)
      when is_map(context) and is_map(step_definition) do
    base_input = Map.get(step_definition, "input", %{})
    dependencies = Map.get(step_definition, "depends_on", [])

    # Collect results from dependency steps
    dependency_data =
      dependencies
      |> Enum.reduce(%{}, fn dep_step, acc ->
        case get_step_result(context, dep_step) do
          nil -> acc
          result -> Map.merge(acc, flatten_result(result, dep_step))
        end
      end)

    # Merge: base input overrides dependency data
    Map.merge(dependency_data, base_input)
  end

  @doc """
  Extracts specific values from the context based on a path.

  Supports dot notation for nested access.

  ## Examples

      iex> context = %{"step1" => %{user: %{id: 123, name: "Alice"}}}
      iex> Kawa.Domain.SagaContext.extract_value(context, "step1.user.id")
      123

      iex> Kawa.Domain.SagaContext.extract_value(context, "step1.user.email", "default@example.com")
      "default@example.com"
  """
  def extract_value(context, path, default \\ nil) when is_map(context) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(context, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key)
        _ -> nil
      end
    end)
    |> case do
      nil -> default
      value -> value
    end
  end

  # Private functions

  defp flatten_result(result, step_id) when is_map(result) do
    # Flatten nested maps and prefix with step ID to avoid conflicts
    result
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      flattened_key = "#{step_id}_#{key}"
      Map.put(acc, flattened_key, value)
    end)
  end

  defp flatten_result(result, step_id) do
    # For non-map results, store under step ID
    %{step_id => result}
  end
end
