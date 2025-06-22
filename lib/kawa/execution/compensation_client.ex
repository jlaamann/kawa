defmodule Kawa.Execution.CompensationClient do
  @moduledoc """
  Behavior for executing compensation requests.

  This allows for different implementations in test vs production environments
  without embedding simulation logic in business code.
  """

  @callback compensate_step(saga_id :: String.t(), step :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Gets the appropriate compensation client based on environment.
  """
  def impl do
    Application.get_env(:kawa, :compensation_client, __MODULE__.WebSocket)
  end

  @doc """
  Delegates to the configured compensation client implementation.
  """
  def compensate_step(saga_id, step) do
    impl().compensate_step(saga_id, step)
  end
end
