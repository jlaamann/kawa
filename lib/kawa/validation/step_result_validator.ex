defmodule Kawa.Validation.StepResultValidator do
  @moduledoc """
  Validates step results and handles errors with sophisticated validation rules.

  This module provides comprehensive validation for step execution results,
  including schema validation, business rule validation, and error classification.
  """

  @type validation_result :: :ok | {:error, [validation_error()]}
  @type validation_error :: %{
          type: atom(),
          field: String.t() | nil,
          message: String.t(),
          details: map()
        }

  @doc """
  Validates a step result against its schema and business rules.

  Returns `:ok` if valid, `{:error, errors}` if validation fails.

  ## Examples

      iex> schema = %{"type" => "object", "required" => ["user_id"]}
      iex> result = %{"user_id" => 123}
      iex> Kawa.StepResultValidator.validate_result(result, schema)
      :ok

      iex> result = %{"name" => "Alice"}
      iex> Kawa.StepResultValidator.validate_result(result, schema)
      {:error, [%{type: :missing_required, field: "user_id", message: "Required field missing", details: %{}}]}
  """
  def validate_result(result, schema, opts \\ []) do
    validators = [
      &validate_basic_structure/2,
      &validate_schema_compliance/2,
      # TODO: business rules can't be set yet
      &validate_business_rules/2,
      &validate_data_types/2,
      &validate_constraints/2
    ]

    context = %{
      result: result,
      schema: schema,
      opts: opts,
      errors: []
    }

    case run_validators(validators, context) do
      %{errors: []} -> :ok
      %{errors: errors} -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Validates step input before execution.

  Similar to result validation but focuses on input validation rules.
  """
  def validate_input(input, step_definition, context \\ %{}) do
    input_schema = get_input_schema(step_definition)

    case validate_result(input, input_schema, context: context) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_input, errors}}
    end
  end

  @doc """
  Validates error responses from step execution.

  Ensures error responses follow the expected format and contain required information.
  """
  def validate_error_response(error_response) do
    required_fields = ["type", "message"]

    errors = []

    # Check required fields
    errors =
      Enum.reduce(required_fields, errors, fn field, acc ->
        if Map.has_key?(error_response, field) do
          acc
        else
          [create_error(:missing_required, field, "Required error field missing") | acc]
        end
      end)

    # Validate field types
    errors = validate_error_field_types(error_response, errors)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Classifies an error as retryable or non-retryable.

  TODO: unused at the moment

  Returns `{:retryable, reason}` or `{:non_retryable, reason}`.
  """
  def classify_error(error) when is_map(error) do
    error_type = Map.get(error, "type", "unknown_error")
    error_code = Map.get(error, "code")
    retryable_hint = Map.get(error, "retryable")

    cond do
      # Explicit hint takes precedence
      is_boolean(retryable_hint) ->
        if retryable_hint do
          {:retryable, "explicit_hint"}
        else
          {:non_retryable, "explicit_hint"}
        end

      # Network and timeout errors are typically retryable
      error_type in ["timeout_error", "network_error", "connection_error"] ->
        {:retryable, "transient_infrastructure_error"}

      # Service unavailable errors are retryable
      error_code in ["SERVICE_UNAVAILABLE", "RATE_LIMITED", "CIRCUIT_BREAKER_OPEN"] ->
        {:retryable, "service_temporarily_unavailable"}

      # Validation and business logic errors are typically not retryable
      error_type in ["validation_error", "business_rule_violation", "authentication_error"] ->
        {:non_retryable, "deterministic_error"}

      # Unknown errors default to non-retryable for safety
      true ->
        {:non_retryable, "unknown_error_type"}
    end
  end

  @doc """
  Creates a standardized error response.

  Ensures consistent error format across the system.
  """
  def create_error_response(type, message, opts \\ []) do
    %{
      "type" => to_string(type),
      "message" => message,
      "code" => Keyword.get(opts, :code),
      "details" => Keyword.get(opts, :details, %{}),
      "retryable" => Keyword.get(opts, :retryable, false),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Validates saga context data for consistency and completeness.

  Ensures the context contains all required data for subsequent steps.
  """
  def validate_context(context, required_keys \\ []) do
    errors = []

    # Check for required keys
    errors =
      Enum.reduce(required_keys, errors, fn key, acc ->
        if Map.has_key?(context, key) do
          acc
        else
          [create_error(:missing_context_key, key, "Required context key missing") | acc]
        end
      end)

    # Validate context structure
    errors = validate_context_structure(context, errors)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Sanitizes step results by removing sensitive data and normalizing format.

  Ensures no sensitive information leaks through saga context.
  """
  def sanitize_result(result, sanitization_rules \\ []) do
    result
    |> remove_sensitive_fields(sanitization_rules)
    |> normalize_data_types()
    |> validate_size_limits()
  end

  @doc """
  Validates step execution performance metrics.

  Checks if execution time and resource usage are within acceptable limits.
  """
  def validate_performance_metrics(metrics, limits \\ %{}) do
    errors = []

    # Check execution time
    # 5 minutes default
    max_execution_time = Map.get(limits, :max_execution_time_ms, 300_000)
    execution_time = Map.get(metrics, :execution_time_ms, 0)

    errors =
      if execution_time > max_execution_time do
        [
          create_error(
            :performance_violation,
            "execution_time_ms",
            "Execution time #{execution_time}ms exceeds limit #{max_execution_time}ms"
          )
          | errors
        ]
      else
        errors
      end

    # Check memory usage if provided
    # 1GB default
    max_memory = Map.get(limits, :max_memory_mb, 1000)
    memory_usage = Map.get(metrics, :memory_usage_mb)

    errors =
      if memory_usage && memory_usage > max_memory do
        [
          create_error(
            :performance_violation,
            "memory_usage_mb",
            "Memory usage #{memory_usage}MB exceeds limit #{max_memory}MB"
          )
          | errors
        ]
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  # Private functions

  defp run_validators(validators, context) do
    Enum.reduce(validators, context, fn validator, acc ->
      if acc.errors == [] do
        validator.(acc.result, acc)
      else
        # Skip remaining validators if errors found
        acc
      end
    end)
  end

  defp validate_basic_structure(result, context) when is_map(result) do
    # Basic structure is valid for maps
    context
  end

  defp validate_basic_structure(_result, context) do
    error = create_error(:invalid_structure, nil, "Result must be a map")
    %{context | errors: [error | context.errors]}
  end

  defp validate_schema_compliance(_result, %{schema: nil} = context) do
    # No schema provided, skip validation
    context
  end

  defp validate_schema_compliance(result, %{schema: schema} = context) do
    case validate_json_schema(result, schema) do
      :ok ->
        context

      {:error, schema_errors} ->
        errors = Enum.map(schema_errors, &convert_schema_error/1)
        %{context | errors: errors ++ context.errors}
    end
  end

  defp validate_business_rules(result, context) do
    business_rules = get_business_rules(context.schema)

    rule_errors =
      Enum.reduce(business_rules, [], fn rule, acc ->
        case apply_business_rule(rule, result, context) do
          :ok -> acc
          {:error, error} -> [error | acc]
        end
      end)

    %{context | errors: rule_errors ++ context.errors}
  end

  defp validate_data_types(result, context) do
    type_errors = validate_field_types(result, Map.get(context.schema, "properties", %{}))
    %{context | errors: type_errors ++ context.errors}
  end

  defp validate_constraints(result, context) do
    constraint_errors = validate_field_constraints(result, context.schema)
    %{context | errors: constraint_errors ++ context.errors}
  end

  defp validate_json_schema(data, schema) do
    # Simplified JSON schema validation
    # In a real implementation, you'd use a proper JSON schema library
    required_fields = Map.get(schema, "required", [])

    missing_fields =
      Enum.filter(required_fields, fn field ->
        !Map.has_key?(data, field)
      end)

    if missing_fields == [] do
      :ok
    else
      {:error,
       Enum.map(missing_fields, fn field ->
         %{field: field, type: :missing_required}
       end)}
    end
  end

  defp convert_schema_error(%{field: field, type: type}) do
    create_error(type, field, "Schema validation failed for field #{field}")
  end

  defp get_business_rules(schema) do
    Map.get(schema, "business_rules", [])
  end

  defp apply_business_rule(rule, result, _context) do
    # Simplified business rule application
    case rule do
      %{"type" => "positive_amount", "field" => field} ->
        amount = Map.get(result, field)

        if is_number(amount) && amount > 0 do
          :ok
        else
          {:error, create_error(:business_rule_violation, field, "Amount must be positive")}
        end

      %{"type" => "valid_email", "field" => field} ->
        email = Map.get(result, field)

        if is_binary(email) && String.contains?(email, "@") do
          :ok
        else
          {:error, create_error(:business_rule_violation, field, "Invalid email format")}
        end

      _ ->
        :ok
    end
  end

  defp validate_field_types(data, properties) when is_map(data) and is_map(properties) do
    Enum.reduce(properties, [], fn {field, field_schema}, errors ->
      case Map.get(data, field) do
        # Field not present, handled by required validation
        nil ->
          errors

        value ->
          expected_type = Map.get(field_schema, "type")

          if validate_type(value, expected_type) do
            errors
          else
            error =
              create_error(
                :type_mismatch,
                field,
                "Expected #{expected_type}, got #{get_value_type(value)}"
              )

            [error | errors]
          end
      end
    end)
  end

  defp validate_field_types(_data, _properties), do: []

  defp validate_type(value, "string"), do: is_binary(value)
  defp validate_type(value, "integer"), do: is_integer(value)
  defp validate_type(value, "number"), do: is_number(value)
  defp validate_type(value, "boolean"), do: is_boolean(value)
  defp validate_type(value, "array"), do: is_list(value)
  defp validate_type(value, "object"), do: is_map(value)
  # Unknown type, allow
  defp validate_type(_value, _type), do: true

  defp get_value_type(value) when is_binary(value), do: "string"
  defp get_value_type(value) when is_integer(value), do: "integer"
  defp get_value_type(value) when is_float(value), do: "number"
  defp get_value_type(value) when is_boolean(value), do: "boolean"
  defp get_value_type(value) when is_list(value), do: "array"
  defp get_value_type(value) when is_map(value), do: "object"
  defp get_value_type(_value), do: "unknown"

  defp validate_field_constraints(_data, _schema) do
    # Simplified constraint validation
    # Real implementation would handle more constraint types
    []
  end

  defp validate_error_field_types(error_response, errors) do
    # Validate error type is string
    errors =
      if Map.has_key?(error_response, "type") &&
           !is_binary(error_response["type"]) do
        [create_error(:type_mismatch, "type", "Error type must be string") | errors]
      else
        errors
      end

    # Validate retryable is boolean if present
    errors =
      if Map.has_key?(error_response, "retryable") &&
           !is_boolean(error_response["retryable"]) do
        [create_error(:type_mismatch, "retryable", "Retryable must be boolean") | errors]
      else
        errors
      end

    errors
  end

  defp validate_context_structure(context, errors) when is_map(context) do
    # Context should not contain reserved keys
    reserved_keys = ["_metadata", "_internal"]

    Enum.reduce(reserved_keys, errors, fn key, acc ->
      if Map.has_key?(context, key) do
        [create_error(:reserved_key_usage, key, "Reserved context key used") | acc]
      else
        acc
      end
    end)
  end

  defp validate_context_structure(_context, errors) do
    [create_error(:invalid_structure, nil, "Context must be a map") | errors]
  end

  defp remove_sensitive_fields(result, sanitization_rules) do
    sensitive_patterns =
      Keyword.get(
        sanitization_rules,
        :sensitive_patterns,
        ~w(password secret token key credential)
      )

    Enum.reduce(result, %{}, fn {key, value}, acc ->
      if Enum.any?(sensitive_patterns, fn pattern ->
           String.contains?(String.downcase(key), pattern)
         end) do
        Map.put(acc, key, "[REDACTED]")
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_data_types(result) when is_map(result) do
    # Normalize data types for consistency
    result
  end

  defp normalize_data_types(result), do: result

  defp validate_size_limits(result) do
    # Check if result is within size limits
    serialized_size = byte_size(:erlang.term_to_binary(result))
    # 1MB limit
    max_size = 1_000_000

    if serialized_size > max_size do
      %{"error" => "Result too large", "size_bytes" => serialized_size, "max_bytes" => max_size}
    else
      result
    end
  end

  defp get_input_schema(step_definition) do
    Map.get(step_definition, "input_schema", %{})
  end

  defp create_error(type, field, message, details \\ %{}) do
    %{
      type: type,
      field: field,
      message: message,
      details: details
    }
  end
end
