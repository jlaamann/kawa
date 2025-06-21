defmodule KawaWeb.ClientChannelTest do
  use KawaWeb.ChannelCase

  alias KawaWeb.{UserSocket, ClientChannel}
  alias Kawa.{Repo}
  alias Kawa.Core.ClientRegistry
  alias Kawa.Schemas.Client

  setup do
    # Create a test client with API key
    {:ok, client} = create_test_client()

    %{client: client, api_key: client.api_key}
  end

  describe "join/3" do
    test "joins successfully with valid API key", %{client: client, api_key: api_key} do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:ok, reply, socket} =
               subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{
                 "api_key" => api_key
               })

      assert reply.client_id == client.id
      assert reply.status == "connected"
      assert socket.assigns.client.id == client.id
    end

    test "rejects connection with invalid API key", %{client: client} do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:error, reply} =
               subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{
                 "api_key" => "invalid_key"
               })

      assert reply.reason == "authentication_failed"
    end

    test "rejects connection without API key", %{client: client} do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:error, reply} =
               subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{})

      assert reply.reason == "api_key_required"
    end

    test "registers client in ClientRegistry on successful join", %{
      client: client,
      api_key: api_key
    } do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{
                 "api_key" => api_key
               })

      assert ClientRegistry.client_connected?(client.id)
    end
  end

  describe "handle_in/3" do
    setup %{client: client, api_key: api_key} do
      {:ok, socket} = connect(UserSocket, %{})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{"api_key" => api_key})

      %{socket: socket}
    end

    test "handles heartbeat message", %{socket: socket} do
      ref = push(socket, "heartbeat", %{})

      assert_reply ref, :ok, %{timestamp: timestamp}
      assert %DateTime{} = timestamp
    end

    test "handles valid workflow registration", %{socket: socket} do
      workflow_def = %{
        "name" => "test-workflow",
        "steps" => [
          %{
            "id" => "step1",
            "type" => "http",
            "action" => %{"method" => "GET", "url" => "http://example.com"}
          }
        ]
      }

      ref = push(socket, "register_workflow", %{"workflow" => workflow_def})

      assert_reply ref, :ok, %{status: "workflow_registered", workflow_id: "test-workflow"}
    end

    test "rejects invalid workflow registration", %{socket: socket} do
      invalid_workflow = %{
        # Invalid characters
        "name" => "invalid workflow!",
        # Empty steps
        "steps" => []
      }

      ref = push(socket, "register_workflow", %{"workflow" => invalid_workflow})

      assert_reply ref, :error, %{reason: "validation_failed", errors: errors}
      assert is_list(errors)
      assert length(errors) > 0
    end

    test "handles step result", %{socket: socket} do
      ref =
        push(socket, "step_result", %{
          "saga_id" => "test-saga-123",
          "step_id" => "test-step",
          "result" => %{"success" => true}
        })

      assert_reply ref, :ok, %{status: "result_received"}
    end
  end

  describe "terminate/2" do
    test "unregisters client on disconnect", %{client: client, api_key: api_key} do
      {:ok, socket} = connect(UserSocket, %{})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, ClientChannel, "client:#{client.id}", %{"api_key" => api_key})

      # Verify client is registered
      assert ClientRegistry.client_connected?(client.id)

      # Close the connection
      Process.unlink(socket.channel_pid)
      close(socket)

      # Wait a bit for cleanup
      Process.sleep(50)

      # Verify client is unregistered
      refute ClientRegistry.client_connected?(client.id)
    end
  end

  defp create_test_client do
    %Client{}
    |> Client.create_changeset(%{
      "name" => "test-client-#{System.unique_integer([:positive])}",
      "environment" => "dev"
    })
    |> Repo.insert()
  end
end
