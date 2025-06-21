# WorkflowRegistry Usage Guide

The `Kawa.WorkflowRegistry` is a GenServer that manages workflow definitions with versioning, metadata tracking, and usage statistics. This guide shows you how to use it effectively.

## Overview

The WorkflowRegistry provides:
- Workflow registration with automatic versioning
- Active version management
- Usage tracking and statistics
- Metadata storage
- Comprehensive validation using WorkflowValidator

## Basic Usage

### Starting the Registry

```elixir
# Start the registry (usually done in your application supervision tree)
{:ok, pid} = Kawa.WorkflowRegistry.start_link()

# Or with a custom name
{:ok, pid} = Kawa.WorkflowRegistry.start_link(name: MyApp.WorkflowRegistry)
```

### Registering a Workflow

```elixir
# Define a workflow
workflow_definition = %{
  "name" => "ecommerce-order",
  "description" => "Complete order processing with inventory and payment",
  "timeout" => "5m",
  "steps" => [
    %{
      "id" => "reserve_inventory",
      "type" => "http",
      "action" => %{
        "method" => "POST",
        "url" => "http://inventory-service/reserve",
        "body" => %{
          "product_id" => "{{ saga.input.product_id }}",
          "quantity" => "{{ saga.input.quantity }}"
        }
      },
      "compensation" => %{
        "method" => "POST", 
        "url" => "http://inventory-service/release",
        "body" => %{
          "reservation_id" => "{{ steps.reserve_inventory.response.reservation_id }}"
        }
      },
      "timeout" => "30s"
    },
    %{
      "id" => "charge_payment",
      "type" => "http",
      "depends_on" => ["reserve_inventory"],
      "action" => %{
        "method" => "POST",
        "url" => "http://payment-service/charge",
        "body" => %{
          "amount" => "{{ saga.input.amount }}",
          "payment_method" => "{{ saga.input.payment_method }}"
        }
      },
      "compensation" => %{
        "method" => "POST",
        "url" => "http://payment-service/refund",
        "body" => %{
          "charge_id" => "{{ steps.charge_payment.response.charge_id }}"
        }
      },
      "timeout" => "45s"
    }
  ]
}

# Register the workflow
definition_params = %{
  definition: workflow_definition,
  client_id: "ecommerce-app-1",
  metadata: %{
    "created_by" => "john.doe@company.com",
    "environment" => "production",
    "tags" => ["ecommerce", "critical"]
  }
}

{:ok, version} = Kawa.WorkflowRegistry.register_workflow("ecommerce-order", definition_params)
# Returns: {:ok, 1}
```

### Retrieving Workflows

```elixir
# Get the active version of a workflow
{:ok, workflow} = Kawa.WorkflowRegistry.get_workflow("ecommerce-order")

# Get a specific version
{:ok, workflow_v1} = Kawa.WorkflowRegistry.get_workflow("ecommerce-order", 1)

# List all active workflows
active_workflows = Kawa.WorkflowRegistry.list_workflows()

# List all versions of a specific workflow
{:ok, all_versions} = Kawa.WorkflowRegistry.list_workflow_versions("ecommerce-order")
```

## Workflow Versioning

### Creating New Versions

When you register a workflow with the same name, it creates a new version:

```elixir
# First registration - version 1
{:ok, 1} = Kawa.WorkflowRegistry.register_workflow("my-workflow", definition_params)

# Second registration - version 2 (automatically becomes active)
updated_definition = %{
  definition: updated_workflow_definition,
  client_id: "ecommerce-app-1"
}

{:ok, 2} = Kawa.WorkflowRegistry.register_workflow("my-workflow", updated_definition)
```

### Managing Active Versions

```elixir
# Update workflow and make it active (default behavior)
{:ok, version} = Kawa.WorkflowRegistry.update_workflow(
  "my-workflow", 
  updated_definition_params
)

# Update workflow but don't make it active
{:ok, version} = Kawa.WorkflowRegistry.update_workflow(
  "my-workflow", 
  updated_definition_params,
  make_active: false
)

# Manually set a specific version as active
:ok = Kawa.WorkflowRegistry.set_active_version("my-workflow", 1)
```

## Usage Tracking

```elixir
# Record usage of the active version
Kawa.WorkflowRegistry.record_usage("ecommerce-order")

# Record usage of a specific version
Kawa.WorkflowRegistry.record_usage("ecommerce-order", 2)

# Get workflow after usage
{:ok, workflow} = Kawa.WorkflowRegistry.get_workflow("ecommerce-order")
IO.puts("Usage count: #{workflow.usage_count}")
IO.puts("Last used: #{workflow.last_used_at}")
```

## Statistics and Monitoring

