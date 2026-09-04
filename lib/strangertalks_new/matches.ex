defmodule StrangertalksNew.Matches do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Matching

  def get_match(match_id) do
    Repo.get(Matching, match_id)
  end

  def create_match(attrs \\ %{}) do
    %Matching{}
    |> Matching.changeset(attrs)
    |> Repo.insert()
  end

  def change_match(%Matching{} = matching, attrs \\ %{}) do
    Matching.changeset(matching, attrs)
  end

  def conversation_started?(match_id) do
    case Repo.get(Matching, match_id) do
      %Matching{conversation_started: true} -> true
      _ -> false
    end
  end

  def mark_conversation_started!(match_id) do
    matching = Repo.get!(Matching, match_id)

    unless matching.conversation_started do
      matching
      |> Matching.changeset(%{conversation_started: true})
      |> Repo.update!()
    end

    :ok
  end
end
