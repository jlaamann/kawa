defmodule Kawa.Validation.StepResultValidatorTest do
  use ExUnit.Case, async: true
  alias Kawa.Validation.StepResultValidator

  describe "validate_result/3" do
    test "validates successful result with valid schema" do
      schema = %{
        "type" => "object",
        "required" => ["user_id", "status"],
        "properties" => %{
          "user_id" => %{"type" => "integer"},
          "status" => %{"type" => "string"}
        }
      }

      result = %{"user_id" => 123, "status" => "active"}

      assert :ok = StepResultValidator.validate_result(result, schema)
    end

    test "validates result with missing required fields" do
      schema = %{
        "type" => "object",
        "required" => ["user_id", "email"]
      }

      result = %{"user_id" => 123}

      assert {:error, errors} = StepResultValidator.validate_result(result, schema)
      assert length(errors) >= 1

      # Find the missing_required error
      missing_error = Enum.find(errors, &(&1.type == :missing_required))
      assert missing_error != nil
      assert missing_error.field == "email"
    end

    test "validates result with type mismatches" do
      schema = %{
        "properties" => %{
          "user_id" => %{"type" => "integer"},
          "email" => %{"type" => "string"}
        }
      }

      result = %{"user_id" => "not_an_integer", "email" => 123}

      assert {:error, errors} = StepResultValidator.validate_result(result, schema)

      # Should have type mismatch errors
      type_errors = Enum.filter(errors, &(&1.type == :type_mismatch))
      assert length(type_errors) == 2
    end

    test "validates result with business rules" do
      schema = %{
        "business_rules" => [
          %{"type" => "positive_amount", "field" => "amount"},
          %{"type" => "valid_email", "field" => "email"}
        ]
      }

      # Valid result
      valid_result = %{"amount" => 100.50, "email" => "user@example.com"}
      assert :ok = StepResultValidator.validate_result(valid_result, schema)

      # Invalid amount
      invalid_amount = %{"amount" => -50, "email" => "user@example.com"}
      assert {:error, errors} = StepResultValidator.validate_result(invalid_amount, schema)

      business_error = Enum.find(errors, &(&1.type == :business_rule_violation))
      assert business_error != nil
      assert business_error.field == "amount"

      # Invalid email
      invalid_email = %{"amount" => 100, "email" => "invalid_email"}
      assert {:error, errors} = StepResultValidator.validate_result(invalid_email, schema)

      business_error = Enum.find(errors, &(&1.type == :business_rule_violation))
      assert business_error != nil
      assert business_error.field == "email"
    end

    test "validates result with no schema" do
      result = %{"any" => "data"}
      # Now the validator can handle nil schema
      assert :ok = StepResultValidator.validate_result(result, nil)
    end

    test "rejects non-map results" do
      schema = %{"type" => "object"}

      assert {:error, errors} = StepResultValidator.validate_result("string", schema)

      structure_error = Enum.find(errors, &(&1.type == :invalid_structure))
      assert structure_error != nil
      assert structure_error.message == "Result must be a map"
    end

    test "validates different data types correctly" do
      schema = %{
        "properties" => %{
          "string_field" => %{"type" => "string"},
          "integer_field" => %{"type" => "integer"},
          "number_field" => %{"type" => "number"},
          "boolean_field" => %{"type" => "boolean"},
          "array_field" => %{"type" => "array"},
          "object_field" => %{"type" => "object"}
        }
      }

      valid_result = %{
        "string_field" => "hello",
        "integer_field" => 42,
        "number_field" => 3.14,
        "boolean_field" => true,
        "array_field" => [1, 2, 3],
        "object_field" => %{"nested" => "value"}
      }

      assert :ok = StepResultValidator.validate_result(valid_result, schema)
    end

    test "handles unknown business rule types gracefully" do
      schema = %{
        "business_rules" => [
          %{"type" => "unknown_rule", "field" => "field"}
        ]
      }

      result = %{"field" => "value"}
      assert :ok = StepResultValidator.validate_result(result, schema)
    end
  end

  describe "validate_input/3" do
    test "validates input with schema" do
      step_definition = %{
        "input_schema" => %{
          "required" => ["order_id"],
          "properties" => %{
            "order_id" => %{"type" => "string"}
          }
        }
      }

      # Valid input
      valid_input = %{"order_id" => "ORD123"}
      assert :ok = StepResultValidator.validate_input(valid_input, step_definition)

      # Invalid input
      invalid_input = %{"amount" => 100}

      assert {:error, {:invalid_input, errors}} =
               StepResultValidator.validate_input(invalid_input, step_definition)

      assert length(errors) >= 1
    end

    test "validates input with no schema" do
      step_definition = %{}
      input = %{"any" => "data"}

      assert :ok = StepResultValidator.validate_input(input, step_definition)
    end

    test "validates input with context" do
      step_definition = %{"input_schema" => %{}}
      input = %{"data" => "value"}
      context = %{"saga_id" => "saga123"}

      assert :ok = StepResultValidator.validate_input(input, step_definition, context)
    end
  end

  describe "validate_error_response/1" do
    test "validates valid error response" do
      valid_error = %{
        "type" => "validation_error",
        "message" => "Invalid input provided",
        "code" => "VALIDATION_FAILED",
        "retryable" => false
      }

      assert :ok = StepResultValidator.validate_error_response(valid_error)
    end

    test "rejects error response missing required fields" do
      # Missing type
      missing_type = %{"message" => "Error occurred"}
      assert {:error, errors} = StepResultValidator.validate_error_response(missing_type)

      missing_error = Enum.find(errors, &(&1.type == :missing_required && &1.field == "type"))
      assert missing_error != nil

      # Missing message
      missing_message = %{"type" => "error"}
      assert {:error, errors} = StepResultValidator.validate_error_response(missing_message)

      missing_error = Enum.find(errors, &(&1.type == :missing_required && &1.field == "message"))
      assert missing_error != nil
    end

    test "validates error response field types" do
      # Invalid type field (not string)
      invalid_type = %{"type" => 123, "message" => "Error"}
      assert {:error, errors} = StepResultValidator.validate_error_response(invalid_type)

      type_error = Enum.find(errors, &(&1.type == :type_mismatch && &1.field == "type"))
      assert type_error != nil

      # Invalid retryable field (not boolean)
      invalid_retryable = %{"type" => "error", "message" => "Error", "retryable" => "yes"}
      assert {:error, errors} = StepResultValidator.validate_error_response(invalid_retryable)

      retryable_error = Enum.find(errors, &(&1.type == :type_mismatch && &1.field == "retryable"))
      assert retryable_error != nil
    end

    test "accepts optional fields" do
      minimal_error = %{"type" => "error", "message" => "Something went wrong"}
      assert :ok = StepResultValidator.validate_error_response(minimal_error)

      with_optional = %{
        "type" => "error",
        "message" => "Something went wrong",
        "code" => "ERR001",
        "details" => %{"extra" => "info"},
        "retryable" => true
      }

      assert :ok = StepResultValidator.validate_error_response(with_optional)
    end
  end

  describe "classify_error/1" do
    test "classifies retryable errors by explicit hint" do
      retryable_error = %{"type" => "some_error", "retryable" => true}
      assert {:retryable, "explicit_hint"} = StepResultValidator.classify_error(retryable_error)

      non_retryable_error = %{"type" => "some_error", "retryable" => false}

      assert {:non_retryable, "explicit_hint"} =
               StepResultValidator.classify_error(non_retryable_error)
    end

    test "classifies retryable errors by type" do
      timeout_error = %{"type" => "timeout_error"}

      assert {:retryable, "transient_infrastructure_error"} =
               StepResultValidator.classify_error(timeout_error)

      network_error = %{"type" => "network_error"}

      assert {:retryable, "transient_infrastructure_error"} =
               StepResultValidator.classify_error(network_error)

      connection_error = %{"type" => "connection_error"}

      assert {:retryable, "transient_infrastructure_error"} =
               StepResultValidator.classify_error(connection_error)
    end

    test "classifies retryable errors by code" do
      service_unavailable = %{"type" => "service_error", "code" => "SERVICE_UNAVAILABLE"}

      assert {:retryable, "service_temporarily_unavailable"} =
               StepResultValidator.classify_error(service_unavailable)

      rate_limited = %{"type" => "service_error", "code" => "RATE_LIMITED"}

      assert {:retryable, "service_temporarily_unavailable"} =
               StepResultValidator.classify_error(rate_limited)

      circuit_breaker = %{"type" => "service_error", "code" => "CIRCUIT_BREAKER_OPEN"}

      assert {:retryable, "service_temporarily_unavailable"} =
               StepResultValidator.classify_error(circuit_breaker)
    end

    test "classifies non-retryable errors by type" do
      validation_error = %{"type" => "validation_error"}

      assert {:non_retryable, "deterministic_error"} =
               StepResultValidator.classify_error(validation_error)

      business_error = %{"type" => "business_rule_violation"}

      assert {:non_retryable, "deterministic_error"} =
               StepResultValidator.classify_error(business_error)

      auth_error = %{"type" => "authentication_error"}

      assert {:non_retryable, "deterministic_error"} =
               StepResultValidator.classify_error(auth_error)
    end

    test "classifies unknown errors as non-retryable" do
      unknown_error = %{"type" => "unknown_error_type"}

      assert {:non_retryable, "unknown_error_type"} =
               StepResultValidator.classify_error(unknown_error)

      empty_error = %{}

      assert {:non_retryable, "unknown_error_type"} =
               StepResultValidator.classify_error(empty_error)
    end

    test "explicit hint takes precedence over type/code" do
      # Timeout error would normally be retryable, but explicit hint says no
      error = %{"type" => "timeout_error", "retryable" => false}
      assert {:non_retryable, "explicit_hint"} = StepResultValidator.classify_error(error)

      # Validation error would normally be non-retryable, but explicit hint says yes
      error = %{"type" => "validation_error", "retryable" => true}
      assert {:retryable, "explicit_hint"} = StepResultValidator.classify_error(error)
    end
  end

  describe "create_error_response/3" do
    test "creates basic error response" do
      response = StepResultValidator.create_error_response(:validation_error, "Invalid data")

      assert response["type"] == "validation_error"
      assert response["message"] == "Invalid data"
      assert response["code"] == nil
      assert response["details"] == %{}
      assert response["retryable"] == false
      assert is_binary(response["timestamp"])
    end

    test "creates error response with all options" do
      opts = [
        code: "VAL001",
        details: %{"field" => "user_id", "value" => "invalid"},
        retryable: true
      ]

      response =
        StepResultValidator.create_error_response(:validation_error, "Invalid data", opts)

      assert response["type"] == "validation_error"
      assert response["message"] == "Invalid data"
      assert response["code"] == "VAL001"
      assert response["details"] == %{"field" => "user_id", "value" => "invalid"}
      assert response["retryable"] == true
      assert is_binary(response["timestamp"])
    end

    test "converts atom types to strings" do
      response = StepResultValidator.create_error_response(:custom_error_type, "Message")
      assert response["type"] == "custom_error_type"
    end

    test "includes valid ISO8601 timestamp" do
      response = StepResultValidator.create_error_response(:error, "Message")

      # Parse timestamp to verify it's valid ISO8601
      {:ok, _datetime, _offset} = DateTime.from_iso8601(response["timestamp"])
    end
  end

  describe "validate_context/2" do
    test "validates context with required keys" do
      context = %{"saga_id" => "saga123", "user_id" => 456}
      required_keys = ["saga_id", "user_id"]

      assert :ok = StepResultValidator.validate_context(context, required_keys)
    end

    test "rejects context missing required keys" do
      context = %{"saga_id" => "saga123"}
      required_keys = ["saga_id", "user_id", "order_id"]

      assert {:error, errors} = StepResultValidator.validate_context(context, required_keys)

      missing_errors = Enum.filter(errors, &(&1.type == :missing_context_key))
      assert length(missing_errors) == 2

      missing_keys = Enum.map(missing_errors, & &1.field)
      assert "user_id" in missing_keys
      assert "order_id" in missing_keys
    end

    test "validates context without required keys" do
      context = %{"any" => "data"}
      assert :ok = StepResultValidator.validate_context(context)
    end

    test "rejects context with reserved keys" do
      context = %{
        "saga_id" => "saga123",
        "_metadata" => "reserved",
        "_internal" => "also_reserved"
      }

      assert {:error, errors} = StepResultValidator.validate_context(context)

      reserved_errors = Enum.filter(errors, &(&1.type == :reserved_key_usage))
      assert length(reserved_errors) == 2

      reserved_keys = Enum.map(reserved_errors, & &1.field)
      assert "_metadata" in reserved_keys
      assert "_internal" in reserved_keys
    end

    test "rejects non-map context" do
      assert {:error, errors} = StepResultValidator.validate_context("not_a_map")

      structure_error = Enum.find(errors, &(&1.type == :invalid_structure))
      assert structure_error != nil
      assert structure_error.message == "Context must be a map"
    end
  end

  describe "sanitize_result/2" do
    test "removes sensitive fields by default patterns" do
      result = %{
        "user_id" => 123,
        "password" => "secret123",
        "api_token" => "abc123",
        "credit_card_key" => "4567890123456789",
        "user_credential" => "sensitive"
      }

      sanitized = StepResultValidator.sanitize_result(result)

      assert sanitized["user_id"] == 123
      assert sanitized["password"] == "[REDACTED]"
      assert sanitized["api_token"] == "[REDACTED]"
      assert sanitized["credit_card_key"] == "[REDACTED]"
      assert sanitized["user_credential"] == "[REDACTED]"
    end

    test "removes sensitive fields by custom patterns" do
      result = %{
        "user_id" => 123,
        "ssn_number" => "123-45-6789",
        "account_pin" => "1234"
      }

      sanitization_rules = [sensitive_patterns: ["ssn", "pin"]]
      sanitized = StepResultValidator.sanitize_result(result, sanitization_rules)

      assert sanitized["user_id"] == 123
      assert sanitized["ssn_number"] == "[REDACTED]"
      assert sanitized["account_pin"] == "[REDACTED]"
    end

    test "handles case-insensitive pattern matching" do
      result = %{
        "Password" => "secret",
        "API_TOKEN" => "token123",
        "UserSecret" => "hidden"
      }

      sanitized = StepResultValidator.sanitize_result(result)

      assert sanitized["Password"] == "[REDACTED]"
      assert sanitized["API_TOKEN"] == "[REDACTED]"
      assert sanitized["UserSecret"] == "[REDACTED]"
    end

    test "validates size limits for large results" do
      # Create a large result that exceeds 1MB limit
      # > 1MB
      large_value = String.duplicate("x", 1_100_000)
      large_result = %{"data" => large_value}

      sanitized = StepResultValidator.sanitize_result(large_result)

      # Should return error structure for oversized results
      assert Map.has_key?(sanitized, "error")
      assert sanitized["error"] == "Result too large"
      assert Map.has_key?(sanitized, "size_bytes")
      assert Map.has_key?(sanitized, "max_bytes")
    end

    test "preserves normal-sized results" do
      normal_result = %{"data" => "normal sized data"}

      sanitized = StepResultValidator.sanitize_result(normal_result)

      assert sanitized == normal_result
    end

    test "handles non-map inputs gracefully" do
      # Now that we have a fallback clause, non-map inputs should pass through

      # Test with string input
      assert StepResultValidator.sanitize_result("string_input") == "string_input"

      # Test with number input (goes through normalize_data_types and validate_size_limits)
      assert StepResultValidator.sanitize_result(123) == 123

      # Test with list input
      assert StepResultValidator.sanitize_result([1, 2, 3]) == [1, 2, 3]
    end
  end

  describe "validate_performance_metrics/2" do
    test "validates metrics within limits" do
      metrics = %{
        # 1 second
        execution_time_ms: 1000,
        # 50 MB
        memory_usage_mb: 50
      }

      assert :ok = StepResultValidator.validate_performance_metrics(metrics)
    end

    test "rejects metrics exceeding execution time limit" do
      # 400 seconds > 5 minute default
      metrics = %{execution_time_ms: 400_000}

      assert {:error, errors} = StepResultValidator.validate_performance_metrics(metrics)

      perf_error = Enum.find(errors, &(&1.type == :performance_violation))
      assert perf_error != nil
      assert perf_error.field == "execution_time_ms"
      assert String.contains?(perf_error.message, "400000ms exceeds limit 300000ms")
    end

    test "rejects metrics exceeding memory limit" do
      # 1.5GB > 1GB default
      metrics = %{memory_usage_mb: 1500}

      assert {:error, errors} = StepResultValidator.validate_performance_metrics(metrics)

      perf_error = Enum.find(errors, &(&1.type == :performance_violation))
      assert perf_error != nil
      assert perf_error.field == "memory_usage_mb"
      assert String.contains?(perf_error.message, "1500MB exceeds limit 1000MB")
    end

    test "validates with custom limits" do
      metrics = %{
        execution_time_ms: 2000,
        memory_usage_mb: 200
      }

      limits = %{
        # 1 second limit
        max_execution_time_ms: 1000,
        # 100 MB limit
        max_memory_mb: 100
      }

      assert {:error, errors} = StepResultValidator.validate_performance_metrics(metrics, limits)

      # Should have both execution time and memory violations
      time_error = Enum.find(errors, &(&1.field == "execution_time_ms"))
      memory_error = Enum.find(errors, &(&1.field == "memory_usage_mb"))

      assert time_error != nil
      assert memory_error != nil
    end

    test "handles missing metrics gracefully" do
      # No execution_time_ms or memory_usage_mb
      metrics = %{some_other_metric: 100}

      assert :ok = StepResultValidator.validate_performance_metrics(metrics)
    end

    test "handles nil memory usage" do
      metrics = %{
        execution_time_ms: 1000,
        memory_usage_mb: nil
      }

      assert :ok = StepResultValidator.validate_performance_metrics(metrics)
    end

    test "validates multiple violations" do
      metrics = %{
        # Over time limit
        execution_time_ms: 500_000,
        # Over memory limit
        memory_usage_mb: 2000
      }

      assert {:error, errors} = StepResultValidator.validate_performance_metrics(metrics)
      assert length(errors) == 2
    end
  end

  describe "edge cases and error handling" do
    test "handles nil inputs gracefully" do
      # validate_result with nil result should fail basic structure validation
      assert {:error, errors} = StepResultValidator.validate_result(nil, %{})
      structure_error = Enum.find(errors, &(&1.type == :invalid_structure))
      assert structure_error != nil
    end

    test "handles empty schema" do
      result = %{"any" => "data"}
      schema = %{}

      assert :ok = StepResultValidator.validate_result(result, schema)
    end

    test "handles complex nested objects" do
      schema = %{
        "properties" => %{
          "nested" => %{
            "type" => "object",
            "properties" => %{
              "inner" => %{"type" => "string"}
            }
          }
        }
      }

      result = %{
        "nested" => %{
          "inner" => "value"
        }
      }

      assert :ok = StepResultValidator.validate_result(result, schema)
    end

    test "handles unknown field types in schema" do
      schema = %{
        "properties" => %{
          "custom_field" => %{"type" => "unknown_type"}
        }
      }

      result = %{"custom_field" => "any_value"}

      # Unknown types should be allowed
      assert :ok = StepResultValidator.validate_result(result, schema)
    end

    test "error responses handle edge cases" do
      # Empty error response
      assert {:error, _} = StepResultValidator.validate_error_response(%{})

      # Error response with nil values
      error_with_nils = %{"type" => nil, "message" => nil}
      assert {:error, _} = StepResultValidator.validate_error_response(error_with_nils)
    end

    test "classify_error handles malformed errors" do
      # Error without type or code
      malformed = %{"something" => "else"}

      assert {:non_retryable, "unknown_error_type"} =
               StepResultValidator.classify_error(malformed)

      # Error with nil values
      nil_error = %{"type" => nil, "code" => nil}

      assert {:non_retryable, "unknown_error_type"} =
               StepResultValidator.classify_error(nil_error)
    end
  end

  describe "private function coverage" do
    test "covers various error field validation scenarios" do
      # Test with missing type and message
      empty_error = %{}
      assert {:error, errors} = StepResultValidator.validate_error_response(empty_error)
      # Both type and message missing
      assert length(errors) >= 2

      # Test with non-string type and valid message
      invalid_type = %{"type" => [], "message" => "valid message"}
      assert {:error, errors} = StepResultValidator.validate_error_response(invalid_type)
      type_error = Enum.find(errors, &(&1.type == :type_mismatch && &1.field == "type"))
      assert type_error != nil

      # Test with valid type and retryable as non-boolean
      invalid_retryable = %{"type" => "error", "message" => "msg", "retryable" => "not_boolean"}
      assert {:error, errors} = StepResultValidator.validate_error_response(invalid_retryable)
      retryable_error = Enum.find(errors, &(&1.type == :type_mismatch && &1.field == "retryable"))
      assert retryable_error != nil
    end

    test "covers input schema extraction" do
      # Test step definition without input_schema
      step_def_no_schema = %{"other" => "data"}
      assert :ok = StepResultValidator.validate_input(%{}, step_def_no_schema)

      # Test step definition with empty input_schema
      step_def_empty_schema = %{"input_schema" => %{}}
      assert :ok = StepResultValidator.validate_input(%{"any" => "data"}, step_def_empty_schema)
    end

    test "covers business rule edge cases" do
      # Test positive_amount with non-number
      schema = %{
        "business_rules" => [
          %{"type" => "positive_amount", "field" => "amount"}
        ]
      }

      result = %{"amount" => "not_a_number"}
      assert {:error, errors} = StepResultValidator.validate_result(result, schema)

      business_error = Enum.find(errors, &(&1.type == :business_rule_violation))
      assert business_error != nil

      # Test valid_email with non-string
      email_schema = %{
        "business_rules" => [
          %{"type" => "valid_email", "field" => "email"}
        ]
      }

      result = %{"email" => 123}
      assert {:error, errors} = StepResultValidator.validate_result(result, email_schema)

      business_error = Enum.find(errors, &(&1.type == :business_rule_violation))
      assert business_error != nil
    end

    test "covers get_value_type for all data types" do
      # This is tested indirectly through type validation errors, but let's ensure coverage
      schema = %{
        "properties" => %{
          # Wrong type to trigger error
          "float_field" => %{"type" => "string"}
        }
      }

      # Float value
      result = %{"float_field" => 3.14}
      assert {:error, errors} = StepResultValidator.validate_result(result, schema)

      type_error = Enum.find(errors, &(&1.type == :type_mismatch))
      assert type_error != nil
      # Should identify as "number" type
      assert String.contains?(type_error.message, "number")
    end
  end
end
