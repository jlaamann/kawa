defmodule Kawa.Repo.Migrations.CreateSagaEvents do
  use Ecto.Migration

  def up do
    create table(:saga_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :saga_id, references(:sagas, type: :uuid, on_delete: :delete_all), null: false
      add :sequence_number, :bigint, null: false
      add :event_type, :string, null: false, size: 50
      add :step_id, :string, size: 100
      add :payload, :map, null: false, default: %{}
      add :before_state, :map
      add :after_state, :map
      add :duration_ms, :integer
      add :occurred_at, :utc_datetime, null: false, default: fragment("now()")

      timestamps(inserted_at: :inserted_at, updated_at: false, type: :utc_datetime)
    end

    # Constraints
    create constraint(:saga_events, :saga_events_event_type_length_check,
             check: "length(event_type) > 0"
           )

    create constraint(:saga_events, :saga_events_duration_check,
             check: "duration_ms IS NULL OR duration_ms >= 0"
           )

    # Unique constraints
    create unique_index(:saga_events, [:saga_id, :sequence_number],
             name: :uk_saga_events_saga_sequence
           )

    # Indexes for performance
    create index(:saga_events, [:saga_id, :sequence_number], name: :idx_saga_events_saga_sequence)
    create index(:saga_events, [:occurred_at], name: :idx_saga_events_occurred_at)
    create index(:saga_events, [:event_type], name: :idx_saga_events_event_type)
  end

  def down do
    drop table(:saga_events)
  end
end
