# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kawa is a distributed saga orchestration engine built in Elixir. This project implements the Saga pattern for managing distributed transactions across microservices.

## Development Setup

This project uses Phoenix with LiveView and Ecto, with PostgreSQL running in Docker.

### Database Setup (Docker)
- `docker-compose up -d` - Start PostgreSQL containers (dev + test)
- `docker-compose down` - Stop PostgreSQL containers
- `docker-compose logs db` - View database logs

### Phoenix Development Commands
- `mix setup` - Install dependencies and setup database
- `mix deps.get` - Install dependencies only
- `mix ecto.create` - Create the database
- `mix ecto.migrate` - Run database migrations
- `mix phx.server` - Start Phoenix server (http://localhost:4000)
- `iex -S mix phx.server` - Start server in interactive mode
- `mix test` - Run tests
- `mix format` - Format code
- `mix compile` - Compile the project

**First-time setup:**
1. `docker-compose up -d` - Start databases
2. `mix setup` - Install deps and setup database
3. `mix phx.server` - Start server

### Continuous Integration
- GitHub Actions automatically run tests on push/PR to main branch
- Includes: formatting checks, compilation, tests, dependency checks
- Uses PostgreSQL service for database tests

## Architecture

As a saga orchestration engine, this project will implement:

- **Saga Coordinator**: Central orchestrator that manages saga execution
- **Saga Definition**: DSL or configuration for defining saga workflows
- **Step Handlers**: Individual transaction steps that can be compensated
- **Event Store**: Persistence layer for saga state and events
- **Compensation Logic**: Rollback mechanisms for failed transactions

The distributed nature suggests it will include:
- Inter-service communication mechanisms
- State persistence and recovery
- Error handling and retry logic
- Monitoring and observability features

### Client-server communication
Clients will communicate with the orchestrator over WebSockets.

### Database schema
Database schema is defined in a UML file located in docs/schema.uml.

## Repository structure
TODO

## Key Concepts

- **Saga Pattern**: Long-running business transactions split into steps
- **Compensation**: Rollback actions when saga steps fail
- **Orchestration**: Centralized coordination of distributed transactions
- **Event Sourcing**: Likely used for maintaining saga state history

## Saga format (YAML)

```yaml
name: "ecommerce-order"
description: "Complete order processing with inventory and payment"
timeout: "5m"

steps:
  - id: "reserve_inventory"
    type: "http"
    action:
      method: "POST"
      url: "http://inventory-service/reserve"
      body: 
        product_id: "{{ saga.input.product_id }}"
        quantity: "{{ saga.input.quantity }}"
    compensation:
      method: "POST" 
      url: "http://inventory-service/release"
      body:
        reservation_id: "{{ steps.reserve_inventory.response.reservation_id }}"
    timeout: "30s"
    
  - id: "charge_payment"
    type: "http"
    depends_on: ["reserve_inventory"]
    action:
      method: "POST"
      url: "http://payment-service/charge"
      body:
        amount: "{{ saga.input.amount }}"
        payment_method: "{{ saga.input.payment_method }}"
    compensation:
      method: "POST"
      url: "http://payment-service/refund" 
      body:
        charge_id: "{{ steps.charge_payment.response.charge_id }}"
    timeout: "45s"

  - id: "send_confirmation"
    type: "elixir"
    depends_on: ["charge_payment"]
    action:
      module: "OrderService"
      function: "send_confirmation_email"
      args: ["{{ saga.input.user_email }}", "{{ saga.input.order_id }}"]
    # No compensation needed for email
    timeout: "10s"
```

## Application flows

**Defining workflow in client:**
```elixir
# In client app's lib/workflows/order_workflow.ex
defmodule EcommerceApp.Workflows.OrderWorkflow do
  use Kawa.Workflow
  
  def run(order_data) do
    workflow "ecommerce-order" do
      step :reserve_inventory do
        action fn -> InventoryService.reserve(order_data.product_id) end
        compensation fn ctx -> InventoryService.release(ctx.reservation_id) end
        timeout "30s"
      end
      
      step :charge_payment, depends_on: [:reserve_inventory] do
        action fn ctx -> 
          PaymentService.charge(order_data.amount, order_data.payment_method)
        end
        compensation fn ctx -> PaymentService.refund(ctx.charge_id) end
        timeout "45s"
      end
      
      step :send_confirmation, depends_on: [:charge_payment] do
        action fn ctx -> 
          EmailService.send_confirmation(order_data.email, ctx.order_id)
        end
        # No compensation needed
      end
    end
  end
end
```

**Starting workflow from client:**
```elixir
# In client application
{:ok, saga_id} = Kawa.Client.start_workflow(
  EcommerceApp.Workflows.OrderWorkflow,
  %{product_id: "123", amount: 99.99, email: "user@example.com"}
)

# Monitor progress
Kawa.Client.get_status(saga_id)
```

**1. Client registers workflow on startup**
```elixir
# In client app's application.ex
def start(_type, _args) do
  # Connect to Kawa server
  Kawa.Client.connect("http://kawa-server:4000")
  
  # Register workflows
  Kawa.Client.register_workflow(EcommerceApp.Workflows.OrderWorkflow)
  
  # ... rest of supervision tree
end
```

**2. Kawa server receives workflow definition**
```elixir
# Kawa stores the workflow code/definition
%WorkflowDefinition{
  name: "ecommerce-order",
  module: "EcommerceApp.Workflows.OrderWorkflow", 
  client_id: "ecommerce-app-1",
  steps: [%{id: :reserve_inventory, ...}, ...]
}
```

**3. When workflow executes, Kawa calls back to client:**
```
# Kawa -> Client: "Execute step :reserve_inventory"
# Client -> Kawa: "Step completed with result: %{reservation_id: 'abc'}"
# Kawa -> Client: "Execute step :charge_payment"
```

**WebSocket Connection Pattern:**

```elixir
# Client side
defmodule MyApp.KawaClient do
  use GenServer
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  def init(_) do
    {:ok, socket} = connect_to_kawa()
    {:ok, %{socket: socket, workflows: %{}}}
  end
  
  # Handle step execution requests from Kawa
  def handle_info({:execute_step, saga_id, step_id, input}, state) do
    result = execute_workflow_step(step_id, input)
    Phoenix.Channel.push(state.socket, "step_result", %{
      saga_id: saga_id,
      step_id: step_id, 
      result: result
    })
    {:noreply, state}
  end
end
```

**Connection Management:**

```elixir
# Kawa server tracks client connections
defmodule Kawa.ClientRegistry do
  # When client connects
  def client_connected(client_id, socket_pid) do
    # Resume paused sagas for this client
    Kawa.SagaManager.resume_client_sagas(client_id)
  end
  
  # When client disconnects  
  def client_disconnected(client_id) do
    # Pause running sagas for this client
    Kawa.SagaManager.pause_client_sagas(client_id)
  end
end
```