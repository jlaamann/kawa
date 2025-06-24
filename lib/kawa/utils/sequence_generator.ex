defmodule Kawa.Utils.SequenceGenerator do
  @moduledoc """
  Utility for generating sequential sequence numbers for saga events.

  Provides atomic sequence number generation to avoid race conditions
  when multiple processes create events for the same saga simultaneously.
  """

  alias Kawa.Repo
  alias Kawa.Schemas.SagaEvent
  import Ecto.Query

  @doc """
  Atomically creates a saga event with the next sequential sequence number.

  This function ensures that sequence numbers are consecutive for each saga
  by using a database transaction to get the next number and create the event
  atomically.
  """
  def create_saga_event_with_sequence(event_attrs) do
    Repo.transaction(fn ->
      saga_id = event_attrs[:saga_id] || event_attrs["saga_id"]

      if is_nil(saga_id) do
        Repo.rollback(:missing_saga_id)
      end

      # Get next sequence number within transaction
      sequence_number = get_next_sequence_number_atomic(saga_id)

      # Add sequence number to event attributes
      event_attrs_with_seq = Map.put(event_attrs, :sequence_number, sequence_number)

      # Create the event
      case %SagaEvent{}
           |> SagaEvent.changeset(event_attrs_with_seq)
           |> Repo.insert() do
        {:ok, event} -> event
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Gets the next sequence number for a saga within a transaction.

  This should only be called within a database transaction to ensure
  atomicity with the event insertion.
  """
  def get_next_sequence_number_atomic(saga_id) do
    # Use PostgreSQL advisory lock to ensure atomicity for this saga
    # Convert saga_id UUID to a numeric lock ID by hashing
    # Max int32 value
    lock_id = :erlang.phash2(saga_id, 2_147_483_647)

    # Acquire advisory lock for this saga
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_id])

    # Now safely get the max sequence number
    max_seq =
      from(e in SagaEvent,
        where: e.saga_id == ^saga_id,
        select: max(e.sequence_number)
      )
      |> Repo.one()

    case max_seq do
      # First event for this saga
      nil -> 1
      max_seq -> max_seq + 1
    end
  end
end
