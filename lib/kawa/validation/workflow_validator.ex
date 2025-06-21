defmodule Kawa.Validation.WorkflowValidator do
  @moduledoc """
  Validates workflow definitions to ensure they are valid saga configurations.

  This module provides comprehensive validation including:
  - JSON schema validation
  - Circular dependency detection using topological sorting
  - Step reference validation (depends_on)
  - Timeout and URL format validation
  - Detailed error messages with field/line information
  """

  alias Kawa.Utils.TopologicalSort

  @type validation_error :: %{
          field: String.t(),
          message: String.t(),
          line: integer() | nil,
          value: any()
        }

  @type validation_result :: {:ok, map()} | {:error, [validation_error()]}

  @doc """
  Validates a workflow definition (JSON or map format).

  ## Examples

      iex> workflow = %{
      ...>   "name" => "test-workflow",
      ...>   "steps" => [
      ...>     %{"id" => "step1", "type" => "http", "action" => %{"method" => "POST", "url" => "http://example.com"}}
      ...>   ]
      ...> }
      iex> Kawa.WorkflowValidator.validate(workflow)
      {:ok, workflow}

      iex> invalid_workflow = %{"name" => ""}
      iex> {:error, errors} = Kawa.WorkflowValidator.validate(invalid_workflow)
      iex> length(errors) > 0
      true
  """
  @spec validate(map() | String.t()) :: validation_result()
  def validate(workflow) when is_binary(workflow) do
    case Jason.decode(workflow) do
      {:ok, parsed_workflow} ->
        validate(parsed_workflow)

      {:error, %Jason.DecodeError{data: data, position: pos}} ->
        {:error,
         [
           %{
             field: "json",
             message: "Invalid JSON format at position #{pos}",
             line: calculate_line_number(data, pos),
             value: data
           }
         ]}
    end
  end

  def validate(workflow) when is_map(workflow) do
    errors = []

    errors
    |> validate_required_fields(workflow)
    |> validate_workflow_metadata(workflow)
    |> validate_steps(workflow)
    |> validate_step_dependencies(workflow)
    |> validate_circular_dependencies(workflow)
    |> case do
      [] -> {:ok, workflow}
      validation_errors -> {:error, validation_errors}
    end
  end

  def validate(_),
    do:
      {:error,
       [%{field: "root", message: "Workflow must be a map or JSON string", line: nil, value: nil}]}

  ## Private Validation Functions

  defp validate_required_fields(errors, workflow) do
    required_fields = ["name", "steps"]

    Enum.reduce(required_fields, errors, fn field, acc ->
      case Map.get(workflow, field) do
        nil -> [%{field: field, message: "is required", line: nil, value: nil} | acc]
        "" -> [%{field: field, message: "cannot be empty", line: nil, value: ""} | acc]
        _ -> acc
      end
    end)
  end

  defp validate_workflow_metadata(errors, workflow) do
    errors
    |> validate_workflow_name(workflow)
    |> validate_workflow_description(workflow)
    |> validate_workflow_timeout(workflow)
  end

  defp validate_workflow_name(errors, workflow) do
    case Map.get(workflow, "name") do
      name when is_binary(name) and byte_size(name) > 0 ->
        if String.match?(name, ~r/^[a-zA-Z0-9_-]+$/) do
          errors
        else
          [
            %{
              field: "name",
              message: "must contain only alphanumeric characters, hyphens, and underscores",
              line: nil,
              value: name
            }
            | errors
          ]
        end

      name when is_binary(name) ->
        [%{field: "name", message: "cannot be empty", line: nil, value: name} | errors]

      name ->
        [%{field: "name", message: "must be a string", line: nil, value: name} | errors]
    end
  end

  defp validate_workflow_description(errors, workflow) do
    case Map.get(workflow, "description") do
      # Optional field
      nil ->
        errors

      desc when is_binary(desc) ->
        errors

      desc ->
        [%{field: "description", message: "must be a string", line: nil, value: desc} | errors]
    end
  end

  defp validate_workflow_timeout(errors, workflow) do
    case Map.get(workflow, "timeout") do
      # Optional field
      nil ->
        errors

      timeout when is_binary(timeout) ->
        case parse_timeout(timeout) do
          {:ok, _} ->
            errors

          {:error, message} ->
            [%{field: "timeout", message: message, line: nil, value: timeout} | errors]
        end

      timeout ->
        [%{field: "timeout", message: "must be a string", line: nil, value: timeout} | errors]
    end
  end

  defp validate_steps(errors, workflow) do
    case Map.get(workflow, "steps") do
      steps when is_list(steps) ->
        if length(steps) > 0 do
          steps
          |> Enum.with_index()
          |> Enum.reduce(errors, fn {step, index}, acc ->
            validate_step(acc, step, index)
          end)
          |> validate_step_ids_unique(steps)
        else
          [
            %{field: "steps", message: "must contain at least one step", line: nil, value: steps}
            | errors
          ]
        end

      steps ->
        [%{field: "steps", message: "must be an array", line: nil, value: steps} | errors]
    end
  end

  defp validate_step(errors, step, index) when is_map(step) do
    step_path = "steps[#{index}]"

    errors
    |> validate_step_id(step, step_path)
    |> validate_step_type(step, step_path)
    |> validate_step_action(step, step_path)
    |> validate_step_compensation(step, step_path)
    |> validate_step_timeout(step, step_path)
    |> validate_step_depends_on(step, step_path)
  end

  defp validate_step(errors, step, index) do
    [%{field: "steps[#{index}]", message: "must be an object", line: nil, value: step} | errors]
  end

  defp validate_step_id(errors, step, step_path) do
    case Map.get(step, "id") do
      id when is_binary(id) and byte_size(id) > 0 ->
        if String.match?(id, ~r/^[a-zA-Z0-9_-]+$/) do
          errors
        else
          [
            %{
              field: "#{step_path}.id",
              message: "must contain only alphanumeric characters, hyphens, and underscores",
              line: nil,
              value: id
            }
            | errors
          ]
        end

      id when is_binary(id) ->
        [%{field: "#{step_path}.id", message: "cannot be empty", line: nil, value: id} | errors]

      nil ->
        [%{field: "#{step_path}.id", message: "is required", line: nil, value: nil} | errors]

      id ->
        [%{field: "#{step_path}.id", message: "must be a string", line: nil, value: id} | errors]
    end
  end

  defp validate_step_type(errors, step, step_path) do
    valid_types = ["http", "elixir"]

    case Map.get(step, "type") do
      type when type in ["http", "elixir"] ->
        errors

      nil ->
        [%{field: "#{step_path}.type", message: "is required", line: nil, value: nil} | errors]

      type ->
        [
          %{
            field: "#{step_path}.type",
            message: "must be one of: #{Enum.join(valid_types, ", ")}",
            line: nil,
            value: type
          }
          | errors
        ]
    end
  end

  defp validate_step_action(errors, step, step_path) do
    case Map.get(step, "action") do
      nil ->
        [%{field: "#{step_path}.action", message: "is required", line: nil, value: nil} | errors]

      action when is_map(action) ->
        validate_action_by_type(errors, action, Map.get(step, "type"), "#{step_path}.action")

      action ->
        [
          %{field: "#{step_path}.action", message: "must be an object", line: nil, value: action}
          | errors
        ]
    end
  end

  defp validate_action_by_type(errors, action, "http", action_path) do
    errors
    |> validate_http_method(action, action_path)
    |> validate_http_url(action, action_path)
    |> validate_http_body(action, action_path)
  end

  defp validate_action_by_type(errors, action, "elixir", action_path) do
    errors
    |> validate_elixir_module(action, action_path)
    |> validate_elixir_function(action, action_path)
    |> validate_elixir_args(action, action_path)
  end

  defp validate_action_by_type(errors, _action, _type, _action_path), do: errors

  defp validate_http_method(errors, action, action_path) do
    valid_methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    case Map.get(action, "method") do
      method when method in ["GET", "POST", "PUT", "PATCH", "DELETE"] ->
        errors

      nil ->
        [
          %{
            field: "#{action_path}.method",
            message: "is required for HTTP actions",
            line: nil,
            value: nil
          }
          | errors
        ]

      method ->
        [
          %{
            field: "#{action_path}.method",
            message: "must be one of: #{Enum.join(valid_methods, ", ")}",
            line: nil,
            value: method
          }
          | errors
        ]
    end
  end

  defp validate_http_url(errors, action, action_path) do
    case Map.get(action, "url") do
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            errors

          _ ->
            [
              %{
                field: "#{action_path}.url",
                message: "must be a valid HTTP/HTTPS URL",
                line: nil,
                value: url
              }
              | errors
            ]
        end

      nil ->
        [
          %{
            field: "#{action_path}.url",
            message: "is required for HTTP actions",
            line: nil,
            value: nil
          }
          | errors
        ]

      url ->
        [
          %{field: "#{action_path}.url", message: "must be a string", line: nil, value: url}
          | errors
        ]
    end
  end

  defp validate_http_body(errors, action, _action_path) do
    # Body is optional and can be any valid JSON structure
    case Map.get(action, "body") do
      nil -> errors
      # Any structure is valid for body
      _body -> errors
    end
  end

  defp validate_elixir_module(errors, action, action_path) do
    case Map.get(action, "module") do
      module when is_binary(module) and byte_size(module) > 0 ->
        errors

      nil ->
        [
          %{
            field: "#{action_path}.module",
            message: "is required for Elixir actions",
            line: nil,
            value: nil
          }
          | errors
        ]

      module ->
        [
          %{
            field: "#{action_path}.module",
            message: "must be a non-empty string",
            line: nil,
            value: module
          }
          | errors
        ]
    end
  end

  defp validate_elixir_function(errors, action, action_path) do
    case Map.get(action, "function") do
      func when is_binary(func) and byte_size(func) > 0 ->
        errors

      nil ->
        [
          %{
            field: "#{action_path}.function",
            message: "is required for Elixir actions",
            line: nil,
            value: nil
          }
          | errors
        ]

      func ->
        [
          %{
            field: "#{action_path}.function",
            message: "must be a non-empty string",
            line: nil,
            value: func
          }
          | errors
        ]
    end
  end

  defp validate_elixir_args(errors, action, action_path) do
    # Args is optional and can be any list structure
    case Map.get(action, "args") do
      nil ->
        errors

      args when is_list(args) ->
        errors

      args ->
        [
          %{field: "#{action_path}.args", message: "must be an array", line: nil, value: args}
          | errors
        ]
    end
  end

  defp validate_step_compensation(errors, step, step_path) do
    case Map.get(step, "compensation") do
      # Compensation is optional
      nil ->
        errors

      compensation when is_map(compensation) ->
        validate_action_by_type(
          errors,
          compensation,
          Map.get(step, "type"),
          "#{step_path}.compensation"
        )

      compensation ->
        [
          %{
            field: "#{step_path}.compensation",
            message: "must be an object",
            line: nil,
            value: compensation
          }
          | errors
        ]
    end
  end

  defp validate_step_timeout(errors, step, step_path) do
    case Map.get(step, "timeout") do
      # Optional field
      nil ->
        errors

      timeout when is_binary(timeout) ->
        case parse_timeout(timeout) do
          {:ok, _} ->
            errors

          {:error, message} ->
            [
              %{field: "#{step_path}.timeout", message: message, line: nil, value: timeout}
              | errors
            ]
        end

      timeout ->
        [
          %{field: "#{step_path}.timeout", message: "must be a string", line: nil, value: timeout}
          | errors
        ]
    end
  end

  defp validate_step_depends_on(errors, step, step_path) do
    case Map.get(step, "depends_on") do
      # Optional field
      nil ->
        errors

      deps when is_list(deps) ->
        Enum.reduce(deps, errors, fn dep, acc ->
          case dep do
            dep when is_binary(dep) and byte_size(dep) > 0 ->
              acc

            dep ->
              [
                %{
                  field: "#{step_path}.depends_on",
                  message: "all dependencies must be non-empty strings",
                  line: nil,
                  value: dep
                }
                | acc
              ]
          end
        end)

      deps ->
        [
          %{field: "#{step_path}.depends_on", message: "must be an array", line: nil, value: deps}
          | errors
        ]
    end
  end

  defp validate_step_ids_unique(errors, steps) do
    step_ids =
      steps
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.filter(&is_binary/1)

    duplicates =
      step_ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)

    case duplicates do
      [] ->
        errors

      dups ->
        Enum.reduce(dups, errors, fn dup_id, acc ->
          [
            %{field: "steps", message: "duplicate step ID: #{dup_id}", line: nil, value: dup_id}
            | acc
          ]
        end)
    end
  end

  defp validate_step_dependencies(errors, workflow) do
    steps = Map.get(workflow, "steps", [])

    # Only process if steps is actually a list
    if is_list(steps) do
      step_ids =
        steps
        |> Enum.filter(&is_map/1)
        |> MapSet.new(&Map.get(&1, "id"))

      steps
      |> Enum.filter(&is_map/1)
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {step, index}, acc ->
        case Map.get(step, "depends_on") do
          nil ->
            acc

          deps when is_list(deps) ->
            invalid_deps = Enum.reject(deps, &MapSet.member?(step_ids, &1))

            case invalid_deps do
              [] ->
                acc

              invalid ->
                Enum.reduce(invalid, acc, fn invalid_dep, acc2 ->
                  [
                    %{
                      field: "steps[#{index}].depends_on",
                      message: "references non-existent step: #{invalid_dep}",
                      line: nil,
                      value: invalid_dep
                    }
                    | acc2
                  ]
                end)
            end

          _ ->
            acc
        end
      end)
    else
      errors
    end
  end

  defp validate_circular_dependencies(errors, workflow) do
    steps = Map.get(workflow, "steps", [])

    # Only process if steps is actually a list
    if is_list(steps) do
      filtered_steps =
        steps
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn step ->
          %{
            "id" => Map.get(step, "id"),
            "depends_on" => Map.get(step, "depends_on", [])
          }
        end)

      case TopologicalSort.detect_cycles(filtered_steps) do
        [] ->
          errors

        cycles ->
          Enum.reduce(cycles, errors, fn cycle, acc ->
            cycle_str = Enum.join(cycle, " -> ")

            [
              %{
                field: "steps",
                message: "circular dependency detected: #{cycle_str}",
                line: nil,
                value: cycle
              }
              | acc
            ]
          end)
      end
    else
      errors
    end
  end

  defp parse_timeout(timeout_str) do
    case Regex.run(~r/^(\d+)(s|m|h)$/, timeout_str) do
      [_, number_str, unit] ->
        case Integer.parse(number_str) do
          {number, ""} when number > 0 ->
            case unit do
              "s" -> {:ok, number * 1000}
              "m" -> {:ok, number * 60 * 1000}
              "h" -> {:ok, number * 60 * 60 * 1000}
            end

          _ ->
            {:error, "timeout value must be a positive integer"}
        end

      _ ->
        {:error, "timeout must be in format like '30s', '5m', or '1h'"}
    end
  end

  defp calculate_line_number(data, position) do
    data
    |> String.slice(0, position)
    |> String.split("\n")
    |> length()
  end
end
