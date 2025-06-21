defmodule Kawa.Repo.Migrations.CreateWorkflowDefinitions do
  use Ecto.Migration

  def up do
    create table(:workflow_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :name, :string, null: false, size: 255
      add :version, :string, null: false, default: "1.0.0", size: 50
      add :client_id, references(:clients, type: :uuid, on_delete: :delete_all), null: false
      add :module_name, :string, null: false, size: 500
      add :definition, :map, null: false
      add :definition_checksum, :string, null: false, size: 32
      add :default_timeout_ms, :integer, null: false, default: 300_000

      add :default_retry_policy, :map,
        null: false,
        default: %{"max_retries" => 3, "backoff_ms" => 1000}

      add :is_active, :boolean, null: false, default: true
      add :validation_errors, {:array, :map}, null: false, default: []
      add :registered_at, :utc_datetime, null: false, default: fragment("now()")

      timestamps(type: :utc_datetime)
    end

    # Constraints
    create constraint(:workflow_definitions, :workflow_definitions_timeout_check,
             check: "default_timeout_ms > 0"
           )

    create constraint(:workflow_definitions, :workflow_definitions_name_length_check,
             check: "length(name) > 0"
           )

    create constraint(:workflow_definitions, :workflow_definitions_module_length_check,
             check: "length(module_name) > 0"
           )

    # Unique constraints
    create unique_index(:workflow_definitions, [:client_id, :name, :version],
             name: :uk_workflow_definitions_client_name_version
           )

    # Indexes for performance
    create index(:workflow_definitions, [:client_id, :is_active],
             name: :idx_workflow_definitions_client_active
           )

    create index(:workflow_definitions, [:name], name: :idx_workflow_definitions_name)
  end

  def down do
    drop table(:workflow_definitions)
  end
end
