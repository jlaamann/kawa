defmodule Kawa.Schemas.Client do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "clients" do
    field :name, :string
    field :version, :string, default: "1.0.0"
    field :status, :string, default: "disconnected"
    field :last_heartbeat_at, :utc_datetime
    field :connection_metadata, :map, default: %{}
    field :capabilities, :map, default: %{}
    field :last_metrics, :map, default: %{}
    field :heartbeat_interval_ms, :integer, default: 30000
    field :registered_at, :utc_datetime
    field :api_key_hash, :string
    field :environment, :string
    field :api_key_prefix, :string

    # Virtual field for the actual API key (not stored)
    field :api_key, :string, virtual: true

    # Associations will be added when schemas are created
    # has_many :workflow_definitions, Kawa.WorkflowDefinition
    # has_many :sagas, Kawa.Saga

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(connected disconnected error)
  @valid_environments ~w(dev staging prod)

  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :name,
      :version,
      :status,
      :last_heartbeat_at,
      :connection_metadata,
      :capabilities,
      :last_metrics,
      :heartbeat_interval_ms,
      :registered_at,
      :environment
    ])
    |> validate_required([:name, :environment])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:environment, @valid_environments)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:heartbeat_interval_ms, greater_than: 0)
    |> unique_constraint(:name, name: :uk_clients_name)
    |> unique_constraint(:api_key_hash, name: :uk_clients_api_key_hash)
  end

  def create_changeset(client, attrs) do
    client
    |> changeset(attrs)
    |> put_change(:registered_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> generate_api_key()
  end

  defp generate_api_key(changeset) do
    if changeset.valid? do
      environment = get_field(changeset, :environment)
      {api_key, api_key_hash, api_key_prefix} = Kawa.Utils.ApiKey.generate(environment)

      changeset
      |> put_change(:api_key, api_key)
      |> put_change(:api_key_hash, api_key_hash)
      |> put_change(:api_key_prefix, api_key_prefix)
    else
      changeset
    end
  end
end
