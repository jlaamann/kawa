defmodule Kawa.Repo.Migrations.CreateSagaSteps do
  use Ecto.Migration

  def up do
    create table(:saga_steps, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :saga_id, references(:sagas, type: :uuid, on_delete: :delete_all), null: false
      add :step_id, :string, null: false, size: 100
      add :status, :string, null: false, default: "pending", size: 20
      add :step_type, :string, null: false, default: "action", size: 20
      add :input, :map, null: false, default: %{}
      add :output, :map, null: false, default: %{}
      add :error_details, :map, null: false, default: %{}
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :timeout_at, :utc_datetime
      add :retry_count, :integer, null: false, default: 0
      add :depends_on, {:array, :string}, null: false, default: []
      add :execution_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Constraints
    create constraint(:saga_steps, :saga_steps_status_check, 
      check: "status IN ('pending', 'running', 'completed', 'failed', 'compensating', 'compensated', 'skipped')")
    create constraint(:saga_steps, :saga_steps_step_type_check, 
      check: "step_type IN ('action', 'compensation')")
    create constraint(:saga_steps, :saga_steps_retry_count_check, 
      check: "retry_count >= 0")
    create constraint(:saga_steps, :saga_steps_step_id_length_check, 
      check: "length(step_id) > 0")

    # Unique constraints
    create unique_index(:saga_steps, [:saga_id, :step_id, :step_type], 
      name: :uk_saga_steps_saga_step_type)

    # Indexes for performance
    create index(:saga_steps, [:saga_id, :status], name: :idx_saga_steps_saga_status)
    create index(:saga_steps, [:status], where: "status IN ('running', 'failed')", name: :idx_saga_steps_status)
  end

  def down do
    drop table(:saga_steps)
  end
end