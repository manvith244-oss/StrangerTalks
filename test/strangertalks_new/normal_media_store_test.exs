defmodule StrangertalksNew.NormalMediaStoreTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  setup do
    conversation_id = Ecto.UUID.generate()
    on_exit(fn -> NormalMediaStore.delete_conversation(conversation_id) end)
    {:ok, conversation_id: conversation_id}
  end

  test "same logical upload is idempotent and conflicting content is rejected", %{
    conversation_id: conversation_id
  } do
    sender_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()
    binary = "normal-media"
    metadata = metadata(binary)

    assert {:ok, first, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               binary,
               metadata,
               self()
             )

    assert {:ok, second, :duplicate} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               binary,
               metadata,
               self()
             )

    assert first.client_message_id == second.client_message_id
    assert first.sequence == second.sequence

    other = "different-media"

    assert {:error, :normal_media_identity_conflict} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               other,
               metadata(other),
               self()
             )

    assert {:ok, items} = NormalMediaStore.list_media(conversation_id, sender_id)
    assert Enum.map(items, & &1.client_message_id) == [message_id]
  end

  test "two rapid media sends retain independent identities and order", %{
    conversation_id: conversation_id
  } do
    sender_id = Ecto.UUID.generate()
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    assert {:ok, first, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               first_id,
               "first",
               metadata("first"),
               self()
             )

    assert {:ok, second, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               second_id,
               "second",
               metadata("second"),
               self()
             )

    assert first.sequence < second.sequence
    assert {:ok, items} = NormalMediaStore.list_media(conversation_id, sender_id)
    assert Enum.map(items, & &1.client_message_id) == [first_id, second_id]
  end

  test "media is isolated by Conversation id", %{conversation_id: conversation_id} do
    other_conversation_id = Ecto.UUID.generate()
    sender_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    on_exit(fn -> NormalMediaStore.delete_conversation(other_conversation_id) end)

    assert {:ok, _item, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               "private",
               metadata("private"),
               self()
             )

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(other_conversation_id, message_id)
  end

  test "owner process death removes every binary for that Conversation", %{
    conversation_id: conversation_id
  } do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    sender_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    assert {:ok, _item, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               "temporary",
               metadata("temporary"),
               owner
             )

    assert {:ok, "temporary", "image/jpeg"} =
             NormalMediaStore.fetch_media(conversation_id, message_id)

    Process.exit(owner, :kill)

    assert eventually(fn ->
             NormalMediaStore.fetch_media(conversation_id, message_id) ==
               {:error, :media_unavailable}
           end)
  end

  defp metadata(binary) do
    %{
      media_type: "image/jpeg",
      width: 1,
      height: 1,
      content_hash: :crypto.hash(:sha256, binary)
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        1 -> eventually(fun, attempts - 1)
      end
    end
  end
end
