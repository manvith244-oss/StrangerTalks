defmodule StrangertalksNew.NormalMediaStoreTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  setup do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: match.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: :ACTIVE,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    {:ok, pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})

    on_exit(fn ->
      NormalMediaStore.delete_conversation(conversation.conversation_id)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok,
     conversation_id: conversation.conversation_id,
     sender_id: a.participant_id,
     recipient_id: b.participant_id,
     owner_pid: pid}
  end

  test "same logical upload is idempotent and preserves its original Conversation anchor", %{
    conversation_id: conversation_id,
    sender_id: sender_id
  } do
    message_id = Ecto.UUID.generate()
    binary = "normal-media"

    assert {:ok, first, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               binary,
               metadata(binary)
             )

    assert first.anchor_sequence == 0
    assert first.anchor_ordinal == 1

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation_id,
               sender_id,
               Ecto.UUID.generate(),
               "accepted after media"
             )

    assert {:ok, retry, :duplicate} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               binary,
               metadata(binary)
             )

    assert retry.anchor_sequence == 0
    assert retry.anchor_ordinal == 1

    other = "different-media"

    assert {:error, :normal_media_identity_conflict} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               other,
               metadata(other)
             )
  end

  test "multiple media accepted at one generic Conversation boundary get deterministic ordinals",
       %{
         conversation_id: conversation_id,
         sender_id: sender_id
       } do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    assert {:ok, first, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               first_id,
               "first",
               metadata("first")
             )

    assert {:ok, second, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               second_id,
               "second",
               metadata("second")
             )

    assert first.anchor_sequence == 0
    assert second.anchor_sequence == 0
    assert first.anchor_ordinal == 1
    assert second.anchor_ordinal == 2

    assert {:ok, items} = NormalMediaStore.list_media(conversation_id, sender_id)
    assert Enum.map(items, & &1.client_message_id) == [first_id, second_id]
  end

  test "media → text → media is anchored to the shared Conversation acceptance order", %{
    conversation_id: conversation_id,
    sender_id: sender_id
  } do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    assert {:ok, first, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               first_id,
               "first",
               metadata("first")
             )

    assert first.anchor_sequence == 0

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation_id,
               sender_id,
               Ecto.UUID.generate(),
               "middle text"
             )

    assert {:ok, second, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               second_id,
               "second",
               metadata("second")
             )

    assert second.anchor_sequence == 1
    assert second.anchor_ordinal == 1

    assert {:ok, items} = NormalMediaStore.list_media(conversation_id, sender_id)

    assert Enum.map(items, &{&1.client_message_id, &1.anchor_sequence, &1.anchor_ordinal}) == [
             {first_id, 0, 1},
             {second_id, 1, 1}
           ]
  end

  test "concurrent text and media can only land on one side of the same canonical boundary", %{
    conversation_id: conversation_id,
    sender_id: sender_id
  } do
    media_id = Ecto.UUID.generate()
    text_id = Ecto.UUID.generate()

    media_task =
      Task.async(fn ->
        NormalMediaStore.put_media(
          conversation_id,
          sender_id,
          media_id,
          "race-media",
          metadata("race-media")
        )
      end)

    text_task =
      Task.async(fn ->
        ConversationServer.append_message(conversation_id, sender_id, text_id, "race text")
      end)

    assert {:ok, media, :created} = Task.await(media_task, 5_000)
    assert {:ok, %{sequence: 1}} = Task.await(text_task, 5_000)
    assert media.anchor_sequence in [0, 1]

    # anchor 0 means media's critical section won before text sequence 1.
    # anchor 1 means text sequence 1 was accepted before media's critical section.
    assert media.anchor_ordinal == 1
  end

  test "media is isolated by Conversation id", %{
    conversation_id: conversation_id,
    sender_id: sender_id
  } do
    message_id = Ecto.UUID.generate()

    assert {:ok, _item, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               "private",
               metadata("private")
             )

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(Ecto.UUID.generate(), message_id)
  end

  test "ConversationServer death removes every normal-media binary", %{
    conversation_id: conversation_id,
    sender_id: sender_id,
    owner_pid: owner_pid
  } do
    message_id = Ecto.UUID.generate()

    assert {:ok, _item, :created} =
             NormalMediaStore.put_media(
               conversation_id,
               sender_id,
               message_id,
               "temporary",
               metadata("temporary")
             )

    assert {:ok, "temporary", "image/jpeg"} =
             NormalMediaStore.fetch_media(conversation_id, message_id)

    Process.unlink(owner_pid)
    Process.exit(owner_pid, :kill)

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

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(2)
      eventually(fun, attempts - 1)
    end
  end
end
