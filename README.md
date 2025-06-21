# kawa
A distributed saga orchestration engine in Elixir

## Vision
- **Developer Experience First**: (offer language specific SDKs)
- **Extreme Concurrency**
	- Make use of Elixir and handle 1M+ concurrent sagas on commodity hardware
    - Horizontal scaling via clustering
- **Smart Observability**: Real-time dashboards; start, restart and stop workflows from the UI

## Development
To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## API Documentation

### Clients API

The Clients API allows you to manage client registrations for the saga orchestration engine.

#### Create a Client

Creates a new client with an API key for authentication.

```bash
curl -X POST http://localhost:4000/api/clients \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ecommerce-app",
    "environment": "prod",
    "description": "Main ecommerce service"
  }'
```

**Response:**
```json
{
  "client": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "name": "ecommerce-app",
    "environment": "prod",
    "api_key_prefix": "kawa_pro",
    "registered_at": "2024-01-01T00:00:00Z",
    "metadata": {
      "description": "Main ecommerce service"
    }
  },
  "api_key": "kawa_prod_x1y2z3a4b5c6d7e8f9g0h1i2j3k4l5m6"
}
```

#### List All Clients

Returns a list of all registered clients (without API keys for security).

```bash
curl http://localhost:4000/api/clients
```

**Response:**
```json
{
  "clients": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "ecommerce-app",
      "environment": "prod",
      "status": "disconnected",
      "api_key_prefix": "kawa_pro",
      "registered_at": "2024-01-01T00:00:00Z",
      "last_heartbeat_at": null
    }
  ]
}
```

#### Get Client Details

Returns detailed information about a specific client.

```bash
curl http://localhost:4000/api/clients/550e8400-e29b-41d4-a716-446655440000
```

**Response:**
```json
{
  "client": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "name": "ecommerce-app",
    "environment": "prod",
    "status": "disconnected",
    "api_key_prefix": "kawa_pro",
    "registered_at": "2024-01-01T00:00:00Z",
    "last_heartbeat_at": null,
    "connection_metadata": {
      "description": "Main ecommerce service"
    },
    "capabilities": {},
    "last_metrics": {}
  }
}
```

#### Environment Values

- `dev` - Development environment
- `staging` - Staging environment  
- `prod` - Production environment

#### API Key Format

Generated API keys follow the format: `kawa_{environment}_{32_char_random_string}`

- Production: `kawa_prod_...` (prefix: `kawa_pro`)
- Staging: `kawa_staging_...` (prefix: `kawa_sta`)
- Development: `kawa_dev_...` (prefix: `kawa_dev`)

### Database schema
[Mermaid](https://www.mermaidchart.com/app/projects/a8e091df-2e34-4719-9903-3e68da60a741/diagrams/cd90e4b6-770a-4ba6-8bc4-27c54ce70e91/version/v0.1/edit)