defmodule Kawa.Schemas.WorkflowDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_definitions" do
    field :name, :string
    field :version, :string, default: "1.0.0"
    field :module_name, :string
    field :definition, :map
    field :definition_checksum, :string
    field :default_timeout_ms, :integer, default: 300_000
    field :default_retry_policy, :map, default: %{"max_retries" => 3, "backoff_ms" => 1000}
    field :is_active, :boolean, default: true
    field :validation_errors, {:array, :map}, default: []
    field :registered_at, :utc_datetime

    belongs_to :client, Kawa.Schemas.Client
    has_many :sagas, Kawa.Schemas.Saga

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow_definition, attrs) do
    workflow_definition
    |> cast(attrs, [
      :name,
      :version,
      :module_name,
      :definition,
      :definition_checksum,
      :default_timeout_ms,
      :default_retry_policy,
      :is_active,
      :validation_errors,
      :registered_at,
      :client_id
    ])
    |> validate_required([:name, :version, :module_name, :definition, :client_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:module_name, min: 1, max: 500)
    |> validate_number(:default_timeout_ms, greater_than: 0)
    |> unique_constraint([:client_id, :name, :version])
  end
end
