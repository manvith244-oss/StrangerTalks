defmodule StrangertalksNew.Experiments.Hearth.Supervisor do
  use Supervisor

  alias StrangertalksNew.Experiments.Hearth.{Authority, Notifier}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Authority, name: Authority, notifier: Notifier}
      ],
      strategy: :one_for_one
    )
  end
end
