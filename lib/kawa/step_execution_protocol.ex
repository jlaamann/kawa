defmodule Kawa.StepExecutionProtocol do
  @moduledoc """
  Defines the message format and protocol for step execution between Kawa server and clients.

  This module provides structured message formats for reliable communication during
  saga step execution, including requests, responses, and status updates.
  """

  @doc """
  Creates a step execution request message.

  Sent from Kawa server to client to request execution of a specific step.

  ## Message Structure

      %{
        type: "execute_step",
        saga_id: "uuid",
        step_id: "step_name",
        correlation_id: "uuid",
        input: %{...},
        timeout_ms: 30000,
        retry_count: 0,
        metadata: %{...}
      }
  """
  def create_execution_request(saga_id, step_id, input, opts \\ []) do
    %{
      type: "execute_step",
      saga_id: saga_id,
      step_id: step_id,
      correlation_id: generate_correlation_id(),
      input: input || %{},
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
      retry_count: Keyword.get(opts, :retry_count, 0),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a step completion response message.

  Sent from client to Kawa server when a step completes successfully.

  ## Message Structure

      %{
        type: "step_completed",
        saga_id: "uuid",
        step_id: "step_name",
        correlation_id: "uuid",
        result: %{...},
        execution_time_ms: 1500,
        metadata: %{...}
      }
  """
  def create_completion_response(saga_id, step_id, correlation_id, result, opts \\ []) do
    %{
      type: "step_completed",
      saga_id: saga_id,
      step_id: step_id,
      correlation_id: correlation_id,
      result: result || %{},
      execution_time_ms: Keyword.get(opts, :execution_time_ms),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a step failure response message.

  Sent from client to Kawa server when a step fails.

  ## Message Structure

      %{
        type: "step_failed",
        saga_id: "uuid",
        step_id: "step_name",
        correlation_id: "uuid",
        error: %{
          type: "validation_error",
          message: "Invalid input data",
          code: "INVALID_INPUT",
          details: %{...},
          retryable: false
        },
        execution_time_ms: 500,
        metadata: %{...}
      }
  """
  def create_failure_response(saga_id, step_id, correlation_id, error, opts \\ []) do
    %{
      type: "step_failed",
      saga_id: saga_id,
      step_id: step_id,
      correlation_id: correlation_id,
      error: normalize_error(error),
      execution_time_ms: Keyword.get(opts, :execution_time_ms),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a compensation request message.

  Sent from Kawa server to client to request compensation (rollback) of a step.

  ## Message Structure

      %{
        type: "compensate_step",
        saga_id: "uuid",
        step_id: "step_name",
        correlation_id: "uuid",
        original_result: %{...},
        compensation_data: %{...},
        timeout_ms: 30000,
        metadata: %{...}
      }
  """
  def create_compensation_request(
        saga_id,
        step_id,
        original_result,
        compensation_data,
        opts \\ []
      ) do
    %{
      type: "compensate_step",
      saga_id: saga_id,
      step_id: step_id,
      correlation_id: generate_correlation_id(),
      original_result: original_result || %{},
      compensation_data: compensation_data || %{},
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a step status query message.

  Sent from Kawa server to client to check step execution status.

  ## Message Structure

      %{
        type: "step_status_query",
        saga_id: "uuid",
        step_id: "step_name",
        correlation_id: "uuid"
      }
  """
  def create_status_query(saga_id, step_id) do
    %{
      type: "step_status_query",
      saga_id: saga_id,
      step_id: step_id,
      correlation_id: generate_correlation_id(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a step status response message.

  Sent from client to Kawa server in response to status query.

  ## Message Structure

      %{
        type: "step_status_response",
        saga_id: "uuid",
        step_id: "step_name",
        correlation_id: "uuid",
        status: "running",
        progress: %{
          percentage: 75,
          current_task: "processing data",
          estimated_completion: "2024-01-01T12:30:00Z"
        }
      }
  """
  def create_status_response(saga_id, step_id, correlation_id, status, progress \\ %{}) do
    %{
      type: "step_status_response",
      saga_id: saga_id,
      step_id: step_id,
      correlation_id: correlation_id,
      status: status,
      progress: progress,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a heartbeat message.

  Sent between client and server to maintain connection liveness.

  ## Message Structure

      %{
        type: "heartbeat",
        client_id: "uuid",
        active_sagas: ["saga1", "saga2"],
        system_metrics: %{...}
      }
  """
  def create_heartbeat(client_id, active_sagas \\ [], system_metrics \\ %{}) do
    %{
      type: "heartbeat",
      client_id: client_id,
      active_sagas: active_sagas,
      system_metrics: system_metrics,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Validates a step execution message format.

  Returns `:ok` if valid, `{:error, reasons}` if invalid.
  """
  def validate_message(message) when is_map(message) do
    required_fields = get_required_fields(message["type"])

    case validate_required_fields(message, required_fields) do
      :ok -> validate_field_types(message)
      error -> error
    end
  end

  @doc """
  Extracts correlation ID from a message.

  Returns the correlation ID if present, generates one if missing.
  """
  def get_correlation_id(message) when is_map(message) do
    Map.get(message, "correlation_id") || generate_correlation_id()
  end

  @doc """
  Checks if a message is a request type (requires response).
  """
  def is_request_message?(message) when is_map(message) do
    Map.get(message, "type") in ["execute_step", "compensate_step", "step_status_query"]
  end

  @doc """
  Checks if a message is a response type.
  """
  def is_response_message?(message) when is_map(message) do
    Map.get(message, "type") in ["step_completed", "step_failed", "step_status_response"]
  end

  @doc """
  Gets the expected response type for a request message.
  """
  def get_expected_response_type(request_type) do
    case request_type do
      "execute_step" -> ["step_completed", "step_failed"]
      "compensate_step" -> ["step_completed", "step_failed"]
      "step_status_query" -> ["step_status_response"]
      _ -> []
    end
  end

  @doc """
  Creates an error response for invalid messages.
  """
  def create_error_response(original_message, error_details) do
    %{
      type: "error",
      original_type: Map.get(original_message, "type"),
      correlation_id: get_correlation_id(original_message),
      error: normalize_error(error_details),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Serializes a message to JSON format for transmission.
  """
  def serialize_message(message) when is_map(message) do
    Jason.encode(message)
  end

  @doc """
  Deserializes a JSON message.
  """
  def deserialize_message(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # Private functions

  defp generate_correlation_id do
    Ecto.UUID.generate()
  end

  defp get_required_fields(message_type) do
    case message_type do
      "execute_step" -> ["type", "saga_id", "step_id", "input"]
      "step_completed" -> ["type", "saga_id", "step_id", "result"]
      "step_failed" -> ["type", "saga_id", "step_id", "error"]
      "compensate_step" -> ["type", "saga_id", "step_id", "original_result"]
      "step_status_query" -> ["type", "saga_id", "step_id"]
      "step_status_response" -> ["type", "saga_id", "step_id", "status"]
      "heartbeat" -> ["type", "client_id"]
      "error" -> ["type", "error"]
      _ -> ["type"]
    end
  end

  defp validate_required_fields(message, required_fields) do
    missing_fields =
      required_fields
      |> Enum.filter(fn field -> !Map.has_key?(message, field) end)

    if missing_fields == [] do
      :ok
    else
      {:error, {:missing_fields, missing_fields}}
    end
  end

  defp validate_field_types(message) do
    errors = []

    # Validate saga_id is UUID format if present
    errors =
      if Map.has_key?(message, "saga_id") && !valid_uuid?(message["saga_id"]) do
        [{:invalid_format, "saga_id", "must be valid UUID"} | errors]
      else
        errors
      end

    # Validate correlation_id is UUID format if present
    errors =
      if Map.has_key?(message, "correlation_id") && !valid_uuid?(message["correlation_id"]) do
        [{:invalid_format, "correlation_id", "must be valid UUID"} | errors]
      else
        errors
      end

    # Validate timeout_ms is positive integer if present
    errors =
      if Map.has_key?(message, "timeout_ms") && !valid_timeout?(message["timeout_ms"]) do
        [{:invalid_format, "timeout_ms", "must be positive integer"} | errors]
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, {:validation_errors, errors}}
  end

  defp valid_uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp valid_timeout?(value) when is_integer(value) and value > 0, do: true
  defp valid_timeout?(_), do: false

  defp normalize_error(error) when is_map(error) do
    %{
      type: Map.get(error, :type, "unknown_error"),
      message: Map.get(error, :message, "An error occurred"),
      code: Map.get(error, :code),
      details: Map.get(error, :details, %{}),
      retryable: Map.get(error, :retryable, false)
    }
  end

  defp normalize_error(error) when is_binary(error) do
    %{
      type: "string_error",
      message: error,
      code: nil,
      details: %{},
      retryable: false
    }
  end

  defp normalize_error(error) do
    %{
      type: "unknown_error",
      message: inspect(error),
      code: nil,
      details: %{},
      retryable: false
    }
  end
end
