defmodule KawaWeb.ClientChannelWorkflowTest do
  use KawaWeb.ChannelCase

  alias KawaWeb.{UserSocket, ClientChannel}
  alias Kawa.{Repo}
  alias Kawa.Core.{ClientRegistry}
  alias Kawa.Schemas.{Client, WorkflowDefinition}

  setup do
    # Create a test client with API key
    {:ok, client} = create_test_client()
    {:ok, workflow_def} = create_test_workflow_definition(client)

    %{
      client: client,
      api_key: client.api_key,
      workflow_def: workflow_def
    }
  end

  describe "join/3" do
    test "joins successfully with valid API key", %{client: client, api_key: api_key} do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:ok, _reply, socket} =
               subscribe_and_join(
                 socket,
                 ClientChannel,
                 "client:#{client.id}",
                 %{
                   "api_key" => api_key
                 }
               )

      assert socket.assigns.client_id == client.id
      assert socket.assigns.client.id == client.id
    end

    test "rejects connection with invalid API key", %{client: client} do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:error, reply} =
               subscribe_and_join(
                 socket,
                 ClientChannel,
                 "client:#{client.id}",
                 %{
                   "api_key" => "invalid_key"
                 }
               )

      assert reply.reason == "authentication_failed"
    end

    test "rejects connection without API key", %{client: client} do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:error, reply} =
               subscribe_and_join(
                 socket,
                 ClientChannel,
                 "client:#{client.id}",
                 %{}
               )

      assert reply.reason == "api_key_required"
    end

    test "rejects connection for non-existent client" do
      {:ok, socket} = connect(UserSocket, %{})
      fake_client_id = Ecto.UUID.generate()

      assert {:error, reply} =
               subscribe_and_join(
                 socket,
                 ClientChannel,
                 "client:#{fake_client_id}",
                 %{
                   "api_key" => "any_key"
                 }
               )

      assert reply.reason == "authentication_failed"
    end

    test "registers client channel in ClientRegistry on successful join", %{
      client: client,
      api_key: api_key
    } do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 ClientChannel,
                 "client:#{client.id}",
                 %{
                   "api_key" => api_key
                 }
               )

      # Check that the client channel is registered
      assert {:ok, _pid} = ClientRegistry.get_client_channel_pid(client.id, :client)
    end
  end

  describe "handle_in trigger_workflow - validation" do
    setup %{client: client, api_key: api_key} do
      {:ok, socket} = connect(UserSocket, %{})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{
          "api_key" => api_key
        })

      %{socket: socket}
    end

    test "rejects request with missing required fields", %{socket: socket} do
      payload = %{
        "workflow_name" => "test-workflow"
        # Missing correlation_id
      }

      ref = push(socket, "trigger_workflow", payload)

      assert_reply ref, :error, %{validation_errors: errors}
      assert is_list(errors)
      assert Keyword.has_key?(errors, :required_fields)
    end

    test "rejects request for non-existent workflow", %{socket: socket} do
      payload = %{
        "workflow_name" => "non-existent-workflow",
        "correlation_id" => "test-correlation-#{System.unique_integer([:positive])}"
      }

      ref = push(socket, "trigger_workflow", payload)

      assert_reply ref, :error, %{validation_errors: errors}
      assert is_list(errors)
      assert Keyword.has_key?(errors, :workflow)
    end

    test "rejects request for non-existent workflow version", %{
      socket: socket,
      workflow_def: workflow_def
    } do
      payload = %{
        "workflow_name" => workflow_def.name,
        "workflow_version" => "999.0.0",
        "correlation_id" => "test-correlation-#{System.unique_integer([:positive])}"
      }

      ref = push(socket, "trigger_workflow", payload)

      assert_reply ref, :error, %{validation_errors: errors}
      assert is_list(errors)
      assert Keyword.has_key?(errors, :workflow)
    end
  end

  describe "handle_in get_saga_status" do
    setup %{client: client, api_key: api_key} do
      {:ok, socket} = connect(UserSocket, %{})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{
          "api_key" => api_key
        })

      %{socket: socket}
    end

    test "returns error for non-existent saga", %{socket: socket} do
      ref = push(socket, "get_saga_status", %{"saga_id" => "non-existent-saga"})

      assert_reply ref, :error, %{reason: _reason}
    end
  end

  # Helper functions

  defp create_test_client do
    %Client{}
    |> Client.create_changeset(%{
      "name" => "test-client-#{System.unique_integer([:positive])}",
      "environment" => "dev"
    })
    |> Repo.insert()
  end

  defp create_test_workflow_definition(client) do
    workflow_definition = %{
      "name" => "payment_workflow",
      "description" => "Test payment workflow",
      "steps" => [
        %{
          "id" => "payment_step",
          "name" => "Process Payment",
          "type" => "http",
          "depends_on" => [],
          "timeout_ms" => 30_000,
          "action" => %{
            "method" => "POST",
            "url" => "https://payment-api.example.com/charge",
            "headers" => %{"Content-Type" => "application/json"}
          },
          "compensation" => %{
            "method" => "POST",
            "url" => "https://payment-api.example.com/refund"
          }
        },
        %{
          "id" => "notification_step",
          "name" => "Send Notification",
          "type" => "http",
          "depends_on" => ["payment_step"],
          "timeout_ms" => 10_000,
          "action" => %{
            "method" => "POST",
            "url" => "https://notification-api.example.com/send"
          }
        }
      ]
    }

    %WorkflowDefinition{}
    |> WorkflowDefinition.changeset(%{
      name: "payment_workflow_#{System.unique_integer([:positive])}",
      version: "1.0.0",
      module_name: "PaymentWorkflow",
      definition: workflow_definition,
      definition_checksum: "test-checksum-#{System.unique_integer([:positive])}",
      client_id: client.id,
      is_active: true
    })
    |> Repo.insert()
  end
end
