defmodule StrangertalksNewWeb.TransportSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      StrangertalksNew.Hangouts.PresenceAuthority,
      StrangertalksNewWeb.Endpoint
    ]

    # PresenceAuthority and socket processes share one ordered failure domain.
    # If presence authority is lost, rest_for_one tears down and restarts the
    # Endpoint so no transport survives missing server-owned presence state.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
