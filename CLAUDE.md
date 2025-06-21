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

### Git Hooks (Optional)
To enable automatic code formatting on commit:
```bash
cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

This hook will:
- Run `mix format` on staged Elixir files before commit
- Prevent commits if formatting changes are needed
- Ensure consistent code formatting across the team

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

### Client-server communication
Clients will communicate with the orchestrator over WebSockets.

### Database schema
Database schema is defined in a UML file located in docs/schema.uml.

## Key Concepts

- **Saga Pattern**: Long-running business transactions split into steps
- **Compensation**: Rollback actions when saga steps fail
- **Orchestration**: Centralized coordination of distributed transactions
- **Event Sourcing**: Used for maintaining saga state history

## Application flows
### Defining and starting workflows
**Defining workflow in client (SDK approach):**
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

**When workflow executes, Kawa calls back to client:**
```
# Kawa -> Client: "Execute step :reserve_inventory"
# Client -> Kawa: "Step completed with result: %{reservation_id: 'abc'}"
# Kawa -> Client: "Execute step :charge_payment"
```

### Registering workflows
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

### WebSocket Connection Pattern

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

## Server State Recovery

Kawa ensures distributed saga transactions survive server failures and resume execution seamlessly through event sourcing and persistent state management.

**Key Benefits:**
- Zero transaction loss across server restarts
- Automatic saga resumption without manual intervention  
- Client reconnection with state synchronization
- Complete compensation integrity for failed transactions

### Recovery Architecture

#### Event Sourcing
Every saga operation generates immutable events stored in PostgreSQL:
- `saga_started`, `step_completed`, `step_failed`, `compensation_started`, etc.
- Sequential numbering ensures correct replay order
- Complete state snapshots enable precise reconstruction

#### Persistent State
Critical data maintained across restarts:
- **Sagas**: Current status and metadata
- **Steps**: Individual execution state  
- **Events**: Complete operation history
- **Clients**: Connection and workflow information

### Recovery Process

#### Server Startup
1. **Identify** active sagas (`running`, `paused`, `compensating`)
2. **Reconstruct** state by replaying event history
3. **Resume** execution from last known checkpoint

#### Client Reconnection
When clients reconnect:
- Kawa detects previous connections automatically
- Retrieves associated saga states
- Continues execution from interruption point
- Retransmits any pending step requests

#### Compensation Recovery
For failed transactions requiring rollback:
- Identifies last successful step
- Executes compensation in reverse order
- Tracks rollback progress via events

### Guarantees

✅ **Exactly-once execution** - Steps never duplicate despite retries  
✅ **Progress preservation** - No loss of completed work  
✅ **Compensation integrity** - Failed transactions properly rolled back  
✅ **Event ordering** - Sequential replay maintains consistency  