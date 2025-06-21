defmodule Kawa.Schemas.Saga do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sagas" do
    field :correlation_id, :string
    field :status, :string, default: "pending"
    field :input, :map, default: %{}
    field :context, :map, default: %{}
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :paused_at, :utc_datetime
    field :timeout_at, :utc_datetime
    field :total_retry_count, :integer, default: 0

    belongs_to :workflow_definition, Kawa.Schemas.WorkflowDefinition
    belongs_to :client, Kawa.Schemas.Client

    has_many :saga_steps, Kawa.Schemas.SagaStep
    has_many :saga_events, Kawa.Schemas.SagaEvent

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending running paused completed failed compensating compensated)

  def changeset(saga, attrs) do
    saga
    |> cast(attrs, [
      :correlation_id,
      :status,
      :input,
      :context,
      :metadata,
      :started_at,
      :completed_at,
      :paused_at,
      :timeout_at,
      :total_retry_count,
      :workflow_definition_id,
      :client_id
    ])
    |> validate_required([:correlation_id, :status, :workflow_definition_id, :client_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:total_retry_count, greater_than_or_equal_to: 0)
    |> validate_length(:correlation_id, min: 1, max: 255)
    |> unique_constraint(:correlation_id)
  end

  def create_changeset(saga, attrs) do
    saga
    |> changeset(attrs)
    |> put_change(:started_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