```elixir
# Get registry statistics
stats = Kawa.WorkflowRegistry.get_stats()

IO.puts("Total workflows: #{stats.total_workflows}")
IO.puts("Total versions: #{stats.total_versions}")
IO.puts("Total usage: #{stats.total_usage}")
IO.puts("Unique clients: #{stats.unique_clients}")
```

## Error Handling

### Validation Errors

The registry uses `Kawa.WorkflowValidator` for comprehensive validation:

```elixir
# Invalid workflow will be rejected
invalid_definition = %{
  definition: %{
    "name" => "",  # Empty name
    "steps" => []  # No steps
  },
  client_id: "test-client"
}

{:error, {:invalid_workflow_definition, errors}} = 
  Kawa.WorkflowRegistry.register_workflow("invalid", invalid_definition)

# errors contains detailed validation information
Enum.each(errors, fn error ->
  IO.puts("#{error.field}: #{error.message}")
end)
```

### Common Error Cases

```elixir
# Missing required fields
{:error, {:missing_required_field, :definition}} = 
  Kawa.WorkflowRegistry.register_workflow("test", %{client_id: "test"})

# Workflow not found
{:error, :not_found} = 
  Kawa.WorkflowRegistry.get_workflow("non-existent")

# Version not found
{:error, :version_not_found} = 
  Kawa.WorkflowRegistry.set_active_version("test", 999)

# Updating non-existent workflow
{:error, :workflow_not_found} = 
  Kawa.WorkflowRegistry.update_workflow("non-existent", definition_params)
```

## Advanced Usage Patterns

### Workflow Lifecycle Management

```elixir
defmodule MyApp.WorkflowManager do
  alias Kawa.WorkflowRegistry

  def deploy_workflow(name, definition, client_id) do
    definition_params = %{
      definition: definition,
      client_id: client_id,
      metadata: %{
        "deployed_at" => DateTime.utc_now(),
        "deployed_by" => System.get_env("USER"),
        "git_commit" => get_git_commit()
      }
    }

    case WorkflowRegistry.register_workflow(name, definition_params) do
      {:ok, version} ->
        Logger.info("Deployed #{name} version #{version}")
        {:ok, version}

      {:error, reason} ->
        Logger.error("Failed to deploy #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def rollback_workflow(name, target_version) do
    case WorkflowRegistry.set_active_version(name, target_version) do
      :ok ->
        Logger.info("Rolled back #{name} to version #{target_version}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to rollback #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_workflow_history(name) do
    case WorkflowRegistry.list_workflow_versions(name) do
      {:ok, versions} ->
        Enum.map(versions, fn version ->
          %{
            version: version.version,
            is_active: version.is_active,
            registered_at: version.registered_at,
            usage_count: version.usage_count,
            metadata: version.metadata
          }
        end)

      {:error, :not_found} ->
        []
    end
  end

  defp get_git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"]) do
      {commit, 0} -> String.trim(commit)
      _ -> "unknown"
    end
  end
end
```

### Monitoring and Alerting

```elixir
defmodule MyApp.WorkflowMonitor do
  alias Kawa.WorkflowRegistry

  def check_workflow_health do
    stats = WorkflowRegistry.get_stats()
    
    # Check for unused workflows
    active_workflows = WorkflowRegistry.list_workflows()
    unused_workflows = 
      active_workflows
      |> Enum.filter(fn workflow -> 
        workflow.usage_count == 0 && 
        DateTime.diff(DateTime.utc_now(), workflow.registered_at, :day) > 30
      end)

    if length(unused_workflows) > 0 do
      Logger.warn("Found #{length(unused_workflows)} unused workflows")
    end

    # Check for high usage workflows
    high_usage_workflows = 
      active_workflows
      |> Enum.filter(fn workflow -> workflow.usage_count > 1000 end)

    if length(high_usage_workflows) > 0 do
      Logger.info("Found #{length(high_usage_workflows)} high-usage workflows")
    end

    %{
      total_workflows: stats.total_workflows,
      unused_count: length(unused_workflows),
      high_usage_count: length(high_usage_workflows)
    }
  end
end
```

## Integration with Application Supervision Tree

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Start the registry early in the supervision tree
      {Kawa.WorkflowRegistry, name: MyApp.WorkflowRegistry},
      
      # Other processes...
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Workflow Definition Validation

The registry automatically validates workflow definitions using `Kawa.WorkflowValidator`. Make sure your workflows follow the expected schema:

- Required fields: `name`, `steps`
- Valid step types: `http`, `elixir`
- Proper dependency references
- No circular dependencies
- Valid HTTP URLs and methods
- Proper timeout formats (e.g., "30s", "5m", "1h")

See the [workflow format documentation](../CLAUDE.md#saga-format-yaml) for complete schema details.