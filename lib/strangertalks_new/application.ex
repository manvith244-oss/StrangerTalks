defmodule StrangertalksNew.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StrangertalksNewWeb.Telemetry,
      StrangertalksNew.Repo,
      {DNSCluster, query: Application.get_env(:strangertalks_new, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: StrangertalksNew.PubSub},
      {Registry, keys: :unique, name: StrangertalksNew.DistributedRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: StrangertalksNew.ConversationDynamicSupervisor},
      StrangertalksNew.ConversationLifecycle.VoiceNoteStore,
      StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore,
      StrangertalksNew.RateLimiter,

      # Queue Engine Processes (Must boot before the Web Endpoint)
      StrangertalksNew.QueueEngine.QueueState,
      StrangertalksNew.QueueEngine.ParticipantConnectionTracker,
      StrangertalksNew.QueueEngine.RamMonitor,
      StrangertalksNew.QueueEngine.SafetyReceiver,
      StrangertalksNew.ConversationLifecycle.RecoverySweeper,

      # Start a worker by calling: StrangertalksNew.Worker.start_link(arg)
      # {StrangertalksNew.Worker, arg},

      # Start to serve requests, typically the last entry
      StrangertalksNewWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: StrangertalksNew.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StrangertalksNewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
