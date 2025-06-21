defmodule Kawa.Validation.WorkflowValidatorTest do
  use ExUnit.Case, async: true

  alias Kawa.Validation.WorkflowValidator

  describe "validate/1 with valid workflows" do
    test "validates a simple HTTP workflow" do
      workflow = %{
        "name" => "test-workflow",
        "description" => "A test workflow",
        "timeout" => "5m",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{
              "method" => "POST",
              "url" => "http://example.com/api",
              "body" => %{"key" => "value"}
            },
            "compensation" => %{
              "method" => "DELETE",
              "url" => "http://example.com/api/rollback"
            },
            "timeout" => "30s"
          }
        ]
      }

      assert {:ok, ^workflow} = WorkflowValidator.validate(workflow)
    end

    test "validates an Elixir workflow" do
      workflow = %{
        "name" => "elixir-workflow",
        "steps" => [
          %{
            "id" => "process_data",
            "type" => "elixir",
            "action" => %{
              "module" => "MyApp.DataProcessor",
              "function" => "process",
              "args" => ["arg1", "arg2"]
            },
            "compensation" => %{
              "module" => "MyApp.DataProcessor",
              "function" => "rollback",
              "args" => ["arg1"]
            }
          }
        ]
      }

      assert {:ok, ^workflow} = WorkflowValidator.validate(workflow)
    end

    test "validates workflow with step dependencies" do
      workflow = %{
        "name" => "dependency-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step2",
            "type" => "http",
            "depends_on" => ["step1"],
            "action" => %{"method" => "POST", "url" => "http://example.com"}
          },
          %{
            "id" => "step3",
            "type" => "http",
            "depends_on" => ["step1", "step2"],
            "action" => %{"method" => "PUT", "url" => "http://example.com"}
          }
        ]
      }

      assert {:ok, ^workflow} = WorkflowValidator.validate(workflow)
    end

    test "validates JSON string input" do
      json_workflow = """
      {
        "name": "json-workflow",
        "steps": [
          {
            "id": "step1",
            "type": "http",
            "action": {
              "method": "GET",
              "url": "https://api.example.com"
            }
          }
        ]
      }
      """

      assert {:ok, workflow} = WorkflowValidator.validate(json_workflow)
      assert workflow["name"] == "json-workflow"
    end
  end

  describe "validate/1 with invalid JSON" do
    test "rejects invalid JSON format" do
      invalid_json = """
      {
        "name": "test",
        "steps": [
          {
            "id": "step1"
            "type": "http"  // Missing comma
          }
        ]
      }
      """

      assert {:error, [error]} = WorkflowValidator.validate(invalid_json)
      assert error.field == "json"
      assert String.contains?(error.message, "Invalid JSON format")
      assert is_integer(error.line)
    end
  end

  describe "validate/1 with invalid workflow structure" do
    test "rejects non-map input" do
      assert {:error, [error]} = WorkflowValidator.validate("not a map")
      assert error.field == "json"
      assert String.contains?(error.message, "Invalid JSON format")
    end

    test "rejects missing required fields" do
      workflow = %{}

      assert {:error, errors} = WorkflowValidator.validate(workflow)

      error_fields = Enum.map(errors, & &1.field)
      assert "name" in error_fields
      assert "steps" in error_fields
    end

    test "rejects empty required fields" do
      workflow = %{"name" => "", "steps" => []}

      assert {:error, errors} = WorkflowValidator.validate(workflow)

      name_error = Enum.find(errors, &(&1.field == "name"))
      steps_error = Enum.find(errors, &(&1.field == "steps"))

      assert name_error.message == "cannot be empty"
      assert steps_error.message == "must contain at least one step"
    end

    test "rejects invalid workflow name" do
      workflow = %{
        "name" => "invalid name with spaces!",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "name"
      assert String.contains?(error.message, "alphanumeric characters")
    end

    test "rejects invalid timeout format" do
      workflow = %{
        "name" => "test-workflow",
        "timeout" => "invalid-timeout",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, errors} = WorkflowValidator.validate(workflow)
      timeout_error = Enum.find(errors, &(&1.field == "timeout"))
      assert String.contains?(timeout_error.message, "30s")
    end
  end

  describe "validate/1 step validation" do
    test "rejects steps that are not objects" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => ["not an object"]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0]"
      assert error.message == "must be an object"
    end

    test "rejects missing step id" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{"type" => "http", "action" => %{"method" => "GET", "url" => "http://example.com"}}
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].id"
      assert error.message == "is required"
    end

    test "rejects invalid step type" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [%{"id" => "step1", "type" => "invalid-type", "action" => %{}}]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].type"
      assert String.contains?(error.message, "must be one of")
    end

    test "rejects duplicate step IDs" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "POST", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps"
      assert String.contains?(error.message, "duplicate step ID: step1")
    end
  end

  describe "validate/1 HTTP action validation" do
    test "rejects missing HTTP method" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"url" => "http://example.com"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].action.method"
      assert error.message == "is required for HTTP actions"
    end

    test "rejects invalid HTTP method" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "INVALID", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].action.method"
      assert String.contains?(error.message, "must be one of")
    end

    test "rejects invalid HTTP URL" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "not-a-url"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].action.url"
      assert String.contains?(error.message, "valid HTTP/HTTPS URL")
    end

    test "accepts valid HTTP URLs" do
      valid_urls = [
        "http://example.com",
        "https://api.example.com/v1/endpoint",
        "http://localhost:8080/path"
      ]

      for url <- valid_urls do
        workflow = %{
          "name" => "test-workflow",
          "steps" => [
            %{
              "id" => "step1",
              "type" => "http",
              "action" => %{"method" => "GET", "url" => url}
            }
          ]
        }

        assert {:ok, _} = WorkflowValidator.validate(workflow)
      end
    end
  end

  describe "validate/1 Elixir action validation" do
    test "rejects missing module" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "elixir",
            "action" => %{"function" => "test"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].action.module"
      assert error.message == "is required for Elixir actions"
    end

    test "rejects missing function" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "elixir",
            "action" => %{"module" => "MyModule"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].action.function"
      assert error.message == "is required for Elixir actions"
    end

    test "accepts valid Elixir action" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "elixir",
            "action" => %{
              "module" => "MyModule",
              "function" => "my_function",
              "args" => ["arg1", "arg2"]
            }
          }
        ]
      }

      assert {:ok, _} = WorkflowValidator.validate(workflow)
    end
  end

  describe "validate/1 dependency validation" do
    test "rejects references to non-existent steps" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "depends_on" => ["non-existent-step"],
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, [error]} = WorkflowValidator.validate(workflow)
      assert error.field == "steps[0].depends_on"
      assert String.contains?(error.message, "references non-existent step: non-existent-step")
    end

    test "accepts valid step dependencies" do
      workflow = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step2",
            "type" => "http",
            "depends_on" => ["step1"],
            "action" => %{"method" => "POST", "url" => "http://example.com"}
          }
        ]
      }

      assert {:ok, _} = WorkflowValidator.validate(workflow)
    end
  end

  describe "validate/1 circular dependency detection" do
    test "detects simple circular dependency" do
      workflow = %{
        "name" => "circular-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "depends_on" => ["step2"],
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step2",
            "type" => "http",
            "depends_on" => ["step1"],
            "action" => %{"method" => "POST", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, errors} = WorkflowValidator.validate(workflow)

      circular_errors =
        Enum.filter(
          errors,
          &(&1.field == "steps" && String.contains?(&1.message, "circular dependency"))
        )

      assert length(circular_errors) > 0
    end

    test "detects complex circular dependency" do
      workflow = %{
        "name" => "complex-circular-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "depends_on" => ["step3"],
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step2",
            "type" => "http",
            "depends_on" => ["step1"],
            "action" => %{"method" => "POST", "url" => "http://example.com"}
          },
          %{
            "id" => "step3",
            "type" => "http",
            "depends_on" => ["step2"],
            "action" => %{"method" => "PUT", "url" => "http://example.com"}
          }
        ]
      }

      assert {:error, errors} = WorkflowValidator.validate(workflow)

      circular_errors =
        Enum.filter(
          errors,
          &(&1.field == "steps" && String.contains?(&1.message, "circular dependency"))
        )

      assert length(circular_errors) > 0
    end

    test "accepts complex valid dependency graph" do
      workflow = %{
        "name" => "complex-valid-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step2",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          },
          %{
            "id" => "step3",
            "type" => "http",
            "depends_on" => ["step1", "step2"],
            "action" => %{"method" => "POST", "url" => "http://example.com"}
          },
          %{
            "id" => "step4",
            "type" => "http",
            "depends_on" => ["step3"],
            "action" => %{"method" => "PUT", "url" => "http://example.com"}
          },
          %{
            "id" => "step5",
            "type" => "http",
            "depends_on" => ["step1"],
            "action" => %{"method" => "DELETE", "url" => "http://example.com"}
          }
        ]
      }

      assert {:ok, _} = WorkflowValidator.validate(workflow)
    end
  end

  describe "validate/1 timeout validation" do
    test "accepts valid timeout formats" do
      valid_timeouts = ["1s", "30s", "5m", "2h", "999s"]

      for timeout <- valid_timeouts do
        workflow = %{
          "name" => "timeout-test",
          "timeout" => timeout,
          "steps" => [
            %{
              "id" => "step1",
              "type" => "http",
              "timeout" => timeout,
              "action" => %{"method" => "GET", "url" => "http://example.com"}
            }
          ]
        }

        assert {:ok, _} = WorkflowValidator.validate(workflow), "Failed for timeout: #{timeout}"
      end
    end

    test "rejects invalid timeout formats" do
      invalid_timeouts = ["1", "1sec", "invalid", "0s", "-5s", "1.5m"]

      for timeout <- invalid_timeouts do
        workflow = %{
          "name" => "timeout-test",
          "timeout" => timeout,
          "steps" => [
            %{
              "id" => "step1",
              "type" => "http",
              "action" => %{"method" => "GET", "url" => "http://example.com"}
            }
          ]
        }

        assert {:error, _} = WorkflowValidator.validate(workflow),
               "Should fail for timeout: #{timeout}"
      end
    end
  end

  describe "error message structure" do
    test "includes field, message, line, and value in errors" do
      workflow = %{"name" => 123, "steps" => "not an array"}

      assert {:error, errors} = WorkflowValidator.validate(workflow)

      for error <- errors do
        assert Map.has_key?(error, :field)
        assert Map.has_key?(error, :message)
        assert Map.has_key?(error, :line)
        assert Map.has_key?(error, :value)
        assert is_binary(error.field)
        assert is_binary(error.message)
      end
    end
  end
end
