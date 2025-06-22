defmodule Kawa.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

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
          wait_for_services_ready()
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

  # Wait for critical services to be ready before triggering recovery
  defp wait_for_services_ready do
    services_to_check = [
      {Kawa.Repo, :ready?},
      {Kawa.Core.ClientRegistry, :alive?},
      {Kawa.Core.WorkflowRegistry, :alive?},
      {Kawa.Core.SagaSupervisor, :alive?}
    ]

    Enum.each(services_to_check, fn {module, check_fn} ->
      wait_for_service(module, check_fn)
    end)
  end

  defp wait_for_service(module, check_fn, attempts \\ 0) do
    # 5 seconds max wait
    max_attempts = 50

    cond do
      attempts >= max_attempts ->
        Logger.error("Service #{module} failed to become ready after #{max_attempts} attempts")

      service_ready?(module, check_fn) ->
        Logger.debug("Service #{module} is ready")

      true ->
        Process.sleep(100)
        wait_for_service(module, check_fn, attempts + 1)
    end
  end

  defp service_ready?(module, :ready?) do
    try do
      apply(module, :ready?, [])
    rescue
      _ -> false
    end
  end

  defp service_ready?(module, :alive?) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
