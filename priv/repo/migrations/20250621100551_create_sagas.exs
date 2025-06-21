defmodule Kawa.Repo.Migrations.CreateSagas do
  use Ecto.Migration

  def up do
    create table(:sagas, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")

      add :workflow_definition_id,
          references(:workflow_definitions, type: :uuid, on_delete: :restrict),
          null: false

      add :client_id, references(:clients, type: :uuid, on_delete: :restrict), null: false
      add :correlation_id, :string, null: false, size: 255
      add :status, :string, null: false, default: "pending", size: 20
      add :input, :map, null: false, default: %{}
      add :context, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime, null: false, default: fragment("now()")
      add :completed_at, :utc_datetime
      add :paused_at, :utc_datetime
      add :timeout_at, :utc_datetime
      add :total_retry_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # Constraints
    create constraint(:sagas, :sagas_status_check,
             check:
               "status IN ('pending', 'running', 'paused', 'completed', 'failed', 'compensating', 'compensated')"
           )

    create constraint(:sagas, :sagas_retry_count_check, check: "total_retry_count >= 0")

    create constraint(:sagas, :sagas_correlation_id_length_check,
             check: "length(correlation_id) > 0"
           )

    # Unique constraints
    create unique_index(:sagas, [:correlation_id], name: :uk_sagas_correlation_id)

    # Indexes for performance
    create index(:sagas, [:status],
             where: "status IN ('running', 'paused')",
             name: :idx_sagas_status
           )

    create index(:sagas, [:client_id, :status], name: :idx_sagas_client_status)
    create index(:sagas, [:timeout_at], where: "timeout_at IS NOT NULL", name: :idx_sagas_timeout)
    create index(:sagas, [:correlation_id], name: :idx_sagas_correlation_id)
    create index(:sagas, [:started_at], name: :idx_sagas_started_at)
  end

  def down do
    drop table(:sagas)
  end
end
