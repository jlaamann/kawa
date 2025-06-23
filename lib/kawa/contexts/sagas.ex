defmodule Kawa.Contexts.Sagas do
  @moduledoc """
  Context for managing and querying sagas with filtering and pagination.
  """

  import Ecto.Query, warn: false
  alias Kawa.Repo
  alias Kawa.Schemas.{Saga, SagaStep, SagaEvent}

  @doc """
  Lists sagas with filtering and pagination support.

  ## Options
    * `:status` - Filter by saga status
    * `:client_id` - Filter by client ID
    * `:workflow_name` - Filter by workflow name
    * `:page` - Page number (default: 1)
    * `:page_size` - Number of items per page (default: 20)
    * `:sort_by` - Field to sort by (default: :inserted_at)
    * `:sort_order` - Sort order (:asc or :desc, default: :desc)

  Returns `{sagas, meta}` where meta contains pagination info.
  """
  def list_sagas(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_order = Keyword.get(opts, :sort_order, :desc)

    base_query =
      Saga
      |> join(:left, [s], c in assoc(s, :client))
      |> join(:left, [s], w in assoc(s, :workflow_definition))
      |> apply_filters(opts)

    # Get total count for pagination (without preloads)
    total_count = Repo.aggregate(base_query, :count)

    # Apply preloads and sorting for the actual query
    query =
      base_query
      |> preload([s, c, w], client: c, workflow_definition: w)
      |> apply_sorting(sort_by, sort_order)

    # Apply pagination
    sagas =
      query
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    # Calculate pagination metadata
    total_pages = ceil(total_count / page_size)

    meta = %{
      page: page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages,
      has_next: page < total_pages,
      has_prev: page > 1
    }

    {sagas, meta}
  end

  @doc """
  Gets saga progress information including step completion statistics.
  """
  def get_saga_progress(saga_id) do
    steps_query =
      from s in SagaStep,
        where: s.saga_id == ^saga_id and s.step_type == "action",
        select: %{
          total: count(s.id),
          completed: count(fragment("CASE WHEN ? = 'completed' THEN 1 END", s.status)),
          failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", s.status)),
          running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", s.status)),
          pending: count(fragment("CASE WHEN ? = 'pending' THEN 1 END", s.status)),
          compensating: count(fragment("CASE WHEN ? = 'compensating' THEN 1 END", s.status)),
          compensated: count(fragment("CASE WHEN ? = 'compensated' THEN 1 END", s.status))
        }

    case Repo.one(steps_query) do
      nil ->
        %{
          total: 0,
          completed: 0,
          failed: 0,
          running: 0,
          pending: 0,
          compensating: 0,
          compensated: 0,
          progress_percentage: 0
        }

      stats ->
        progress_percentage =
          if stats.total > 0 do
            round(stats.completed / stats.total * 100)
          else
            0
          end

        Map.put(stats, :progress_percentage, progress_percentage)
    end
  end

  @doc """
  Gets a single saga with all its events and steps data for detailed view.
  """
  def get_saga_with_details(id) do
    saga =
      Saga
      |> where([s], s.id == ^id)
      |> join(:left, [s], c in assoc(s, :client))
      |> join(:left, [s], w in assoc(s, :workflow_definition))
      |> preload([s, c, w],
        client: c,
        workflow_definition: w
      )
      |> Repo.one()

    case saga do
      nil ->
        nil

      saga ->
        # Load events in chronological order (by sequence_number)
        events =
          from(e in SagaEvent,
            where: e.saga_id == ^id,
            order_by: [asc: e.sequence_number]
          )
          |> Repo.all()

        # Load steps for input/output data
        steps_map =
          from(s in SagaStep,
            where: s.saga_id == ^id
          )
          |> Repo.all()
          |> Enum.into(%{}, fn step -> {step.step_id, step} end)

        # Combine events with step data
        enriched_events =
          Enum.map(events, fn event ->
            step_data = Map.get(steps_map, event.step_id, nil)
            Map.put(event, :step_data, step_data)
          end)

        saga
        |> Map.put(:saga_events, enriched_events)
        |> Map.put(:saga_steps, Map.values(steps_map))
    end
  end

  @doc """
  Gets recently created sagas (last 24 hours) for dashboard display.
  """
  def get_recent_sagas(limit \\ 10) do
    yesterday = DateTime.utc_now() |> DateTime.add(-24, :hour)

    Saga
    |> where([s], s.inserted_at >= ^yesterday)
    |> join(:left, [s], c in assoc(s, :client))
    |> join(:left, [s], w in assoc(s, :workflow_definition))
    |> preload([s, c, w], client: c, workflow_definition: w)
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets saga statistics grouped by status.
  """
  def get_saga_stats do
    query =
      from s in Saga,
        group_by: s.status,
        select: {s.status, count(s.id)}

    Repo.all(query)
    |> Enum.into(%{})
  end

  @doc """
  Gets saga statistics grouped by status for the last N days.
  """
  def get_saga_stats_by_day(days \\ 7) do
    start_date = DateTime.utc_now() |> DateTime.add(-days, :day)

    query =
      from s in Saga,
        where: s.inserted_at >= ^start_date,
        group_by: [fragment("DATE(?)", s.inserted_at), s.status],
        select: {fragment("DATE(?)", s.inserted_at), s.status, count(s.id)},
        order_by: [asc: fragment("DATE(?)", s.inserted_at)]

    Repo.all(query)
    |> Enum.group_by(fn {date, _status, _count} -> date end)
    |> Enum.map(fn {date, entries} ->
      stats =
        entries
        |> Enum.map(fn {_date, status, count} -> {status, count} end)
        |> Enum.into(%{})

      {date, stats}
    end)
  end

  # Private functions

  defp apply_filters(query, opts) do
    query
    |> filter_by_status(Keyword.get(opts, :status))
    |> filter_by_client_id(Keyword.get(opts, :client_id))
    |> filter_by_workflow_name(Keyword.get(opts, :workflow_name))
    |> filter_by_correlation_id(Keyword.get(opts, :correlation_id))
    |> filter_by_date_range(Keyword.get(opts, :date_from), Keyword.get(opts, :date_to))
  end

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status) when is_binary(status) do
    where(query, [s], s.status == ^status)
  end

  defp filter_by_status(query, statuses) when is_list(statuses) do
    where(query, [s], s.status in ^statuses)
  end

  defp filter_by_client_id(query, nil), do: query

  defp filter_by_client_id(query, client_id) do
    where(query, [s], s.client_id == ^client_id)
  end

  defp filter_by_workflow_name(query, nil), do: query

  defp filter_by_workflow_name(query, workflow_name) do
    where(query, [s, c, w], ilike(w.name, ^"%#{workflow_name}%"))
  end

  defp filter_by_correlation_id(query, nil), do: query

  defp filter_by_correlation_id(query, correlation_id) do
    where(query, [s], ilike(s.correlation_id, ^"%#{correlation_id}%"))
  end

  defp filter_by_date_range(query, nil, nil), do: query

  defp filter_by_date_range(query, date_from, nil) do
    where(query, [s], s.inserted_at >= ^date_from)
  end

  defp filter_by_date_range(query, nil, date_to) do
    where(query, [s], s.inserted_at <= ^date_to)
  end

  defp filter_by_date_range(query, date_from, date_to) do
    where(query, [s], s.inserted_at >= ^date_from and s.inserted_at <= ^date_to)
  end

  defp apply_sorting(query, :inserted_at, :desc) do
    order_by(query, [s], desc: s.inserted_at)
  end

  defp apply_sorting(query, :inserted_at, :asc) do
    order_by(query, [s], asc: s.inserted_at)
  end

  defp apply_sorting(query, :status, :desc) do
    order_by(query, [s], desc: s.status)
  end

  defp apply_sorting(query, :status, :asc) do
    order_by(query, [s], asc: s.status)
  end

  defp apply_sorting(query, :correlation_id, :desc) do
    order_by(query, [s], desc: s.correlation_id)
  end

  defp apply_sorting(query, :correlation_id, :asc) do
    order_by(query, [s], asc: s.correlation_id)
  end

  defp apply_sorting(query, :started_at, :desc) do
    order_by(query, [s], desc: s.started_at)
  end

  defp apply_sorting(query, :started_at, :asc) do
    order_by(query, [s], asc: s.started_at)
  end

  defp apply_sorting(query, :completed_at, :desc) do
    order_by(query, [s], desc: s.completed_at)
  end

  defp apply_sorting(query, :completed_at, :asc) do
    order_by(query, [s], asc: s.completed_at)
  end

  # Default fallback
  defp apply_sorting(query, _field, _order) do
    order_by(query, [s], desc: s.inserted_at)
  end
end
