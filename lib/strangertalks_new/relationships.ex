defmodule StrangertalksNew.Relationships do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Relationship

  def create_relationship(attrs \\ %{}) do
    %Relationship{}
    |> Relationship.changeset(attrs)
    |> Repo.insert()
  end

  def get_relationship(id) do
    Repo.get(Relationship, id)
  end

  def change_relationship(%Relationship{} = relationship, attrs \\ %{}) do
    Relationship.changeset(relationship, attrs)
  end
end
