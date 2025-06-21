defmodule KawaWeb.ClientControllerTest do
  use KawaWeb.ConnCase, async: true

  alias Kawa.{Repo}
  alias Kawa.Schemas.Client

  describe "POST /api/clients" do
    test "creates client with valid data", %{conn: conn} do
      client_params = %{
        "name" => "ecommerce-app",
        "environment" => "prod",
        "description" => "Main ecommerce service"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "client" => %{
                 "id" => id,
                 "name" => "ecommerce-app",
                 "environment" => "prod",
                 "api_key_prefix" => "kawa_pro",
                 "metadata" => %{"description" => "Main ecommerce service"}
               },
               "api_key" => api_key
             } = json_response(conn, 201)

      # Verify UUID format
      assert {:ok, _} = Ecto.UUID.cast(id)

      # Verify API key format
      assert String.starts_with?(api_key, "kawa_prod_")
      assert String.length(api_key) > 20

      # Verify database record was created
      client = Repo.get!(Client, id)
      assert client.name == "ecommerce-app"
      assert client.environment == "prod"
      assert client.status == "disconnected"
      assert client.api_key_prefix == "kawa_pro"
      assert client.connection_metadata == %{"description" => "Main ecommerce service"}
      assert is_binary(client.api_key_hash)
      refute is_nil(client.registered_at)
    end

    test "creates client without description", %{conn: conn} do
      client_params = %{
        "name" => "test-service",
        "environment" => "dev"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "client" => %{
                 "name" => "test-service",
                 "environment" => "dev",
                 "api_key_prefix" => "kawa_dev",
                 "metadata" => %{}
               },
               "api_key" => api_key
             } = json_response(conn, 201)

      assert String.starts_with?(api_key, "kawa_dev_")
    end

    test "creates client with staging environment", %{conn: conn} do
      client_params = %{
        "name" => "staging-service",
        "environment" => "staging"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "api_key" => api_key
             } = json_response(conn, 201)

      assert String.starts_with?(api_key, "kawa_staging_")
    end

    test "returns validation error for missing name", %{conn: conn} do
      client_params = %{
        "environment" => "prod"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "error" => "Validation failed",
               "details" => %{"name" => ["can't be blank"]}
             } = json_response(conn, 422)
    end

    test "returns validation error for missing environment", %{conn: conn} do
      client_params = %{
        "name" => "test-app"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "error" => "Validation failed",
               "details" => %{"environment" => ["can't be blank"]}
             } = json_response(conn, 422)
    end

    test "returns validation error for invalid environment", %{conn: conn} do
      client_params = %{
        "name" => "test-app",
        "environment" => "invalid"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "error" => "Validation failed",
               "details" => %{"environment" => ["is invalid"]}
             } = json_response(conn, 422)
    end

    test "returns validation error for duplicate name", %{conn: conn} do
      # Create first client
      client_params = %{
        "name" => "duplicate-app",
        "environment" => "prod"
      }

      post(conn, ~p"/api/clients", client_params)

      # Try to create second client with same name
      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "error" => "Validation failed",
               "details" => %{"name" => ["has already been taken"]}
             } = json_response(conn, 422)
    end

    test "returns validation error for empty name", %{conn: conn} do
      client_params = %{
        "name" => "",
        "environment" => "prod"
      }

      conn = post(conn, ~p"/api/clients", client_params)

      assert %{
               "error" => "Validation failed",
               "details" => details
             } = json_response(conn, 422)

      # Should have validation error for empty name
      assert Map.has_key?(details, "name")
    end
  end

  describe "GET /api/clients" do
    test "returns empty list when no clients exist", %{conn: conn} do
      conn = get(conn, ~p"/api/clients")

      assert %{"clients" => []} = json_response(conn, 200)
    end

    test "returns list of clients without API keys", %{conn: conn} do
      # Create test clients
      {:ok, _client1} =
        %Client{}
        |> Client.create_changeset(%{
          "name" => "app1",
          "environment" => "prod"
        })
        |> Repo.insert()

      {:ok, _client2} =
        %Client{}
        |> Client.create_changeset(%{
          "name" => "app2",
          "environment" => "dev"
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/clients")

      assert %{"clients" => clients} = json_response(conn, 200)
      assert length(clients) == 2

      # Verify client data and that API keys are not included
      client_names = Enum.map(clients, & &1["name"]) |> Enum.sort()
      assert client_names == ["app1", "app2"]

      for client <- clients do
        assert Map.has_key?(client, "id")
        assert Map.has_key?(client, "name")
        assert Map.has_key?(client, "environment")
        assert Map.has_key?(client, "status")
        assert Map.has_key?(client, "api_key_prefix")
        assert Map.has_key?(client, "registered_at")
        refute Map.has_key?(client, "api_key")
        refute Map.has_key?(client, "api_key_hash")
      end
    end
  end

  describe "GET /api/clients/:id" do
    setup do
      {:ok, client} =
        %Client{}
        |> Client.create_changeset(%{
          "name" => "test-client",
          "environment" => "staging",
          "connection_metadata" => %{"description" => "Test client"}
        })
        |> Repo.insert()

      %{client: client}
    end

    test "returns client details without API key", %{conn: conn, client: client} do
      conn = get(conn, ~p"/api/clients/#{client.id}")

      assert %{
               "client" => %{
                 "id" => id,
                 "name" => "test-client",
                 "environment" => "staging",
                 "status" => "disconnected",
                 "api_key_prefix" => "kawa_sta",
                 "connection_metadata" => %{"description" => "Test client"},
                 "capabilities" => %{},
                 "last_metrics" => %{}
               }
             } = json_response(conn, 200)

      assert id == client.id
      refute Map.has_key?(json_response(conn, 200)["client"], "api_key")
      refute Map.has_key?(json_response(conn, 200)["client"], "api_key_hash")
    end

    test "returns 404 for non-existent client", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/api/clients/#{fake_id}")

      assert %{"error" => "Client not found"} = json_response(conn, 404)
    end

    test "returns 404 for invalid UUID", %{conn: conn} do
      conn = get(conn, ~p"/api/clients/invalid-uuid")

      assert %{"error" => "Client not found"} = json_response(conn, 404)
    end
  end
end
