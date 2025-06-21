defmodule Kawa.Schemas.SagaStep do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "saga_steps" do
    field :step_id, :string
    field :status, :string, default: "pending"
    field :step_type, :string, default: "action"
    field :input, :map, default: %{}
    field :output, :map, default: %{}
    field :error_details, :map, default: %{}
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :timeout_at, :utc_datetime
    field :retry_count, :integer, default: 0
    field :depends_on, {:array, :string}, default: []
    field :execution_metadata, :map, default: %{}

    belongs_to :saga, Kawa.Schemas.Saga

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending running completed failed compensating compensated skipped)
  @valid_step_types ~w(action compensation)

  def changeset(saga_step, attrs) do
    saga_step
    |> cast(attrs, [
      :step_id,
      :status,
      :step_type,
      :input,
      :output,
      :error_details,
      :started_at,
      :completed_at,
      :timeout_at,
      :retry_count,
      :depends_on,
      :execution_metadata,
      :saga_id
    ])
    |> validate_required([:step_id, :status, :step_type, :saga_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:step_type, @valid_step_types)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> validate_length(:step_id, min: 1, max: 100)
    |> unique_constraint([:saga_id, :step_id, :step_type])
  end
end
