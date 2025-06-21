defmodule Kawa.Schemas.SagaEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "saga_events" do
    field :sequence_number, :integer
    field :event_type, :string
    field :step_id, :string
    field :payload, :map, default: %{}
    field :before_state, :map
    field :after_state, :map
    field :duration_ms, :integer
    field :occurred_at, :utc_datetime

    belongs_to :saga, Kawa.Schemas.Saga

    timestamps(inserted_at: :inserted_at, updated_at: false, type: :utc_datetime)
  end

  def changeset(saga_event, attrs) do
    saga_event
    |> cast(attrs, [
      :sequence_number,
      :event_type,
      :step_id,
      :payload,
      :before_state,
      :after_state,
      :duration_ms,
      :occurred_at,
      :saga_id
    ])
    |> validate_required([:sequence_number, :event_type, :saga_id])
    |> validate_length(:event_type, min: 1, max: 50)
    |> validate_length(:step_id, max: 100)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> unique_constraint([:saga_id, :sequence_number])
  end

  def create_changeset(saga_event, attrs) do
    saga_event
    |> changeset(attrs)
    |> put_change(:occurred_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
