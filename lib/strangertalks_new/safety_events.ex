defmodule StrangertalksNew.SafetyEvents do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.SafetyEvent

  def create_safety_event(attrs \\ %{}) do
    %SafetyEvent{}
    |> SafetyEvent.changeset(attrs)
    |> Repo.insert()
  end

  def get_safety_event(id) do
    Repo.get(SafetyEvent, id)
  end

  def change_safety_event(%SafetyEvent{} = safety_event, attrs \\ %{}) do
    SafetyEvent.changeset(safety_event, attrs)
  end
end
