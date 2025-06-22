defmodule Kawa.Repo.Migrations.DropWorkflowStepsTable do
  use Ecto.Migration

  def change do
    drop table(:workflow_steps)
  end
end
