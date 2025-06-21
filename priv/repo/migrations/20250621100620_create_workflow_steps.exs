defmodule Kawa.Repo.Migrations.CreateWorkflowSteps do
  use Ecto.Migration

  def up do
    create table(:workflow_steps, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")

      add :workflow_definition_id,
          references(:workflow_definitions, type: :uuid, on_delete: :delete_all),
          null: false

      add :step_id, :string, null: false, size: 100
      add :step_name, :string, null: false, size: 255
      add :step_definition, :map, null: false
      add :depends_on, {:array, :string}, null: false, default: []
      add :execution_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # Constraints
    create constraint(:workflow_steps, :workflow_steps_step_id_length_check,
             check: "length(step_id) > 0"
           )

    create constraint(:workflow_steps, :workflow_steps_step_name_length_check,
             check: "length(step_name) > 0"
           )

    create constraint(:workflow_steps, :workflow_steps_execution_order_check,
             check: "execution_order >= 0"
           )

    # Unique constraints
    create unique_index(:workflow_steps, [:workflow_definition_id, :step_id],
             name: :uk_workflow_steps_definition_step
           )

    # Indexes for performance
    create index(:workflow_steps, [:workflow_definition_id], name: :idx_workflow_steps_definition)
  end

  def down do
    drop table(:workflow_steps)
  end
end
