defmodule KawaWeb.ClientController do
  use KawaWeb, :controller

  alias Kawa.{Repo}
  alias Kawa.Schemas.Client

  @doc """
  Creates a new client with generated API key.

  Expects JSON payload:
  {
    "name": "ecommerce-app",
    "environment": "prod",
    "description": "Main ecommerce service"  // optional, stored in metadata
  }

  Returns:
  {
    "client": {
      "id": "uuid",
      "name": "ecommerce-app",
      "environment": "prod",
      "api_key_prefix": "kawa_pro",
      "registered_at": "2024-01-01T00:00:00Z"
    },
    "api_key": "kawa_prod_abc123..."
  }
  """
  def create(conn, params) do
    # Extract description and put it in metadata
    metadata =
      case Map.get(params, "description") do
        nil -> %{}
        description -> %{"description" => description}
      end

    client_params =
      params
      |> Map.take(["name", "environment"])
      |> Map.put("connection_metadata", metadata)

    case create_client(client_params) do
      {:ok, client} ->
        conn
        |> put_status(:created)
        |> json(%{
          client: %{
            id: client.id,
            name: client.name,
            environment: client.environment,
            api_key_prefix: client.api_key_prefix,
            registered_at: client.registered_at,
            metadata: client.connection_metadata
          },
          api_key: client.api_key
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Validation failed",
          details: format_changeset_errors(changeset)
        })
    end
  end

  @doc """
  Lists all clients (without API keys for security).
  """
  def index(conn, _params) do
    clients =
      Repo.all(Client)
      |> Enum.map(fn client ->
        %{
          id: client.id,
          name: client.name,
          environment: client.environment,
          status: client.status,
          api_key_prefix: client.api_key_prefix,
          registered_at: client.registered_at,
          last_heartbeat_at: client.last_heartbeat_at
        }
      end)

    json(conn, %{clients: clients})
  end

  @doc """
  Shows a specific client (without API key for security).
  """
  def show(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Client, uuid) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Client not found"})

          client ->
            json(conn, %{
              client: %{
                id: client.id,
                name: client.name,
                environment: client.environment,
                status: client.status,
                api_key_prefix: client.api_key_prefix,
                registered_at: client.registered_at,
                last_heartbeat_at: client.last_heartbeat_at,
                connection_metadata: client.connection_metadata,
                capabilities: client.capabilities,
                last_metrics: client.last_metrics
              }
            })
        end

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Client not found"})
    end
  end

  defp create_client(params) do
    %Client{}
    |> Client.create_changeset(params)
    |> Repo.insert()
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
