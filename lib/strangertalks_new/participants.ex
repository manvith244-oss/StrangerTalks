defmodule StrangertalksNew.Participants do
  @moduledoc """
  The Participants context — the public API for creating and fetching participants.
  """

  alias StrangertalksNew.Repo
  alias StrangertalksNew.Participant

  def create_participant(attrs \\ %{}) do
    %Participant{}
    |> Ecto.Changeset.cast(attrs, [:presence_state, :last_active_at, :created_at])
    |> Repo.insert()
  end

  def get_participant(id) do
    Repo.get(Participant, id)
  end

  def list_participants do
    Repo.all(Participant)
  end
end
