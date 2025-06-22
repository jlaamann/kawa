defmodule Kawa.Repo.Migrations.IncreaseDefinitionChecksumLength do
  use Ecto.Migration

  def up do
    alter table(:workflow_definitions) do
      modify :definition_checksum, :string, size: 64
    end
  end

  def down do
    alter table(:workflow_definitions) do
      modify :definition_checksum, :string, size: 32
    end
  end
end
