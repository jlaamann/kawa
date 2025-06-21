# WebSocket Client Connection Example

This document shows how clients can connect to Kawa using WebSockets with API key authentication.

## Connection Flow

1. **Get API Key**: First, create a client and get an API key via the REST API
2. **Connect to WebSocket**: Use the API key to authenticate the WebSocket connection
3. **Join Client Channel**: Join the client-specific channel for communication

## Step 1: Create Client and Get API Key

```bash
curl -X POST http://localhost:4000/api/clients \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-service",
    "environment": "dev",
    "description": "My microservice"
  }'
```

Response:
```json
{
  "client": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "name": "my-service",
    "environment": "dev",
    "api_key_prefix": "kawa_dev",
    "registered_at": "2024-01-01T00:00:00Z"
  },
  "api_key": "kawa_dev_abc123def456ghi789jkl012mno345pqr678"
}
```

## Step 2: Connect via WebSocket

### Using JavaScript

```javascript
import {Socket} from "phoenix"

// Create socket connection
const socket = new Socket("ws://localhost:4000/socket")
socket.connect()

// Join the client channel with API key authentication
const clientId = "550e8400-e29b-41d4-a716-446655440000"
const apiKey = "kawa_dev_abc123def456ghi789jkl012mno345pqr678"

const channel = socket.channel(`client:${clientId}`, {
  api_key: apiKey
})

channel.join()
  .receive("ok", (response) => {
    console.log("Connected successfully:", response)
    // Response: {client_id: "550e8400...", status: "connected"}
  })
  .receive("error", (response) => {
    console.log("Connection failed:", response)
    // Response: {reason: "authentication_failed"} or {reason: "api_key_required"}
  })
```

### Using Elixir Phoenix Channels Client

```elixir
# In your client application
defmodule MyApp.KawaClient do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    api_key = Keyword.fetch!(opts, :api_key)
    
    # Connect to WebSocket
    {:ok, socket} = PhoenixClient.Socket.start_link([
      url: "ws://localhost:4000/socket/websocket"
    ])
    
    # Join client channel
    {:ok, channel} = PhoenixClient.Channel.join(socket, "client:#{client_id}", %{
      "api_key" => api_key
    })
    
    Logger.info("Connected to Kawa WebSocket")
    
    {:ok, %{socket: socket, channel: channel, client_id: client_id}}
  end

  # Handle incoming messages from Kawa
  def handle_info({:phoenix_channel_event, "execute_step", payload}, state) do
    # Handle step execution request from Kawa
    Logger.info("Received step execution request: #{inspect(payload)}")
    {:noreply, state}
  end
end
```

## Step 3: Communication Patterns

### Heartbeat
Send periodic heartbeats to maintain connection:

```javascript
// Send heartbeat every 30 seconds
setInterval(() => {
  channel.push("heartbeat", {})
    .receive("ok", (response) => {
      console.log("Heartbeat acknowledged:", response.timestamp)
    })
}, 30000)
```

### Register Workflow
Register a workflow definition with Kawa:

```javascript
const workflowDef = {
  name: "order-processing",
  steps: [
    {
      id: "reserve_inventory",
      type: "http",
      action: {
        method: "POST",
        url: "http://inventory-service/reserve"
      }
    }
  ]
}

channel.push("register_workflow", {workflow: workflowDef})
  .receive("ok", (response) => {
    console.log("Workflow registered:", response)
  })
```

### Report Step Results
When Kawa requests step execution, report the result:

```javascript
// Kawa will send step execution requests via WebSocket
// Client should respond with step results

channel.push("step_result", {
  saga_id: "saga-123",
  step_id: "reserve_inventory", 
  result: {
    success: true,
    reservation_id: "res-456"
  }
})
.receive("ok", (response) => {
  console.log("Result acknowledged:", response)
})
```

## Authentication Notes

- API keys are validated on channel join
- Invalid API keys will result in connection rejection
- API keys must be included in the join payload as `api_key`
- Client connections are tracked in the ClientRegistry for saga coordination
- Client status is automatically updated to "connected"/"disconnected" based on WebSocket state