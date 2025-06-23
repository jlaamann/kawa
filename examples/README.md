# Kawa Demo Client

This directory contains a production-ready demo client that demonstrates how to integrate with the Kawa saga orchestration engine using real WebSocket communication.

## Demo Client (`demo_client.exs`) ⭐ Start Here

A complete WebSocket client that connects to a real Kawa server and demonstrates the full saga workflow lifecycle, including success scenarios and failure with compensation.

**Features:**
- ✅ Real WebSocket connection using gun library
- ✅ Client creation via Kawa REST API
- ✅ Workflow registration via WebSocket
- ✅ Live step execution handling
- ✅ Compensation processing for failed workflows
- ✅ Error scenarios and step failures
- ✅ Production-ready error handling and timeouts

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

## Demo Scenarios

The demo client runs two comprehensive scenarios:

### 🎯 Demo 1: Successful Workflow Execution
Demonstrates a complete payment processing workflow that succeeds:

1. **Validate Payment** - Validates payment details and customer information
2. **Charge Card** - Processes credit card payment via HTTP gateway
3. **Update Inventory** - Updates product stock levels in database

**Expected Output:**
```
🎯 Demo 1: Successful Workflow Execution
🚀 Triggering workflow: order_a893a080
📋 Saga created: 63ead075-914c-434a-80c2-3a03a1a30a3c
📨 Received execute_step: validate_payment
⚙️  Executing step: validate_payment
📤 Step completed: validate_payment
📨 Received execute_step: charge_card
⚙️  Executing step: charge_card
📤 Step completed: charge_card
📨 Received execute_step: update_inventory
⚙️  Executing step: update_inventory
📤 Step completed: update_inventory
🏁 Saga 63ead075... finished with status: completed
```

### ❌ Demo 2: Failed Workflow with Compensation
Demonstrates failure handling and automatic compensation:

1. **Validate Payment** ✅ - Succeeds
2. **Charge Card** ✅ - Succeeds (payment is processed)
3. **Update Inventory** ❌ - Fails with "Product out of stock" error
4. **Compensation** 🔄 - Automatically triggered in reverse order:
   - Compensate validate_payment: Clear validation cache
   - Compensate charge_card: Issue refund

**Expected Output:**
```
❌ Demo 2: Failed Workflow with Compensation
🚀 Triggering workflow (will fail): order_7278fb86
📋 Saga created: f5f9990a-8779-49b0-8bf8-9672359a5a0d
📨 Received execute_step: validate_payment
⚙️  Executing step: validate_payment
📤 Step completed: validate_payment
📨 Received execute_step: charge_card
⚙️  Executing step: charge_card
📤 Step completed: charge_card
📨 Received execute_step: update_inventory
⚙️  Executing step: update_inventory
❌ Step failed: update_inventory - Product out of stock
📤 Step failed: update_inventory
📨 Received compensate_step: validate_payment
🔄 Compensating step: validate_payment
📤 Compensation completed: validate_payment
📨 Received compensate_step: charge_card
🔄 Compensating step: charge_card
📤 Compensation completed: charge_card
🏁 Saga f5f9990a... finished with status: compensated
```

## Workflow Definition

The demo registers a payment processing workflow with these steps:

```elixir
workflow_definition = %{
  "name" => "payment_processing_#{unique_id}",
  "version" => "1.0.0",
  "description" => "Complete payment processing workflow",
  "timeout_ms" => 300_000,
  "steps" => [
    %{
      "id" => "validate_payment",
      "name" => "Validate Payment Details",
      "type" => "elixir",
      "depends_on" => [],
      "timeout_ms" => 10_000,
      "action" => %{
        "module" => "DemoSteps",
        "function" => "validate_payment"
      },
      "compensation" => %{
        "module" => "DemoSteps",
        "function" => "compensate_validation"
      }
    },
    %{
      "id" => "charge_card", 
      "name" => "Charge Credit Card",
      "type" => "http",
      "depends_on" => ["validate_payment"],
      "timeout_ms" => 30_000,
      "action" => %{
        "type" => "http_request",
        "method" => "POST",
        "url" => "https://payment-gateway.example.com/charge"
      },
      "compensation" => %{
        "type" => "http_request", 
        "method" => "POST",
        "url" => "https://payment-gateway.example.com/refund"
      }
    },
    %{
      "id" => "update_inventory",
      "name" => "Update Product Inventory",
      "type" => "elixir",
      "depends_on" => ["charge_card"],
      "timeout_ms" => 15_000,
      "action" => %{
        "module" => "DemoSteps",
        "function" => "update_inventory"
      },
      "compensation" => %{
        "module" => "DemoSteps",
        "function" => "restore_inventory"
      }
    }
  ]
}
```

## Message Protocol

The demo client demonstrates the complete Kawa step execution protocol:

### Client Registration
```json
{
  "topic": "client:client_id",
  "event": "phx_join",
  "payload": {
    "api_key": "kawa_dev_..."
  },
  "ref": "1"
}
```

