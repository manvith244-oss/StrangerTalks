defmodule StrangertalksNew.Experiments.Hearth.Supervisor do
  use Supervisor

  alias StrangertalksNew.Experiments.Hearth.Authority

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([{Authority, name: Authority}], strategy: :one_for_one)
  end
end
