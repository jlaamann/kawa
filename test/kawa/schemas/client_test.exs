defmodule Kawa.Schemas.ClientTest do
  use Kawa.DataCase, async: true

  alias Kawa.Schemas.Client

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod"
      }

      changeset = Client.changeset(%Client{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :name) == "test-client"
      assert get_change(changeset, :environment) == "prod"
    end

    test "invalid changeset without name" do
      attrs = %{"environment" => "prod"}

      changeset = Client.changeset(%Client{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset without environment" do
      attrs = %{"name" => "test-client"}

      changeset = Client.changeset(%Client{}, attrs)

      refute changeset.valid?
      assert %{environment: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset with invalid environment" do
      attrs = %{
        "name" => "test-client",
        "environment" => "invalid"
      }

      changeset = Client.changeset(%Client{}, attrs)

      refute changeset.valid?
      assert %{environment: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with invalid status" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod",
        "status" => "invalid"
      }

      changeset = Client.changeset(%Client{}, attrs)

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with negative heartbeat interval" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod",
        "heartbeat_interval_ms" => -1000
      }

      changeset = Client.changeset(%Client{}, attrs)

      refute changeset.valid?
      assert %{heartbeat_interval_ms: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "invalid changeset with empty name" do
      attrs = %{
        "name" => "",
        "environment" => "prod"
      }

      changeset = Client.changeset(%Client{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "valid changeset with all valid environments" do
      for env <- ["dev", "staging", "prod"] do
        attrs = %{
          "name" => "test-client-#{env}",
          "environment" => env
        }

        changeset = Client.changeset(%Client{}, attrs)
        assert changeset.valid?, "Environment #{env} should be valid"
      end
    end

    test "valid changeset with all valid statuses" do
      for status <- ["connected", "disconnected", "error"] do
        attrs = %{
          "name" => "test-client",
          "environment" => "prod",
          "status" => status
        }

        changeset = Client.changeset(%Client{}, attrs)
        assert changeset.valid?, "Status #{status} should be valid"
      end
    end

    test "valid changeset with optional fields" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod",
        "version" => "2.0.0",
        "connection_metadata" => %{"key" => "value"},
        "capabilities" => %{"feature1" => true},
        "last_metrics" => %{"cpu" => 50},
        "heartbeat_interval_ms" => 60000
      }

      changeset = Client.changeset(%Client{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :version) == "2.0.0"
      assert get_change(changeset, :connection_metadata) == %{"key" => "value"}
      assert get_change(changeset, :capabilities) == %{"feature1" => true}
      assert get_change(changeset, :last_metrics) == %{"cpu" => 50}
      assert get_change(changeset, :heartbeat_interval_ms) == 60000
    end
  end

  describe "create_changeset/2" do
    test "generates API key fields" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod"
      }

      changeset = Client.create_changeset(%Client{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :api_key) != nil
      assert get_change(changeset, :api_key_hash) != nil
      assert get_change(changeset, :api_key_prefix) != nil
      assert get_change(changeset, :registered_at) != nil

      # Verify API key format
      api_key = get_change(changeset, :api_key)
      assert String.starts_with?(api_key, "kawa_prod_")

      # Verify prefix
      prefix = get_change(changeset, :api_key_prefix)
      assert prefix == "kawa_pro"
    end

    test "generates different API keys for different environments" do
      attrs_prod = %{"name" => "client1", "environment" => "prod"}
      attrs_dev = %{"name" => "client2", "environment" => "dev"}

      changeset_prod = Client.create_changeset(%Client{}, attrs_prod)
      changeset_dev = Client.create_changeset(%Client{}, attrs_dev)

      api_key_prod = get_change(changeset_prod, :api_key)
      api_key_dev = get_change(changeset_dev, :api_key)
      prefix_prod = get_change(changeset_prod, :api_key_prefix)
      prefix_dev = get_change(changeset_dev, :api_key_prefix)

      assert String.starts_with?(api_key_prod, "kawa_prod_")
      assert String.starts_with?(api_key_dev, "kawa_dev_")
      assert prefix_prod == "kawa_pro"
      assert prefix_dev == "kawa_dev"
      refute api_key_prod == api_key_dev
    end

    test "generates unique API keys on each call" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod"
      }

      changeset1 = Client.create_changeset(%Client{}, attrs)
      changeset2 = Client.create_changeset(%Client{}, attrs)

      api_key1 = get_change(changeset1, :api_key)
      api_key2 = get_change(changeset2, :api_key)

      refute api_key1 == api_key2
    end

    test "sets registered_at timestamp" do
      attrs = %{
        "name" => "test-client",
        "environment" => "prod"
      }

      changeset = Client.create_changeset(%Client{}, attrs)

      registered_at = get_change(changeset, :registered_at)
      assert %DateTime{} = registered_at
      # Should be truncated to seconds
      assert registered_at.microsecond == {0, 0}
    end

    test "does not generate API key for invalid changeset" do
      attrs = %{
        # Missing required name
        "environment" => "prod"
      }

      changeset = Client.create_changeset(%Client{}, attrs)

      refute changeset.valid?
      assert get_change(changeset, :api_key) == nil
      assert get_change(changeset, :api_key_hash) == nil
      assert get_change(changeset, :api_key_prefix) == nil
    end
  end

  describe "database constraints" do
    test "enforces unique name constraint" do
      attrs = %{
        "name" => "duplicate-client",
        "environment" => "prod"
      }

      # Create first client
      {:ok, _client1} =
        %Client{}
        |> Client.create_changeset(attrs)
        |> Repo.insert()

      # Try to create second client with same name
      assert {:error, changeset} =
               %Client{}
               |> Client.create_changeset(attrs)
               |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "enforces unique api_key_hash constraint" do
      # This is more of an integration test to ensure the constraint exists
      # Since API keys should always be unique due to randomness,
      # we just verify the constraint is properly defined
      attrs = %{
        "name" => "test-client",
        "environment" => "prod"
      }

      changeset = Client.create_changeset(%Client{}, attrs)
      assert changeset.valid?

      # The unique constraint for api_key_hash should be defined in the migration
      # and the schema validation should include it
      assert Enum.any?(changeset.constraints, &(&1.constraint == "uk_clients_api_key_hash"))
    end
  end
end
