defmodule Kawa.Repo.Migrations.AddApiKeyFieldsToClients do
  use Ecto.Migration

  def up do
    alter table(:clients) do
      add :api_key_hash, :string, null: false, size: 255
      add :environment, :string, null: false, default: "dev", size: 20
      add :api_key_prefix, :string, null: false, size: 8
    end

    # Constraints
    create constraint(:clients, :clients_environment_check,
             check: "environment IN ('dev', 'staging', 'prod')"
           )

    # Unique index for API key hash
    create unique_index(:clients, [:api_key_hash], name: :uk_clients_api_key_hash)
  end

  def down do
    drop constraint(:clients, :clients_environment_check)
    drop index(:clients, [:api_key_hash], name: :uk_clients_api_key_hash)

    alter table(:clients) do
      remove :api_key_hash
      remove :environment
      remove :api_key_prefix
    end
  end
end
