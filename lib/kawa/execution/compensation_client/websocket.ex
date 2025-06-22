defmodule Kawa.Execution.CompensationClient.WebSocket do
  @moduledoc """
  Production implementation that sends compensation requests via WebSocket.
  """

  @behaviour Kawa.Execution.CompensationClient

  require Logger

  alias Kawa.Execution.StepExecutionProtocol
  alias Kawa.Core.ClientRegistry

  @impl true
  def compensate_step(_saga_id, step) do
    Logger.info("Performing WebSocket compensation for step #{step.step_id}")

    case ClientRegistry.get_client_pid(step.client_id) do
      {:ok, client_pid} ->
        send_compensation_request(client_pid, step)

      {:error, :not_found} ->
        Logger.error("Client not connected for compensation of step #{step.step_id}")
        {:error, :client_not_connected}
    end
  end

  defp send_compensation_request(client_pid, step) do
    Logger.info("Sending compensation request to client for step #{step.step_id}")

    # Create compensation request message
    message =
      StepExecutionProtocol.create_compensation_request(
        step.saga_id,
        step.step_id,
        step.output,
        %{},
        timeout_ms: 30_000
      )

    send(client_pid, {:compensate_step, message})

    # Wait for compensation response with timeout
    saga_id = step.saga_id
    step_id = step.step_id

    receive do
      {:compensation_completed, ^saga_id, ^step_id, result} ->
        Logger.info("Compensation completed for step #{step_id}")
        {:ok, result}

      {:compensation_failed, ^saga_id, ^step_id, error} ->
        Logger.warning("Compensation failed for step #{step_id}: #{inspect(error)}")
        {:error, error}
    after
      30_000 ->
        Logger.error("Compensation timeout for step #{step_id}")
        {:error, :compensation_timeout}
    end
  end
end