### Workflow Registration
```json
{
  "topic": "client:client_id",
  "event": "register_workflow",
  "payload": {
    "name": "payment_processing",
    "version": "1.0.0",
    "steps": [...]
  },
  "ref": "2"
}
```

### Workflow Triggering
```json
{
  "topic": "client:client_id",
  "event": "trigger_workflow",
  "payload": {
    "workflow_name": "payment_processing",
    "correlation_id": "order_abc123",
    "input": {
      "amount": 99.99,
      "currency": "USD",
      "card_number": "**** **** **** 1234"
    }
  },
  "ref": "3"
}
```

### Step Execution (Server → Client)
```json
{
  "event": "execute_step",
  "payload": {
    "saga_id": "uuid",
    "step_id": "validate_payment",
    "input": {...},
    "timeout_ms": 10000
  }
}
```

### Step Completed (Client → Server)
```json
{
  "topic": "client:client_id",
  "event": "step_completed",
  "payload": {
    "saga_id": "uuid",
    "step_id": "validate_payment",
    "result": {
      "validation_passed": true,
      "order_total": 99.99
    }
  },
  "ref": "4"
}
```

### Step Failed (Client → Server)
```json
{
  "topic": "client:client_id",
  "event": "step_failed",
  "payload": {
    "saga_id": "uuid",
    "step_id": "update_inventory",
    "error": {
      "type": "inventory_error",
      "message": "Product out of stock",
      "code": "OUT_OF_STOCK",
      "retryable": false
    }
  },
  "ref": "5"
}
```

### Compensation Request (Server → Client)
```json
{
  "event": "compensate_step",
  "payload": {
    "saga_id": "uuid",
    "step_id": "charge_card",
    "original_result": {...},
    "compensation_data": {...}
  }
}
```

### Compensation Completed (Client → Server)
```json
{
  "topic": "client:client_id",
  "event": "compensation_completed",
  "payload": {
    "saga_id": "uuid",
    "step_id": "charge_card",
    "result": {
      "refund_id": "ref_12345",
      "refund_amount": 199.99,
      "refund_status": "completed"
    }
  },
  "ref": "6"
}
```

## Integration Patterns

### Step Handler Implementation
```elixir
defp handle_step_execution(state, saga_id, step_id, step_data, scenario) do
  Logger.info("⚙️  Executing step: #{step_id}")
  
  # Simulate processing time
  Process.sleep(100 + :rand.uniform(400))
  
  case step_id do
    "validate_payment" ->
      result = %{
        "validation_passed" => true,
        "order_total" => 99.99
      }
      send_step_completed(state, saga_id, step_id, result)
      
    "charge_card" ->
      result = %{
        "transaction_id" => "txn_abc123",
        "amount_charged" => 99.99
      }
      send_step_completed(state, saga_id, step_id, result)
      
    _ ->
      send_step_completed(state, saga_id, step_id, %{})
  end
end
```

### Error Handling
```elixir
defp execute_failed_step(state, saga_id, step_id) do
  error = %{
    "type" => "inventory_error",
    "message" => "Product out of stock",
    "code" => "OUT_OF_STOCK",
    "retryable" => false
  }
  
  send_step_failed(state, saga_id, step_id, error)
end
```

### Compensation Handling
```elixir
defp handle_compensation(state, saga_id, step_id, _compensation_data) do
  Logger.info("🔄 Compensating step: #{step_id}")
  
  result = case step_id do
    "charge_card" ->
      %{
        "refund_id" => "REF_#{generate_id()}",
        "refund_amount" => 199.99,
        "refund_status" => "completed"
      }
    _ ->
      %{
        "compensated" => true,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
  end
  
  send_compensation_completed(state, saga_id, step_id, result)
end
```

## Technical Implementation

### WebSocket Client
- Uses **gun** HTTP/WebSocket client library (reliable and production-ready)
- Implements proper Phoenix channel protocol
- Handles connection upgrades, timeouts, and error recovery
- Manages message references and acknowledgments

### Dependencies
- `gun ~> 2.0` - HTTP/WebSocket client
- `httpoison ~> 2.0` - HTTP client for API calls
- `jason ~> 1.2` - JSON encoding/decoding

### Key Features
- **Production-ready**: Uses reliable gun library instead of problematic websocket_client
- **Real communication**: No simulation - actual WebSocket messages
- **Complete protocol**: Implements full Phoenix channel message protocol
- **Error handling**: Comprehensive timeout and error handling
- **Compensation**: Demonstrates automatic rollback on failures
- **Realistic timing**: Includes processing delays and timeouts

## Next Steps

1. **Review the demo output** to understand the message flow
2. **Implement your own step handlers** using the patterns shown
3. **Add your business logic** to the step execution functions
4. **Test error scenarios** by modifying the failure conditions
5. **Add monitoring and logging** for production use
6. **Implement step result caching** for reliability
7. **Add health checks** and connection recovery logic

The demo client provides a complete, working example of how to integrate with Kawa's saga orchestration engine. Use it as a template for building your own clients that can participate in distributed saga workflows with automatic compensation!