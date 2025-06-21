defmodule Kawa.Repo.Migrations.CreateClients do
  use Ecto.Migration

  def up do
    # Enable UUID extension
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""

    create table(:clients, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :name, :string, null: false, size: 255
      add :version, :string, null: false, default: "1.0.0", size: 50
      add :status, :string, null: false, default: "disconnected", size: 20
      add :last_heartbeat_at, :utc_datetime
      add :connection_metadata, :map, null: false, default: %{}
      add :capabilities, :map, null: false, default: %{}
      add :last_metrics, :map, null: false, default: %{}
      add :heartbeat_interval_ms, :integer, null: false, default: 30000
      add :registered_at, :utc_datetime, null: false, default: fragment("now()")

      timestamps(type: :utc_datetime)
    end

    # Constraints
    create constraint(:clients, :clients_status_check, 
      check: "status IN ('connected', 'disconnected', 'error')")
    create constraint(:clients, :clients_heartbeat_interval_check, 
      check: "heartbeat_interval_ms > 0")
    create constraint(:clients, :clients_name_length_check, 
      check: "length(name) > 0")

    # Unique constraints
    create unique_index(:clients, [:name], name: :uk_clients_name)

    # Indexes for performance
    create index(:clients, [:status], where: "status = 'connected'", name: :idx_clients_status)
    create index(:clients, [:last_heartbeat_at], where: "status = 'connected'", name: :idx_clients_heartbeat)
  end

  def down do
    drop table(:clients)
    execute "DROP EXTENSION IF EXISTS \"uuid-ossp\""
  end
end