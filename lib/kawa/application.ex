defmodule Kawa.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KawaWeb.Telemetry,
      Kawa.Repo,
      {DNSCluster, query: Application.get_env(:kawa, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kawa.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Kawa.Finch},
      # Start the client registry for WebSocket connections
      Kawa.Core.ClientRegistry,
      # Start the workflow registry
      Kawa.Core.WorkflowRegistry,
      # Start the saga registry for process tracking
      {Registry, keys: :unique, name: Kawa.SagaRegistry},
      # Start the saga supervisor for managing saga processes
      Kawa.Core.SagaSupervisor,
      # Start the async step executor for timeout handling
      Kawa.Execution.AsyncStepExecutor,
      # Start the step execution tracker for monitoring
      Kawa.Execution.StepExecutionTracker,
      # Start saga recovery for handling server restarts
      Kawa.Core.SagaRecovery,
      # Start to serve requests, typically the last entry
      KawaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kawa.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Trigger saga recovery after all services are started
        Task.start(fn ->
          # Give services a moment to fully initialize
          Process.sleep(1000)
          Kawa.Core.SagaRecovery.recover_all_sagas()
        end)

        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KawaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
