defmodule Kawa.Execution.CompensationEngine do
  @moduledoc """
  Automatically rollback completed steps when failures occur in saga execution.

  This module implements the compensation pattern for distributed transactions,
  ensuring that when a saga fails, all completed steps are properly rolled back
  in reverse dependency order to maintain data consistency.

  ## Key Features

  - Reverse dependency traversal for proper compensation order
  - Compensation execution with comprehensive error handling
  - State tracking throughout the compensation process
  - Partial compensation support for steps without compensation logic
  - Event sourcing for compensation audit trail

  ## Compensation States

  - `pending`: Compensation needs to be executed
  - `compensating`: Compensation is currently executing
  - `compensated`: Compensation completed successfully
  - `failed`: Compensation failed during execution

  ## Compensation Order

  Steps are compensated in reverse dependency order to ensure proper rollback:
  1. Steps with no dependents are compensated first
  2. Steps are only compensated after all their dependents are compensated
  3. Steps without compensation logic are marked as skipped
  """

  require Logger

  alias Kawa.Execution.StepDependencyResolver
  alias Kawa.Execution.StepStateMachine
  alias Kawa.Execution.CompensationClient
  alias Kawa.Schemas.{Saga, SagaStep, SagaEvent}
  alias Kawa.Repo

  import Ecto.Query

  @doc """
  Initiates compensation for a failed saga.

  Returns `{:ok, compensation_plan}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> CompensationEngine.start_compensation(saga_id)
      {:ok, %{steps_to_compensate: ["step3", "step2", "step1"], total_steps: 3}}
  """
  def start_compensation(saga_id) when is_binary(saga_id) do
    with {:ok, saga} <- get_saga_with_steps(saga_id),
         {:ok, compensation_plan} <- build_compensation_plan(saga),
         {:ok, _saga} <- update_saga_status(saga, "compensating") do
      Logger.info("Starting compensation for saga #{saga_id}")
      execute_compensation_plan(saga, compensation_plan)
    end
  end

  @doc """
  Executes the compensation plan for a saga.

  Processes steps in reverse dependency order, handling partial compensations
  and error scenarios appropriately.
  """
  def execute_compensation_plan(saga, compensation_plan) do
    Logger.info("Executing compensation plan for saga #{saga.id}")

    case process_compensation_levels(saga, compensation_plan.levels) do
      {:ok, results} ->
        finalize_compensation(saga, results)

      {:error, reason} ->
        handle_compensation_failure(saga, reason)
    end
  end

  @doc """
  Builds a compensation execution plan for a saga.

  Returns `{:ok, plan}` with reverse-ordered compensation levels.
  """
  def build_compensation_plan(saga) do
    # Ensure saga_steps are loaded
    saga =
      case saga.saga_steps do
        %Ecto.Association.NotLoaded{} ->
          Repo.preload(saga, :saga_steps)

        _ ->
          saga
      end

    completed_steps = get_completed_steps(saga)

    if Enum.empty?(completed_steps) do
      {:ok, %{levels: [], total_steps: 0, message: "No steps to compensate"}}
    else
      case build_reverse_dependency_order(completed_steps) do
        {:ok, levels} ->
          {:ok, %{levels: levels, total_steps: count_steps_in_levels(levels)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Gets the current compensation status for a saga.

  Returns detailed information about the compensation progress.
  """
  def get_compensation_status(saga_id) do
    with {:ok, saga} <- get_saga_with_steps(saga_id) do
      compensation_steps =
        saga.saga_steps
        |> Enum.filter(&(&1.status in ["compensating", "compensated", "failed"]))

      # Count original completed steps (those that were completed before compensation)
      # plus those that are now compensated (which were originally completed)
      total_completed =
        saga.saga_steps |> Enum.count(&(&1.status in ["completed", "compensated"]))

      total_compensated = compensation_steps |> Enum.count(&(&1.status == "compensated"))
      total_failed = compensation_steps |> Enum.count(&(&1.status == "failed"))

      {:ok,
       %{
         saga_status: saga.status,
         total_completed_steps: total_completed,
         total_compensated: total_compensated,
         total_failed_compensations: total_failed,
         compensation_progress: calculate_progress(total_completed, total_compensated),
         active_compensations:
           compensation_steps |> Enum.filter(&(&1.status == "compensating")) |> Enum.count()
       }}
    end
  end

  # Private functions

  defp get_saga_with_steps(saga_id) do
    saga =
      Saga
      |> where([s], s.id == ^saga_id)
      |> preload(:saga_steps)
      |> Repo.one()

    case saga do
      nil -> {:error, :saga_not_found}
      saga -> {:ok, saga}
    end
  end

  defp get_completed_steps(saga) do
    saga.saga_steps
    |> Enum.filter(&(&1.status == "completed"))
  end

  defp build_reverse_dependency_order(steps) do
    # Convert to step format expected by dependency resolver
    step_definitions =
      steps
      |> Enum.map(fn step ->
        %{"id" => step.step_id, "depends_on" => step.depends_on}
      end)

    case StepDependencyResolver.build_execution_levels(step_definitions) do
      {:ok, levels} ->
        # Reverse the levels for compensation (last executed first)
        reversed_levels = Enum.reverse(levels)
        {:ok, reversed_levels}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_compensation_levels(saga, levels) do
    results = %{compensated: [], failed: [], skipped: []}

    Enum.reduce_while(levels, {:ok, results}, fn level, {:ok, acc_results} ->
      case compensate_level(saga, level) do
        {:ok, level_results} ->
          merged_results = merge_results(acc_results, level_results)
          {:cont, {:ok, merged_results}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp compensate_level(saga, step_ids) do
    Logger.info("Compensating level with steps: #{inspect(step_ids)}")

    # Process all steps in the level concurrently
    step_ids
    |> Enum.map(fn step_id ->
      Task.async(fn -> compensate_single_step(saga, step_id) end)
    end)
    # 30 second timeout
    |> Task.await_many(30_000)
    |> Enum.reduce({:ok, %{compensated: [], failed: [], skipped: []}}, fn result, acc ->
      case {result, acc} do
        {{:ok, :compensated, step_id}, {:ok, results}} ->
          {:ok, %{results | compensated: [step_id | results.compensated]}}

        {{:ok, :skipped, step_id}, {:ok, results}} ->
          {:ok, %{results | skipped: [step_id | results.skipped]}}

        {{:error, step_id, reason}, {:ok, results}} ->
          failed_entry = %{step_id: step_id, reason: to_string(reason)}
          {:ok, %{results | failed: [failed_entry | results.failed]}}

        {_, {:error, _} = error} ->
          error
      end
    end)
  end

  defp compensate_single_step(saga, step_id) do
    step = Enum.find(saga.saga_steps, &(&1.step_id == step_id))

    if step do
      case update_step_status(step, "compensating") do
        {:ok, updated_step} ->
          execute_step_compensation(updated_step)

        {:error, reason} ->
          {:error, step_id, reason}
      end
    else
      {:error, step_id, :step_not_found}
    end
  end

  defp execute_step_compensation(step) do
    # Check if step has compensation logic
    compensation_available = has_compensation?(step)

    if compensation_available do
      case perform_compensation(step) do
        {:ok, _result} ->
          update_step_status(step, "compensated")
          create_compensation_event(step, "compensated")
          {:ok, :compensated, step.step_id}

        {:error, reason} ->
          update_step_status(step, "failed")
          create_compensation_event(step, "failed", reason)
          {:error, step.step_id, reason}
      end
    else
      # Step has no compensation - mark as skipped
      create_compensation_event(step, "skipped", "No compensation defined")
      {:ok, :skipped, step.step_id}
    end
  end

  defp has_compensation?(step) do
    # Check if step has compensation logic defined
    # This would typically be determined by the workflow definition
    # For now, we'll assume all completed steps can be compensated
    # unless explicitly marked otherwise in metadata
    compensation_config = get_in(step.execution_metadata, ["compensation"])

    case compensation_config do
      # Default: assume compensation is available
      nil -> true
      false -> false
      %{"available" => false} -> false
      _ -> true
    end
  end

  defp perform_compensation(step) do
    Logger.info("Performing compensation for step #{step.step_id}")

    # Get the saga to provide context for compensation
    case get_saga_with_client(step.saga_id) do
      {:ok, saga} ->
        # Pass step with additional client context
        step_with_context = Map.put(step, :client_id, saga.client_id)
        CompensationClient.compensate_step(step.saga_id, step_with_context)

      {:error, reason} ->
        Logger.error("Failed to get saga for compensation: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_step_status(step, new_status) do
    case StepStateMachine.validate_transition(step.status, new_status) do
      :ok ->
        changeset =
          step
          |> SagaStep.changeset(%{
            status: new_status,
            completed_at:
              if(new_status in ["compensated", "failed"],
                do: DateTime.utc_now() |> DateTime.truncate(:second),
                else: nil
              )
          })

        Repo.update(changeset)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_saga_status(saga, new_status) do
    changeset =
      saga
      |> Saga.changeset(%{
        status: new_status,
        completed_at:
          if(new_status in ["compensated", "failed"],
            do: DateTime.utc_now() |> DateTime.truncate(:second),
            else: nil
          )
      })

    Repo.update(changeset)
  end

  defp create_compensation_event(step, event_type, details \\ nil) do
    event_data = %{
      saga_id: step.saga_id,
      step_id: step.step_id,
      event_type: "step_#{event_type}",
      sequence_number: get_next_sequence_number(step.saga_id),
      payload: %{
        step_status: event_type,
        details: details
      },
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %SagaEvent{}
    |> SagaEvent.changeset(event_data)
    |> Repo.insert()
  end

  defp finalize_compensation(saga, results) do
    Logger.info("Finalizing compensation for saga #{saga.id}")

    final_status =
      cond do
        length(results.failed) > 0 -> "failed"
        length(results.compensated) > 0 or length(results.skipped) > 0 -> "compensated"
        true -> "compensated"
      end

    case update_saga_status(saga, final_status) do
      {:ok, updated_saga} ->
        create_saga_compensation_event(updated_saga, final_status, results)
        {:ok, %{saga: updated_saga, results: results}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_compensation_failure(saga, reason) do
    Logger.error("Compensation failed for saga #{saga.id}: #{inspect(reason)}")

    update_saga_status(saga, "failed")
    create_saga_compensation_event(saga, "failed", reason)

    {:error, reason}
  end

  defp create_saga_compensation_event(saga, event_type, details) do
    event_data = %{
      saga_id: saga.id,
      event_type: "saga_compensation_#{event_type}",
      sequence_number: get_next_sequence_number(saga.id),
      payload: %{
        final_status: event_type,
        details: details
      },
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %SagaEvent{}
    |> SagaEvent.changeset(event_data)
    |> Repo.insert()
  end

  defp merge_results(acc, new_results) do
    %{
      compensated: acc.compensated ++ new_results.compensated,
      failed: acc.failed ++ new_results.failed,
      skipped: acc.skipped ++ new_results.skipped
    }
  end

  defp count_steps_in_levels(levels) do
    levels |> List.flatten() |> length()
  end

  defp calculate_progress(total, completed) when total > 0 do
    Float.round(completed / total * 100, 2)
  end

  defp calculate_progress(_, _), do: 0.0

  defp get_next_sequence_number(_saga_id) do
    # Use timestamp in microseconds to ensure uniqueness across concurrent operations
    DateTime.utc_now() |> DateTime.to_unix(:microsecond)
  end

  defp get_saga_with_client(saga_id) do
    case Repo.get(Saga, saga_id) do
      nil -> {:error, :saga_not_found}
      saga -> {:ok, saga}
    end
  end
end
