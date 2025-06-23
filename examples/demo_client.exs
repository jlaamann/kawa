#!/usr/bin/env elixir

defmodule DemoClient do
  @moduledoc """
  Demo client for Kawa saga orchestration engine using gun WebSocket client.

  This demo connects to a real Kawa server and demonstrates the complete saga 
  lifecycle including workflow registration, step execution, compensation, 
  and error handling using actual WebSocket communication.

  Prerequisites:
    - Kawa server running on localhost:4000
    - Database available and migrated

  Usage:
    mix phx.server  # Start Kawa server first
    mix run examples/demo_client.exs
  """

  require Logger

  defstruct [
    :client_id,
    :api_key,
    :gun_pid,
    :stream_ref,
    :ref_counter,
    :pending_refs,
    :active_sagas,
    :workflow_registered,
    :workflow_name
  ]

  def start_demo do
    Logger.info("🚀 Starting Kawa Demo Client")

    # Create client via Kawa API
    case create_client_via_api() do
      {:ok, client_info} ->
        Logger.info("📋 Created client: #{client_info.id}")

        # Connect to Kawa WebSocket
        case connect_to_kawa(client_info) do
          {:ok, client_state} ->
            run_demo_scenarios(client_state)

          {:error, reason} ->
            Logger.error("❌ Failed to connect: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("❌ Failed to create client: #{inspect(reason)}")
    end
  end

  defp create_client_via_api do
    Logger.info("📝 Creating client via Kawa API...")

    client_data = %{
      "name" => "demo-client-#{System.unique_integer([:positive])}-#{:rand.uniform(10000)}",
      "environment" => "dev"
    }

    case HTTPoison.post("http://localhost:4000/api/clients", Jason.encode!(client_data), [
           {"Content-Type", "application/json"}
         ]) do
      {:ok, %HTTPoison.Response{status_code: 201, body: body}} ->
        case Jason.decode(body) do
          {:ok, response} ->
            client_info = %{
              id: response["client"]["id"],
              api_key: response["api_key"],
              name: response["client"]["name"]
            }

            Logger.info("✅ Client created: #{client_info.name}")
            Logger.info("   ID: #{client_info.id}")
            api_key_preview = String.slice(client_info.api_key, 0, 15) <> "..."
            Logger.info("   API Key: #{api_key_preview}")
            {:ok, client_info}

          {:error, reason} ->
            Logger.error("❌ Failed to parse response: #{inspect(reason)}")
            {:error, :parse_error}
        end

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.error("❌ API request failed with status #{status}: #{body}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("❌ HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp connect_to_kawa(client_info) do
    Logger.info("🔌 Connecting to Kawa WebSocket...")

    # Start gun connection
    case :gun.open(~c"localhost", 4000, %{protocols: [:http]}) do
      {:ok, gun_pid} ->
        Logger.debug("📡 Gun connection established")

        # Wait for gun to be ready
        case :gun.await_up(gun_pid, 5000) do
          {:ok, _protocol} ->
            Logger.debug("🔗 Gun connection ready")

            # Upgrade to WebSocket
            stream_ref =
              :gun.ws_upgrade(gun_pid, "/socket/websocket", [
                {"sec-websocket-protocol", "websocket"}
              ])

            # Wait for upgrade
            receive do
              {:gun_upgrade, ^gun_pid, ^stream_ref, ["websocket"], _headers} ->
                Logger.debug("✅ WebSocket upgrade successful")

                state = %__MODULE__{
                  client_id: client_info.id,
                  api_key: client_info.api_key,
                  gun_pid: gun_pid,
                  stream_ref: stream_ref,
                  ref_counter: 1,
                  pending_refs: %{},
                  active_sagas: %{},
                  workflow_registered: false,
                  workflow_name: nil
                }

                # Join the client channel
                join_channel(state, client_info)

              {:gun_response, ^gun_pid, ^stream_ref, _, status, _headers} ->
                Logger.error("❌ WebSocket upgrade failed with status: #{status}")
                :gun.close(gun_pid)
                {:error, {:upgrade_failed, status}}

              {:gun_error, ^gun_pid, ^stream_ref, reason} ->
                Logger.error("❌ WebSocket upgrade error: #{inspect(reason)}")
                :gun.close(gun_pid)
                {:error, {:upgrade_error, reason}}
            after
              10_000 ->
                Logger.error("❌ WebSocket upgrade timeout")
                :gun.close(gun_pid)
                {:error, :upgrade_timeout}
            end

          {:error, reason} ->
            Logger.error("❌ Gun connection failed: #{inspect(reason)}")
            :gun.close(gun_pid)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("❌ Failed to open gun connection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp join_channel(state, client_info) do
    Logger.info("🔌 Joining client channel...")

    join_ref = get_next_ref(state)

    join_message = %{
      "topic" => "client:#{client_info.id}",
      "event" => "phx_join",
      "payload" => %{"api_key" => client_info.api_key},
      "ref" => join_ref
    }

    send_message(state, join_message)

    # Wait for join confirmation
    receive do
      {:gun_ws, _gun_pid, _stream_ref, {:text, json_message}} ->
        case Jason.decode(json_message) do
          {:ok, %{"event" => "phx_reply", "payload" => %{"status" => "ok"}}} ->
            Logger.info("✅ Successfully joined client channel")
            {:ok, state}

          {:ok,
           %{"event" => "phx_reply", "payload" => %{"status" => "error", "response" => reason}}} ->
            Logger.error("❌ Failed to join channel: #{inspect(reason)}")
            {:error, reason}

          {:ok, other} ->
            Logger.debug("📨 Received unexpected message: #{inspect(other)}")
            join_channel(state, client_info)

          {:error, reason} ->
            Logger.error("❌ Failed to decode join response: #{inspect(reason)}")
            {:error, :decode_error}
        end
    after
      10_000 ->
        Logger.error("❌ Channel join timeout")
        {:error, :timeout}
    end
  end

  defp run_demo_scenarios(state) do
    # Register workflow
    case register_payment_workflow(state) do
      {:ok, updated_state} ->
        Logger.info("✅ Workflow registered successfully")

        # Run demo scenarios
        demo_successful_workflow(updated_state)

        # Wait a moment between demos
        Process.sleep(2000)

        demo_failed_workflow_with_compensation(updated_state)

        Logger.info("\\n🎊 Demo Summary:")
        Logger.info("   ✅ Demo 1: Successfully executed workflow with all steps completing")
        Logger.info("   ❌ Demo 2: Workflow failed at inventory step, compensation executed")
        Logger.info("   🔄 Demonstrated: Step execution, failure handling, and compensation")
        Logger.info("\\n✅ All demos completed successfully!")

        # Close connection
        :gun.close(state.gun_pid)

      {:error, reason} ->
        Logger.error("❌ Workflow registration failed: #{inspect(reason)}")
        :gun.close(state.gun_pid)
    end
  end

  defp register_payment_workflow(state) do
    Logger.info("📦 Registering payment workflow...")

    unique_suffix = System.unique_integer([:positive])
    workflow_name = "payment_processing_#{unique_suffix}"

    workflow_definition = %{
      "name" => workflow_name,
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

    ref = get_next_ref(state)

    message = %{
      "topic" => "client:#{state.client_id}",
      "event" => "register_workflow",
      "payload" => workflow_definition,
      "ref" => ref
    }

    Logger.info("📤 Sending workflow registration...")
    send_message(state, message)

    # Wait for registration response
    receive do
      {:gun_ws, _gun_pid, _stream_ref, {:text, json_message}} ->
        case Jason.decode(json_message) do
          {:ok,
           %{
             "event" => "phx_reply",
             "payload" => %{"response" => %{"status" => "workflow_registered"}}
           }} ->
            {:ok, %{state | workflow_registered: true, workflow_name: workflow_name}}

          {:ok,
           %{"event" => "phx_reply", "payload" => %{"status" => "error", "response" => reason}}} ->
            Logger.error("❌ Workflow registration failed: #{inspect(reason)}")
            {:error, reason}

          {:ok, other} ->
            Logger.debug(
              "📨 Received unexpected message during workflow registration: #{inspect(other)}"
            )

            register_payment_workflow(state)

          {:error, reason} ->
            Logger.error("❌ Failed to decode workflow registration response: #{inspect(reason)}")
            {:error, :decode_error}
        end
    after
      15_000 ->
        Logger.error("❌ Workflow registration timeout")
        {:error, :timeout}
    end
  end

  defp demo_successful_workflow(state) do
    Logger.info("\\n🎯 Demo 1: Successful Workflow Execution")

    # Trigger workflow
    trigger_payload = %{
      "workflow_name" => state.workflow_name,
      "correlation_id" => "order_" <> String.slice(Ecto.UUID.generate(), 0, 8),
      "input" => %{
        "amount" => 99.99,
        "currency" => "USD",
        "card_number" => "**** **** **** 1234",
        "product_id" => "DEMO_PRODUCT_001",
        "customer_email" => "demo@example.com"
      },
      "metadata" => %{
        "source" => "demo_client",
        "environment" => "dev",
        "scenario" => "success"
      }
    }

    ref = get_next_ref(state)

    message = %{
      "topic" => "client:#{state.client_id}",
      "event" => "trigger_workflow",
      "payload" => trigger_payload,
      "ref" => ref
    }

    Logger.info("🚀 Triggering workflow: #{trigger_payload["correlation_id"]}")
    send_message(state, message)

    # Wait for trigger response and handle any step executions
    wait_for_saga_completion(state, "success")
  end

  defp demo_failed_workflow_with_compensation(state) do
    Logger.info("\\n❌ Demo 2: Failed Workflow with Compensation")

    # Trigger workflow that will fail at inventory step
    trigger_payload = %{
      "workflow_name" => state.workflow_name,
      "correlation_id" => "order_" <> String.slice(Ecto.UUID.generate(), 0, 8),
      "input" => %{
        "amount" => 199.99,
        "currency" => "USD",
        "card_number" => "**** **** **** 5678",
        "product_id" => "OUT_OF_STOCK_ITEM",
        "customer_email" => "demo2@example.com"
      },
      "metadata" => %{
        "source" => "demo_client",
        "environment" => "dev",
        "scenario" => "failure"
      }
    }

    ref = get_next_ref(state)

    message = %{
      "topic" => "client:#{state.client_id}",
      "event" => "trigger_workflow",
      "payload" => trigger_payload,
      "ref" => ref
    }

    Logger.info("🚀 Triggering workflow (will fail): #{trigger_payload["correlation_id"]}")
    send_message(state, message)

    # Wait for saga and handle steps that will fail
    wait_for_saga_completion(state, "failure")
  end

  defp wait_for_saga_completion(state, scenario) do
    receive do
      {:gun_ws, _gun_pid, _stream_ref, {:text, json_message}} ->
        case Jason.decode(json_message) do
          {:ok,
           %{
             "event" => "phx_reply",
             "payload" => %{
               "response" => %{"saga_id" => saga_id, "correlation_id" => correlation_id}
             }
           }} ->
            Logger.info("📋 Saga created: #{saga_id}")
            Logger.info("🔗 Correlation ID: #{correlation_id}")
            wait_for_saga_completion(state, scenario)

          {:ok, %{"event" => "execute_step", "payload" => payload}} ->
            saga_id = payload["saga_id"]
            step_id = payload["step_id"]
            Logger.info("📨 Received execute_step: #{step_id}")
            handle_step_execution(state, saga_id, step_id, payload, scenario)
            wait_for_saga_completion(state, scenario)

          {:ok, %{"event" => "compensate_step", "payload" => payload}} ->
            saga_id = payload["saga_id"]
            step_id = payload["step_id"]
            Logger.info("📨 Received compensate_step: #{step_id}")
            handle_compensation(state, saga_id, step_id, payload)
            wait_for_saga_completion(state, scenario)

          {:ok, %{"event" => "saga_status_update", "payload" => payload}} ->
            saga_id = payload["saga_id"]
            status = payload["status"]
            Logger.info("📊 Saga #{String.slice(saga_id, 0, 8)}... status: #{status}")

            if status in ["completed", "failed", "compensated"] do
              Logger.info(
                "🏁 Saga #{String.slice(saga_id, 0, 8)}... finished with status: #{status}"
              )

              :done
            else
              wait_for_saga_completion(state, scenario)
            end

          {:ok, other} ->
            Logger.debug("📨 Received message: #{inspect(other)}")
            wait_for_saga_completion(state, scenario)

          {:error, reason} ->
            Logger.error("❌ Failed to decode message: #{inspect(reason)}")
            wait_for_saga_completion(state, scenario)
        end
    after
      30_000 ->
        Logger.info("⏰ Saga completion timeout - finishing demo")
        :done
    end
  end

  defp handle_step_execution(state, saga_id, step_id, _step_data, scenario) do
    Logger.info("⚙️  Executing step: #{step_id} (saga: #{String.slice(saga_id, 0, 8)}...)")

    # Simulate processing time
    Process.sleep(100 + :rand.uniform(400))

    # Check if this step should fail based on scenario
    case scenario do
      "failure" when step_id == "update_inventory" ->
        # Fail at inventory step for compensation demo
        execute_failed_step(state, saga_id, step_id)

      _ ->
        # Execute step successfully
        execute_successful_step(state, saga_id, step_id)
    end
  end

  defp execute_successful_step(state, saga_id, step_id) do
    result =
      case step_id do
        "validate_payment" ->
          %{
            "validation_passed" => true,
            "order_total" => 99.99,
            "tax_amount" => 8.00,
            "processing_fee" => 2.99
          }

        "charge_card" ->
          %{
            "transaction_id" => "txn_" <> String.slice(Ecto.UUID.generate(), 0, 8),
            "amount_charged" => 99.99,
            "authorization_code" => "AUTH_" <> String.slice(Ecto.UUID.generate(), 0, 6)
          }

        "update_inventory" ->
          %{
            "inventory_updated" => true,
            "new_stock_level" => 47,
            "reservation_id" => "RES_" <> String.slice(Ecto.UUID.generate(), 0, 8)
          }

        _ ->
          %{"step_executed" => true, "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()}
      end

    send_step_completed(state, saga_id, step_id, result)
  end

  defp execute_failed_step(state, saga_id, step_id) do
    Process.sleep(50 + :rand.uniform(200))

    error = %{
      "type" => "inventory_error",
      "message" => "Product out of stock",
      "code" => "OUT_OF_STOCK",
      "retryable" => false,
      "details" => %{
        "product_id" => "OUT_OF_STOCK_ITEM",
        "requested_quantity" => 1,
        "available_quantity" => 0
      }
    }

    Logger.info("❌ Step failed: #{step_id} - #{error["message"]}")
    send_step_failed(state, saga_id, step_id, error)
  end

  defp handle_compensation(state, saga_id, step_id, _compensation_data) do
    Logger.info("🔄 Compensating step: #{step_id} (saga: #{String.slice(saga_id, 0, 8)}...)")

    # Simulate compensation processing
    Process.sleep(100 + :rand.uniform(200))

    result =
      case step_id do
        "charge_card" ->
          %{
            "refund_id" => "REF_" <> String.slice(Ecto.UUID.generate(), 0, 8),
            "refund_amount" => 199.99,
            "refund_status" => "completed"
          }

        "validate_payment" ->
          %{
            "cache_cleared" => true,
            "validation_cleanup" => "completed"
          }

        _ ->
          %{
            "compensated" => true,
            "compensation_action" => "rollback_#{step_id}",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
      end

    send_compensation_completed(state, saga_id, step_id, result)
  end

  defp send_step_completed(state, saga_id, step_id, result) do
    ref = System.unique_integer([:positive]) |> Integer.to_string()

    message = %{
      "topic" => "client:#{state.client_id}",
      "event" => "step_completed",
      "payload" => %{
        "saga_id" => saga_id,
        "step_id" => step_id,
        "result" => result
      },
      "ref" => ref
    }

    Logger.info("📤 Step completed: #{step_id}")
    Logger.debug("Result: #{inspect(result, pretty: true)}")

    send_message(state, message)
  end

  defp send_step_failed(state, saga_id, step_id, error) do
    ref = System.unique_integer([:positive]) |> Integer.to_string()

    message = %{
      "topic" => "client:#{state.client_id}",
      "event" => "step_failed",
      "payload" => %{
        "saga_id" => saga_id,
        "step_id" => step_id,
        "error" => error
      },
      "ref" => ref
    }

    Logger.info("📤 Step failed: #{step_id}")
    send_message(state, message)
  end

  defp send_compensation_completed(state, saga_id, step_id, result) do
    ref = System.unique_integer([:positive]) |> Integer.to_string()

    message = %{
      "topic" => "client:#{state.client_id}",
      "event" => "compensation_completed",
      "payload" => %{
        "saga_id" => saga_id,
        "step_id" => step_id,
        "result" => result
      },
      "ref" => ref
    }

    Logger.info("📤 Compensation completed: #{step_id}")
    send_message(state, message)
  end

  defp get_next_ref(state) do
    ref = Integer.to_string(state.ref_counter)
    _updated_state = %{state | ref_counter: state.ref_counter + 1}
    ref
  end

  defp send_message(state, message) do
    json_message = Jason.encode!(message)
    :gun.ws_send(state.gun_pid, state.stream_ref, {:text, json_message})
  end
end

# Run the demo
require Logger
Logger.configure(level: :info)

Logger.info("=" <> String.duplicate("=", 60))
Logger.info("    KAWA WEBSOCKET DEMO CLIENT")
Logger.info("=" <> String.duplicate("=", 60))

DemoClient.start_demo()
