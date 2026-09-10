defmodule StrangertalksNewWeb.TransportSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :duplicate, name: StrangertalksNew.Hangouts.PresenceRegistry},
      StrangertalksNewWeb.Endpoint
    ]

    # Presence registrations and the socket processes that own them must share a
    # failure domain. If the Registry is ever lost, restart the Endpoint too so
    # no still-live channel can outlive its authoritative registration.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
