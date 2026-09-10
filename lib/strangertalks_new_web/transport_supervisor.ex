defmodule StrangertalksNewWeb.TransportSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      StrangertalksNew.Hangouts.PresenceObserver,
      {Registry,
       keys: :duplicate,
       name: StrangertalksNew.Hangouts.PresenceRegistry,
       listeners: [StrangertalksNew.Hangouts.PresenceObserver]},
      StrangertalksNewWeb.Endpoint
    ]

    # Observer state, Registry registrations and the socket processes that own
    # them form one ordered failure domain. Registry loss restarts the Endpoint;
    # observer loss restarts both Registry and Endpoint. No transport is allowed
    # to survive loss of the authority that accounts for its presence.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
