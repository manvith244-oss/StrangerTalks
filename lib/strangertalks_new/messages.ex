defmodule StrangertalksNew.Messages do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Message

  def get_message(id), do: Repo.get(Message, id)

  def create_message(attrs \\ %{}) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  def change_message(%Message{} = message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end
end
