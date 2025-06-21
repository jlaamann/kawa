defmodule Kawa.Execution.StepStateMachine do
  @moduledoc """
  Manages step execution state transitions with validation and event tracking.

  Implements a state machine for saga step execution with the following states:
  - pending: Step is waiting to be executed
  - running: Step is currently being executed
  - completed: Step executed successfully
  - failed: Step failed during execution
  - compensating: Step is being compensated (rolled back)
  - compensated: Step has been successfully compensated
  - skipped: Step was skipped (e.g., due to conditional logic)
  """

  @valid_states ~w(pending running completed failed compensating compensated skipped)

  @valid_transitions %{
    "pending" => ~w(running skipped),
    "running" => ~w(completed failed),
    "completed" => ~w(compensating),
    "failed" => ~w(compensating),
    "compensating" => ~w(compensated failed),
    "compensated" => [],
    "skipped" => []
  }

  defmodule StateTransition do
    @moduledoc false
    defstruct [
      :from_state,
      :to_state,
      :timestamp,
      :reason,
      :metadata
    ]

    @type t :: %__MODULE__{
            from_state: String.t(),
            to_state: String.t(),
            timestamp: DateTime.t(),
            reason: String.t() | nil,
            metadata: map()
          }
  end

  @doc """
  Validates if a state transition is allowed.

  Returns `:ok` if valid, `{:error, reason}` if invalid.

  ## Examples

      iex> Kawa.StepStateMachine.validate_transition("pending", "running")
      :ok

      iex> Kawa.StepStateMachine.validate_transition("completed", "pending")
      {:error, :invalid_transition}
  """
  def validate_transition(from_state, to_state) do
    cond do
      from_state not in @valid_states ->
        {:error, {:invalid_state, from_state}}

      to_state not in @valid_states ->
        {:error, {:invalid_state, to_state}}

      from_state == to_state ->
        {:error, :same_state}

      to_state not in Map.get(@valid_transitions, from_state, []) ->
        {:error, :invalid_transition}

      true ->
        :ok
    end
  end

  @doc """
  Creates a state transition record.

  Returns `{:ok, state_transition}` if valid, `{:error, reason}` if invalid.
  """
  def create_transition(from_state, to_state, opts \\ []) do
    case validate_transition(from_state, to_state) do
      :ok ->
        transition = %StateTransition{
          from_state: from_state,
          to_state: to_state,
          timestamp: DateTime.utc_now(),
          reason: Keyword.get(opts, :reason),
          metadata: Keyword.get(opts, :metadata, %{})
        }

        {:ok, transition}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets all valid next states for a given current state.

  ## Examples

      iex> Kawa.StepStateMachine.valid_next_states("pending")
      ["running", "skipped"]
  """
  def valid_next_states(current_state) do
    Map.get(@valid_transitions, current_state, [])
  end

  @doc """
  Checks if a state is terminal (no further transitions possible).

  ## Examples

      iex> Kawa.StepStateMachine.is_terminal_state?("completed")
      false

      iex> Kawa.StepStateMachine.is_terminal_state?("compensated")
      true
  """
  def is_terminal_state?(state) do
    Map.get(@valid_transitions, state, []) == []
  end

  @doc """
  Checks if a state indicates successful completion.
  """
  def is_success_state?(state) do
    state in ~w(completed compensated skipped)
  end

  @doc """
  Checks if a state indicates failure.
  """
  def is_failure_state?(state) do
    state == "failed"
  end

  @doc """
  Checks if a state indicates the step is actively executing.
  """
  def is_active_state?(state) do
    state in ~w(running compensating)
  end

  @doc """
  Gets the compensation state for a given execution state.

  ## Examples

      iex> Kawa.StepStateMachine.get_compensation_state("completed")
      "compensating"

      iex> Kawa.StepStateMachine.get_compensation_state("failed")
      "compensating"
  """
  def get_compensation_state(state) when state in ~w(completed failed), do: "compensating"
  def get_compensation_state(_state), do: nil

  @doc """
  Builds a state transition path for common workflows.

  Returns a list of valid state transitions for common scenarios.
  """
  def get_transition_path(scenario) do
    case scenario do
      :successful_execution ->
        [
          {"pending", "running"},
          {"running", "completed"}
        ]

      :failed_execution ->
        [
          {"pending", "running"},
          {"running", "failed"}
        ]

      :successful_compensation ->
        [
          {"completed", "compensating"},
          {"compensating", "compensated"}
        ]

      :failed_compensation ->
        [
          {"completed", "compensating"},
          {"compensating", "failed"}
        ]

      :skip_execution ->
        [
          {"pending", "skipped"}
        ]

      :full_saga_rollback ->
        [
          {"completed", "compensating"},
          {"compensating", "compensated"}
        ]

      _ ->
        []
    end
  end

  @doc """
  Validates a sequence of state transitions.

  Returns `:ok` if all transitions are valid, `{:error, details}` otherwise.
  """
  def validate_transition_sequence(transitions) do
    transitions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{from, to}, index}, _acc ->
      case validate_transition(from, to) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {reason, index, {from, to}}}}
      end
    end)
  end
end
