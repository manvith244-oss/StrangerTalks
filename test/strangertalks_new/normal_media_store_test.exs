defmodule StrangertalksNew.NormalMediaStoreTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  setup do
    conversation_id = Ecto.UUID.generate()
    on_exit(fn -> NormalMediaStore.delete_conversation(conversation_id) end)
    {:ok, conversation_id: conversation_id}
  end

  test "same logical upload is idempotent and preserves its original ordering anchor", %{
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
               self(),
               3
             )

    assert {:ok, second, :duplicate} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               binary,
               metadata,
               self(),
               99
             )

    assert first.client_message_id == second.client_message_id
    assert first.anchor_sequence == 3
    assert first.anchor_ordinal == 1
    assert second.anchor_sequence == 3
    assert second.anchor_ordinal == 1

    other = "different-media"

    assert {:error, :normal_media_identity_conflict} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               other,
               metadata(other),
               self(),
               3
             )
  end

  test "multiple media accepted at one Conversation boundary get deterministic ordinals", %{
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
               self(),
               7
             )

    assert {:ok, second, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               second_id,
               "second",
               metadata("second"),
               self(),
               7
             )

    assert first.anchor_sequence == 7
    assert second.anchor_sequence == 7
    assert first.anchor_ordinal == 1
    assert second.anchor_ordinal == 2

    assert {:ok, items} = NormalMediaStore.list_media(conversation_id, sender_id)
    assert Enum.map(items, & &1.client_message_id) == [first_id, second_id]
  end

  test "media at later Conversation boundaries sort after earlier anchors", %{
    conversation_id: conversation_id
  } do
    sender_id = Ecto.UUID.generate()
    later_id = Ecto.UUID.generate()
    earlier_id = Ecto.UUID.generate()

    assert {:ok, _later, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               later_id,
               "later",
               metadata("later"),
               self(),
               2
             )

    assert {:ok, _earlier, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               earlier_id,
               "earlier",
               metadata("earlier"),
               self(),
               1
             )

    assert {:ok, items} = NormalMediaStore.list_media(conversation_id, sender_id)
    assert Enum.map(items, & &1.client_message_id) == [earlier_id, later_id]
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
               self(),
               0
             )

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(other_conversation_id, message_id)
  end

  test "owner process death removes every binary for that Conversation", %{
    conversation_id: conversation_id
  } do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    sender_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    assert {:ok, _item, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               "temporary",
               metadata("temporary"),
               owner,
               0
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
