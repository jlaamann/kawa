defmodule Kawa.Core.SagaServer do
  @moduledoc """
  GenServer responsible for executing individual saga workflows.

  Each saga gets its own SagaServer process that manages step-by-step execution,
  handles timeouts, retries, and maintains execution state.
  """

  use GenServer
  require Logger

  alias Kawa.Repo
  alias Kawa.Schemas.{Saga, SagaStep, SagaEvent}
  alias Kawa.Core.ClientRegistry

  alias Kawa.Execution.{
    StepDependencyResolver,
    StepStateMachine,
    StepExecutionProtocol,
    StepExecutionTracker,
    CompensationEngine
  }

  alias Kawa.Domain.SagaContext
  alias Kawa.Validation.StepResultValidator
  import Ecto.Query

  defmodule State do
    @moduledoc false
    defstruct [
      :saga_id,
      :saga,
      :workflow_definition,
      :steps,
      :execution_graph,
      :context,
      :pending_steps,
      :running_steps,
      :completed_steps,
      :failed_steps,
      :client_pid,
      :timeout_refs
    ]

    @type t :: %__MODULE__{
            saga_id: String.t(),
            saga: Saga.t(),
            workflow_definition: map(),
            steps: %{String.t() => map()},
            execution_graph: %{String.t() => [String.t()]},
            context: map(),
            pending_steps: MapSet.t(),
            running_steps: MapSet.t(),
            completed_steps: MapSet.t(),
            failed_steps: MapSet.t(),
            client_pid: pid() | nil,
            timeout_refs: %{String.t() => reference()}
          }
  end

  # Client API

  @doc """
  Starts a SagaServer for the given saga ID.
  """
  def start_link(saga_id) when is_binary(saga_id) do
    GenServer.start_link(__MODULE__, saga_id, name: via_tuple(saga_id))
  end

  @doc """
  Starts execution of the saga.
  """
  def start_execution(saga_id) do
    GenServer.call(via_tuple(saga_id), :start_execution)
  end

  @doc """
  Handles completion of a step from the client.
  """
  def step_completed(saga_id, step_id, result) do
    GenServer.cast(via_tuple(saga_id), {:step_completed, step_id, result})
  end

  @doc """
  Handles failure of a step from the client.
  """
  def step_failed(saga_id, step_id, error) do
    GenServer.cast(via_tuple(saga_id), {:step_failed, step_id, error})
  end

  @doc """
  Pauses saga execution (e.g., when client disconnects).
  """
  def pause(saga_id) do
    GenServer.cast(via_tuple(saga_id), :pause)
  end

  @doc """
  Resumes saga execution (e.g., when client reconnects).
  """
  def resume(saga_id) do
    GenServer.cast(via_tuple(saga_id), :resume)
  end

  @doc """
  Gets the current status of the saga.
  """
  def get_status(saga_id) do
    GenServer.call(via_tuple(saga_id), :get_status)
  end

  # GenServer callbacks

  @impl true
  def init(saga_id) do
    case load_saga(saga_id) do
      {:ok, saga, workflow_definition} ->
        # Validate workflow dependencies
        workflow_steps = Map.get(workflow_definition, "steps", [])

        case StepDependencyResolver.validate_dependencies(workflow_steps) do
          :ok ->
            state = %State{
              saga_id: saga_id,
              saga: saga,
              workflow_definition: workflow_definition,
              steps: extract_steps(workflow_definition),
              execution_graph: build_execution_graph(workflow_definition),
              context: saga.context,
              pending_steps: MapSet.new(),
              running_steps: MapSet.new(),
              completed_steps: MapSet.new(),
              failed_steps: MapSet.new(),
              client_pid: nil,
              timeout_refs: %{}
            }

            # Initialize step states
            state = initialize_step_states(state)

            Logger.info("SagaServer started for saga #{saga_id}")
            {:ok, state}

          {:error, errors} ->
            Logger.error("Invalid workflow dependencies for saga #{saga_id}: #{inspect(errors)}")
            {:stop, {:invalid_workflow, errors}}
        end

      {:error, reason} ->
        Logger.error("Failed to load saga #{saga_id}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:start_execution, _from, state) do
    case update_saga_status(state.saga, "running") do
      {:ok, updated_saga} ->
        state = %{state | saga: updated_saga}
        record_event(state, "saga_started", %{})

        # Find client and start executing ready steps
        case find_client(state.saga.client_id) do
          {:ok, client_pid} ->
            state = %{state | client_pid: client_pid}
            state = execute_ready_steps(state)
            {:reply, :ok, state}

          {:error, :client_not_found} ->
            # Pause saga until client connects
            {:ok, paused_saga} = update_saga_status(state.saga, "paused")
            state = %{state | saga: paused_saga}
            record_event(state, "saga_paused", %{reason: "client_not_connected"})
            {:reply, {:error, :client_not_connected}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      saga_id: state.saga_id,
      status: state.saga.status,
      pending_steps: MapSet.to_list(state.pending_steps),
      running_steps: MapSet.to_list(state.running_steps),
      completed_steps: MapSet.to_list(state.completed_steps),
      failed_steps: MapSet.to_list(state.failed_steps),
      context: state.context
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:step_completed, step_id, result}, state) do
    if MapSet.member?(state.running_steps, step_id) do
      # Validate state transition
      case StepStateMachine.validate_transition("running", "completed") do
        :ok ->
          # Validate step result
          step_definition = Map.get(state.steps, step_id, %{})

          case validate_step_result(result, step_definition) do
            :ok ->
              # Cancel timeout
              state = cancel_step_timeout(state, step_id)

              # Update step status in database with transition validation
              case update_step_status(state.saga_id, step_id, "completed", %{output: result}) do
                {:ok, _} ->
                  # Update state
                  state = %{
                    state
                    | running_steps: MapSet.delete(state.running_steps, step_id),
                      completed_steps: MapSet.put(state.completed_steps, step_id),
                      context: SagaContext.add_step_result(state.context, step_id, result)
                  }

                  # Record event
                  record_event(state, "step_completed", %{step_id: step_id, result: result})

                  # Track step completion
                  StepExecutionTracker.track_step_completed(state.saga_id, step_id)

                  # Send step result acknowledgment to client
                  send_step_result_acknowledgment(
                    state.client_pid,
                    state.saga_id,
                    step_id,
                    "completed",
                    result
                  )

                  # Check if saga is complete or execute next steps
                  state = check_saga_completion(state)
                  state = execute_ready_steps(state)

                  {:noreply, state}

                {:error, reason} ->
                  Logger.error("Failed to update step #{step_id} status: #{inspect(reason)}")
                  {:noreply, state}
              end

            {:error, validation_errors} ->
              Logger.error(
                "Step #{step_id} result validation failed: #{inspect(validation_errors)}"
              )

              # Treat validation failure as step failure
              validation_error = %{
                type: "validation_error",
                message: "Step result validation failed",
                details: %{validation_errors: validation_errors},
                retryable: false
              }

              handle_cast({:step_failed, step_id, validation_error}, state)
          end

        {:error, reason} ->
          Logger.error("Invalid state transition for step #{step_id}: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      Logger.warning("Received completion for step #{step_id} that is not running")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:step_failed, step_id, error}, state) do
    if MapSet.member?(state.running_steps, step_id) do
      # Validate state transition
      case StepStateMachine.validate_transition("running", "failed") do
        :ok ->
          # Validate error response format
          case StepResultValidator.validate_error_response(error) do
            :ok ->
              # Cancel timeout
              state = cancel_step_timeout(state, step_id)

              # Update step status in database
              case update_step_status(state.saga_id, step_id, "failed", %{error_details: error}) do
                {:ok, _} ->
                  # Update state
                  state = %{
                    state
                    | running_steps: MapSet.delete(state.running_steps, step_id),
                      failed_steps: MapSet.put(state.failed_steps, step_id)
                  }

                  # Record event
                  record_event(state, "step_failed", %{step_id: step_id, error: error})

                  # Track step failure
                  StepExecutionTracker.track_step_failed(state.saga_id, step_id, error)

                  # Send step result acknowledgment to client
                  send_step_result_acknowledgment(
                    state.client_pid,
                    state.saga_id,
                    step_id,
                    "failed",
                    error
                  )

                  # Start compensation process
                  state = start_compensation(state)

                  {:noreply, state}

                {:error, reason} ->
                  Logger.error("Failed to update step #{step_id} status: #{inspect(reason)}")
                  {:noreply, state}
              end

            {:error, validation_errors} ->
              Logger.warning(
                "Error response validation failed for step #{step_id}: #{inspect(validation_errors)}"
              )

              # Use the error anyway but log the validation issue
              # Create normalized error
              normalized_error =
                StepResultValidator.create_error_response(
                  "malformed_error",
                  "Original error response was malformed",
                  details: %{original_error: error, validation_errors: validation_errors}
                )

              # Continue with normalized error
              state = cancel_step_timeout(state, step_id)

              case update_step_status(state.saga_id, step_id, "failed", %{
                     error_details: normalized_error
                   }) do
                {:ok, _} ->
                  state = %{
                    state
                    | running_steps: MapSet.delete(state.running_steps, step_id),
                      failed_steps: MapSet.put(state.failed_steps, step_id)
                  }

                  record_event(state, "step_failed", %{step_id: step_id, error: normalized_error})

                  # Track step failure with normalized error
                  StepExecutionTracker.track_step_failed(state.saga_id, step_id, normalized_error)

                  # Send step result acknowledgment to client
                  send_step_result_acknowledgment(
                    state.client_pid,
                    state.saga_id,
                    step_id,
                    "failed",
                    normalized_error
                  )

                  state = start_compensation(state)
                  {:noreply, state}

                {:error, reason} ->
                  Logger.error("Failed to update step #{step_id} status: #{inspect(reason)}")
                  {:noreply, state}
              end
          end

        {:error, reason} ->
          Logger.error("Invalid state transition for step #{step_id}: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      Logger.warning("Received failure for step #{step_id} that is not running")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:pause, state) do
    # Cancel all running step timeouts
    state = cancel_all_timeouts(state)

    # Update saga status
    {:ok, paused_saga} = update_saga_status(state.saga, "paused")
    state = %{state | saga: paused_saga, client_pid: nil}

    record_event(state, "saga_paused", %{})
    Logger.info("Saga #{state.saga_id} paused")

    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume, state) do
    case find_client(state.saga.client_id) do
      {:ok, client_pid} ->
        # Update saga status
        {:ok, running_saga} = update_saga_status(state.saga, "running")
        state = %{state | saga: running_saga, client_pid: client_pid}

        record_event(state, "saga_resumed", %{})
        Logger.info("Saga #{state.saga_id} resumed")

        # Broadcast saga status update to client
        send_saga_status_update(client_pid, state.saga_id, "running", %{
          resumed: true,
          pending_steps: MapSet.size(state.pending_steps),
          running_steps: MapSet.size(state.running_steps)
        })

        # Resume execution of ready steps
        state = execute_ready_steps(state)
        {:noreply, state}

      {:error, :client_not_found} ->
        Logger.warning("Cannot resume saga #{state.saga_id}: client not connected")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:step_timeout, step_id}, state) do
    if MapSet.member?(state.running_steps, step_id) do
      Logger.warning("Step #{step_id} in saga #{state.saga_id} timed out")

      # Treat timeout as step failure
      error = %{type: "timeout", message: "Step execution timed out"}
      handle_cast({:step_failed, step_id, error}, state)
    else
      {:noreply, state}
    end
  end

  # Private functions

  defp via_tuple(saga_id) do
    {:via, Registry, {Kawa.SagaRegistry, saga_id}}
  end

  defp load_saga(saga_id) do
    case Repo.get(Saga, saga_id) do
      nil ->
        {:error, :saga_not_found}

      saga ->
        case Repo.get(Kawa.Schemas.WorkflowDefinition, saga.workflow_definition_id) do
          nil ->
            {:error, :workflow_definition_not_found}

          workflow_definition ->
            {:ok, saga, workflow_definition.definition}
        end
    end
  end

  defp extract_steps(workflow_definition) do
    workflow_definition
    |> Map.get("steps", [])
    |> Enum.into(%{}, fn step -> {step["id"], step} end)
  end

  defp build_execution_graph(workflow_definition) do
    steps = Map.get(workflow_definition, "steps", [])

    Enum.into(steps, %{}, fn step ->
      step_id = step["id"]
      dependencies = Map.get(step, "depends_on", [])
      {step_id, dependencies}
    end)
  end

  defp initialize_step_states(state) do
    # Load existing step states from database
    existing_steps =
      from(s in SagaStep,
        where: s.saga_id == ^state.saga_id and s.step_type == "action"
      )
      |> Repo.all()
      |> Enum.group_by(& &1.step_id)
      |> Map.new(fn {step_id, [step | _]} -> {step_id, step.status} end)

    # Initialize step sets based on existing states
    {pending, running, completed, failed} =
      Enum.reduce(
        state.steps,
        {MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new()},
        fn {step_id, _step}, {pending, running, completed, failed} ->
          case Map.get(existing_steps, step_id, "pending") do
            "pending" -> {MapSet.put(pending, step_id), running, completed, failed}
            "running" -> {pending, MapSet.put(running, step_id), completed, failed}
            "completed" -> {pending, running, MapSet.put(completed, step_id), failed}
            "failed" -> {pending, running, completed, MapSet.put(failed, step_id)}
            _ -> {MapSet.put(pending, step_id), running, completed, failed}
          end
        end
      )

    %{
      state
      | pending_steps: pending,
        running_steps: running,
        completed_steps: completed,
        failed_steps: failed
    }
  end

  defp execute_ready_steps(state) do
    if state.client_pid && state.saga.status == "running" do
      ready_steps = find_ready_to_execute_steps(state)

      Enum.reduce(ready_steps, state, fn step_id, acc_state ->
        execute_step(acc_state, step_id)
      end)
    else
      state
    end
  end

  defp find_ready_to_execute_steps(state) do
    workflow_steps = Map.get(state.workflow_definition, "steps", [])

    StepDependencyResolver.find_ready_to_execute_steps(workflow_steps, state.completed_steps)
    |> Enum.filter(fn step_id -> MapSet.member?(state.pending_steps, step_id) end)
  end

  defp execute_step(state, step_id) do
    step_definition = Map.get(state.steps, step_id)

    # Validate state transition from pending to running
    case StepStateMachine.validate_transition("pending", "running") do
      :ok ->
        # Build step input using enhanced context
        step_input = SagaContext.build_step_input(state.context, step_definition)

        # Create or update step record
        case create_or_update_step(state.saga_id, step_id, "running", %{
               input: step_input
             }) do
          {:ok, _} ->
            # Send execution request to client
            send_step_execution_request(
              state.client_pid,
              state.saga_id,
              step_id,
              state.context,
              step_definition
            )

            # Set timeout
            timeout_ref = set_step_timeout(step_id, Map.get(step_definition, "timeout", 60_000))

            # Record state transition event
            record_event(state, "step_started", %{step_id: step_id})

            # Track step execution start
            StepExecutionTracker.track_step_started(state.saga_id, step_id)

            # Update state
            %{
              state
              | pending_steps: MapSet.delete(state.pending_steps, step_id),
                running_steps: MapSet.put(state.running_steps, step_id),
                timeout_refs: Map.put(state.timeout_refs, step_id, timeout_ref)
            }

          {:error, reason} ->
            Logger.error("Failed to update step #{step_id} to running: #{inspect(reason)}")
            state
        end

      {:error, reason} ->
        Logger.error(
          "Invalid state transition for step #{step_id} (pending -> running): #{inspect(reason)}"
        )

        state
    end
  end

  defp send_step_execution_request(client_pid, saga_id, step_id, context, step_definition) do
    timeout_ms = Map.get(step_definition, "timeout", 60_000)

    # Create structured execution request
    message =
      StepExecutionProtocol.create_execution_request(
        saga_id,
        step_id,
        context,
        timeout_ms: timeout_ms
      )

    send(client_pid, {:execute_step, message})
  end

  defp set_step_timeout(step_id, timeout_ms) do
    Process.send_after(self(), {:step_timeout, step_id}, timeout_ms)
  end

  defp cancel_step_timeout(state, step_id) do
    case Map.get(state.timeout_refs, step_id) do
      nil ->
        state

      timeout_ref ->
        Process.cancel_timer(timeout_ref)
        %{state | timeout_refs: Map.delete(state.timeout_refs, step_id)}
    end
  end

  defp cancel_all_timeouts(state) do
    Enum.each(state.timeout_refs, fn {_step_id, timeout_ref} ->
      Process.cancel_timer(timeout_ref)
    end)

    %{state | timeout_refs: %{}}
  end

  defp check_saga_completion(state) do
    total_steps =
      MapSet.size(state.pending_steps) + MapSet.size(state.running_steps) +
        MapSet.size(state.completed_steps) + MapSet.size(state.failed_steps)

    completed_steps = MapSet.size(state.completed_steps)

    if completed_steps == total_steps do
      {:ok, completed_saga} = update_saga_status(state.saga, "completed")
      record_event(state, "saga_completed", %{})
      Logger.info("Saga #{state.saga_id} completed successfully")

      # Broadcast saga status update to client
      send_saga_status_update(state.client_pid, state.saga_id, "completed", %{
        total_steps: total_steps,
        completed_steps: completed_steps
      })

      %{state | saga: completed_saga}
    else
      state
    end
  end

  defp start_compensation(state) do
    Logger.info("Starting compensation for saga #{state.saga_id}")

    record_event(state, "compensation_started", %{})

    # Use CompensationEngine to handle the actual compensation logic
    case CompensationEngine.start_compensation(state.saga_id) do
      {:ok, result} ->
        Logger.info("Compensation completed successfully for saga #{state.saga_id}")

        record_event(state, "compensation_completed", %{
          compensated_steps: result.results.compensated,
          skipped_steps: result.results.skipped,
          failed_steps: result.results.failed
        })

        # Broadcast saga status update to client
        send_saga_status_update(state.client_pid, state.saga_id, result.saga.status, %{
          compensated_steps: length(result.results.compensated),
          skipped_steps: length(result.results.skipped),
          failed_compensations: length(result.results.failed)
        })

        # Update local state to reflect final saga status
        %{state | saga: result.saga}

      {:error, reason} ->
        Logger.error("Compensation failed for saga #{state.saga_id}: #{inspect(reason)}")
        record_event(state, "compensation_failed", %{reason: reason})

        # Update saga status to failed
        {:ok, failed_saga} = update_saga_status(state.saga, "failed")

        # Broadcast saga status update to client
        send_saga_status_update(state.client_pid, state.saga_id, "failed", %{
          compensation_failure_reason: reason
        })

        %{state | saga: failed_saga}
    end
  end

  defp find_client(client_id) do
    ClientRegistry.get_client_pid(client_id)
  end

  defp update_saga_status(saga, new_status) do
    changeset = Ecto.Changeset.change(saga, status: new_status)

    case new_status do
      "completed" ->
        changeset =
          Ecto.Changeset.change(changeset,
            completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )

        Repo.update(changeset)

      "paused" ->
        changeset =
          Ecto.Changeset.change(changeset,
            paused_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )

        Repo.update(changeset)

      _ ->
        Repo.update(changeset)
    end
  end

  defp create_or_update_step(saga_id, step_id, status, attrs) do
    case Repo.get_by(SagaStep, saga_id: saga_id, step_id: step_id, step_type: "action") do
      nil ->
        %SagaStep{}
        |> SagaStep.changeset(
          Map.merge(attrs, %{
            saga_id: saga_id,
            step_id: step_id,
            status: status,
            started_at:
              if(status == "running",
                do: DateTime.utc_now() |> DateTime.truncate(:second),
                else: nil
              )
          })
        )
        |> Repo.insert()

      existing_step ->
        changeset_attrs = Map.merge(attrs, %{status: status})

        changeset_attrs =
          if status in ["completed", "failed"] do
            Map.put(
              changeset_attrs,
              :completed_at,
              DateTime.utc_now() |> DateTime.truncate(:second)
            )
          else
            changeset_attrs
          end

        existing_step
        |> SagaStep.changeset(changeset_attrs)
        |> Repo.update()
    end
  end

  defp update_step_status(saga_id, step_id, status, additional_attrs) do
    create_or_update_step(saga_id, step_id, status, additional_attrs)
  end

  defp record_event(state, event_type, payload) do
    # Get next sequence number
    sequence_number = get_next_sequence_number(state.saga_id)

    %SagaEvent{}
    |> SagaEvent.changeset(%{
      saga_id: state.saga_id,
      sequence_number: sequence_number,
      event_type: event_type,
      payload: payload,
      step_id: Map.get(payload, :step_id),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  defp get_next_sequence_number(saga_id) do
    case from(e in SagaEvent,
           where: e.saga_id == ^saga_id,
           select: max(e.sequence_number)
         )
         |> Repo.one() do
      nil -> 1
      max_seq -> max_seq + 1
    end
  end

  defp validate_step_result(result, step_definition) do
    result_schema = Map.get(step_definition, "result_schema", %{})
    StepResultValidator.validate_result(result, result_schema)
  end

  defp send_step_result_acknowledgment(client_pid, saga_id, step_id, status, result_or_error) do
    if client_pid do
      message =
        StepExecutionProtocol.create_step_result_acknowledgment(
          saga_id,
          step_id,
          status,
          result_or_error
        )

      send(client_pid, {:step_result_ack, message})
    end
  end

  defp send_saga_status_update(client_pid, saga_id, status, details) do
    if client_pid do
      message = StepExecutionProtocol.create_saga_status_update(saga_id, status, details)
      send(client_pid, {:saga_status_update, message})
    end
  end
end
