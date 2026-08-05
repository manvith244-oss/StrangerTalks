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
end
