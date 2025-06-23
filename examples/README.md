# Kawa Demo Clients

This directory contains example clients that demonstrate how to integrate with the Kawa saga orchestration engine.

## Demo Clients

### 1. Demo Client (`demo_client.exs`) ⭐ Start Here

A production-ready client that connects to a real Kawa server and demonstrates the complete saga workflow lifecycle. **Perfect for understanding Kawa concepts with real interactions!**

**Features:**
- Real WebSocket connection to Kawa server
- Client creation via Kawa REST API
- Workflow registration via WebSocket
- Live step execution handling
- Compensation processing
- Error scenarios and timeouts

**Prerequisites:**
- Kawa server running on `localhost:4000`
- Database migrated and available

**Usage:**
```bash
# Terminal 1: Start Kawa server
mix phx.server

# Terminal 2: Run demo client
mix run examples/demo_client.exs
```

**Sample Output:**
```
🚀 Starting Kawa Real WebSocket Demo Client
📝 Creating client via Kawa API...
✅ Client created: demo-client-5476
📋 Created client: f8e2a3c4-1d5e-4f7a-8b9c-0123456789ab
🔌 Connecting to Kawa at ws://localhost:4000/socket/websocket?vsn=2.0.0
✅ Successfully joined client channel
📦 Registering payment workflow...
📤 Sending workflow registration...
✅ Workflow registered successfully

🎯 Demo 1: Successful Workflow Execution
🚀 Triggering workflow: order_4b636679
📋 Saga created: e19bac40-8a4b-4a40-be24-ab3496249564
📨 Received execute_step: validate_payment
⚙️  Executing step: validate_payment
📤 Step completed: validate_payment
📨 Received execute_step: charge_card
⚙️  Executing step: charge_card
📤 Step completed: charge_card
📊 Saga e19bac40... status: completed

❌ Demo 2: Failed Workflow with Compensation
🚀 Triggering workflow (will fail): order_906e918e
📨 Received execute_step: update_inventory
❌ Step failed: update_inventory - Product out of stock
📨 Received compensate_step: charge_card
🔄 Compensating step: charge_card
📤 Compensation completed: charge_card
📊 Saga acf1634c... status: compensated
```

**What it demonstrates:**
- ✅ Successful workflow execution
- ❌ Failed workflow with compensation
- ⏰ Timeout scenarios

### 2. WebSocket Client (`websocket_client.exs`)

An advanced WebSocket client that demonstrates additional patterns and more complex e-commerce scenarios.

**Features:**
- Advanced WebSocket patterns
- E-commerce order processing workflow (5 steps)
- Realistic step processing with random delays
- Production-ready error handling
- Heartbeat and connection management

**Prerequisites:**
- Kawa server running on `localhost:4000`

**Usage:**
```bash
# Start Kawa server first
mix phx.server

# In another terminal, run the advanced client
mix run examples/websocket_client.exs
```

**What it demonstrates:**
- 🛒 E-commerce order processing
- 🔄 Advanced compensation patterns
- 💳 Payment processing simulation
- 📦 Inventory management integration
- 🚚 Shipping and fulfillment workflows

## Example Workflows

Both clients demonstrate an e-commerce order processing workflow with these steps:

1. **Validate Order** - Validates order details, payment, and shipping
2. **Process Payment** - Charges the customer's payment method
3. **Update Inventory** - Decrements product stock levels
4. **Create Shipment** - Creates shipping label and tracking
5. **Send Confirmation** - Sends order confirmation email

## Message Protocol

The clients demonstrate the Kawa step execution protocol:

### Step Execution Messages

**Execute Step Request (Server → Client):**
```json
{
  "type": "execute_step",
  "saga_id": "uuid",
  "step_id": "validate_order",
  "input": {...},
  "timeout_ms": 30000
}
```

**Step Completed Response (Client → Server):**
```json
{
  "saga_id": "uuid",
  "step_id": "validate_order", 
  "result": {
    "validation_passed": true,
    "order_total": 139.97
  }
}
```

**Step Failed Response (Client → Server):**
```json
{
  "saga_id": "uuid",
  "step_id": "validate_order",
  "error": {
    "type": "validation_error",
    "message": "Invalid address",
    "code": "INVALID_ADDRESS",
    "retryable": false
  }
}
```

### Compensation Messages

**Compensate Step Request (Server → Client):**
```json
{
  "type": "compensate_step",
  "saga_id": "uuid",
  "step_id": "process_payment",
  "original_result": {...},
  "compensation_data": {...}
}
```

**Compensation Completed Response (Client → Server):**
```json
{
  "saga_id": "uuid",
  "step_id": "process_payment",
  "result": {
    "refund_id": "ref_12345",
    "refund_amount": 139.97
  }
}
```

## Integration Patterns

### 1. Simple Step Handler
```elixir
def handle_step_execution(step_id, input) do
  case step_id do
    "validate_order" ->
      # Validation logic
      {:ok, %{validation_passed: true}}
    "process_payment" ->
      # Payment processing
      {:ok, %{transaction_id: "txn_123"}}
    _ ->
      {:error, %{type: "unknown_step"}}
  end
end
```

### 2. Async Step Processing
```elixir
def handle_async_step(step_id, input, callback) do
  Task.start(fn ->
    result = process_step(step_id, input)
    callback.(result)
  end)
end
```

### 3. Error Handling
```elixir
def handle_step_with_retry(step_id, input, max_retries \\ 3) do
  case execute_step(step_id, input) do
    {:ok, result} -> 
      {:ok, result}
    {:error, error} when error.retryable and max_retries > 0 ->
      Process.sleep(1000)
      handle_step_with_retry(step_id, input, max_retries - 1)
    {:error, error} ->
      {:error, error}
  end
end
```

## Testing Your Integration

1. **Start with the demo client** to understand the message flow
2. **Use the WebSocket client** to test real connections
3. **Implement step handlers** for your business logic
4. **Add error handling** and compensation logic
5. **Test timeout scenarios** and recovery

## Configuration

### Client Configuration
```elixir
config = %{
  server_url: "ws://localhost:4000/socket/websocket",
  client_id: "your-client-id",
  api_key: "your-api-key",
  heartbeat_interval: 30_000,
  step_timeout: 60_000
}
```

### Workflow Definition
```elixir
workflow = %{
  "name" => "your_workflow",
  "version" => "1.0.0", 
  "steps" => [
    %{
      "id" => "step1",
      "depends_on" => [],
      "timeout_ms" => 30_000,
      "action" => %{...},
      "compensation" => %{...}
    }
  ]
}
```

## Next Steps

- Review the [Kawa documentation](../CLAUDE.md) for complete API reference
- Implement your own step handlers using these examples as templates
- Add monitoring and logging for production use
- Consider implementing step result caching for reliability
- Add health checks and connection recovery logic