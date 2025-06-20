# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kawa is a distributed saga orchestration engine built in Elixir. This project implements the Saga pattern for managing distributed transactions across microservices.

## Development Setup

This project uses Elixir/OTP. Common development commands will likely include:

- `mix deps.get` - Install dependencies
- `mix compile` - Compile the project
- `mix test` - Run tests
- `mix format` - Format code
- `mix credo` - Static analysis (if Credo is added)
- `mix dialyzer` - Type checking (if Dialyzer is configured)

## Architecture

As a saga orchestration engine, this project will likely implement:

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
