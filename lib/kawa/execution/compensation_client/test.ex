defmodule Kawa.Execution.CompensationClient.Test do
  @moduledoc """
  Test implementation that simulates compensation without WebSocket communication.

  This is used only in test environments to avoid business logic containing
  test-specific code.
  """

  @behaviour Kawa.Execution.CompensationClient

  require Logger

  @impl true
  def compensate_step(_saga_id, step) do
    Logger.info("Test compensation for step #{step.step_id}")

    # Check if step has compensation configured
    compensation_config = get_in(step.execution_metadata, ["compensation"])

    case compensation_config do
      %{"available" => false} ->
        # Step doesn't support compensation
        {:ok, %{skipped: true, reason: "no_compensation_available"}}

      _ ->
        # Simulate successful compensation
        {:ok, %{compensated_at: DateTime.utc_now()}}
    end
  end
end
