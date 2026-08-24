defmodule StrangertalksNew.ConversationIsolationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Repo

  test "terminal old Conversation cannot mutate a later Conversation for the same participants" do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})

    old_conversation =
      conversation_fixture(participant_a.participant_id, participant_b.participant_id)

    old_id = old_conversation.conversation_id
    {:ok, old_pid} = ConversationServer.ensure_started(old_id)
    :ok = ConversationServer.register_channel(old_id, participant_a.participant_id, self())
    :ok = ConversationServer.register_channel(old_id, participant_b.participant_id, self())

    old_message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               old_id,
               participant_a.participant_id,
               old_message_id,
               "old Conversation content"
             )

    old_monitor = Process.monitor(old_pid)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(old_id, participant_a.participant_id)

    assert_receive {:DOWN, ^old_monitor, :process, ^old_pid, :normal}
    assert Repo.get!(Conversation, old_id).conversation_status == :ENDED
    assert {:error, :not_started} = ConversationServer.lookup(old_id)

    new_conversation =
      conversation_fixture(participant_a.participant_id, participant_b.participant_id)

    new_id = new_conversation.conversation_id
    refute new_id == old_id

    {:ok, new_pid} = ConversationServer.ensure_started(new_id)
    :ok = ConversationServer.register_channel(new_id, participant_a.participant_id, self())
    :ok = ConversationServer.register_channel(new_id, participant_b.participant_id, self())

    new_message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               new_id,
               participant_b.participant_id,
               new_message_id,
               "new Conversation content"
             )

    assert {:ok, before_stale_old_events} = ConversationServer.inspect_state(new_id)

    stale_message_id = Ecto.UUID.generate()

    assert {:error, _reason} =
             ConversationServer.append_message(
               old_id,
               participant_a.participant_id,
               stale_message_id,
               "must never reach new Conversation"
             )

    assert {:error, _reason} =
             ConversationServer.acknowledge_message(
               old_id,
               participant_b.participant_id,
               old_message_id
             )

    assert {:error, _reason} =
             ConversationServer.start_typing(old_id, participant_a.participant_id)

    assert {:ok, after_stale_old_events} = ConversationServer.inspect_state(new_id)
    assert {:ok, ^new_pid} = ConversationServer.lookup(new_id)
    assert after_stale_old_events.epoch_id == before_stale_old_events.epoch_id
    assert after_stale_old_events.next_sequence == before_stale_old_events.next_sequence
    assert after_stale_old_events.pending == before_stale_old_events.pending
    assert after_stale_old_events.completed == before_stale_old_events.completed
    assert after_stale_old_events.delivery_progress == before_stale_old_events.delivery_progress
    assert Map.has_key?(after_stale_old_events.pending, new_message_id)
    refute Map.has_key?(after_stale_old_events.pending, stale_message_id)

    new_monitor = Process.monitor(new_pid)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(new_id, participant_b.participant_id)

    assert_receive {:DOWN, ^new_monitor, :process, ^new_pid, :normal}
    assert Repo.get!(Conversation, new_id).conversation_status == :ENDED
  end

  defp conversation_fixture(participant_a_id, participant_b_id) do
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a_id,
        participant_b_id: participant_b_id,
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
        match_id: matching.match_id,
        participant_a_id: participant_a_id,
        participant_b_id: participant_b_id,
        conversation_status: :PENDING,
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

    conversation
  end
end
