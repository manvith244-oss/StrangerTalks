defmodule StrangertalksNew.Team3RecoveryCoordinationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, RecoverySweeper}
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.Repo

  test "orphan sweep becomes inert when recovery establishes runtime while participant boundary is held" do
    fixture = conversation_fixture()
    conversation_id = fixture.conversation.conversation_id

    fixture.conversation
    |> Conversation.changeset(%{conversation_status: :ACTIVE})
    |> Repo.update!()

    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)

    parent = self()

    {sweep, runtime_pid} =
      ParticipantActivityLock.with_participants([fixture.a, fixture.b], fn ->
        sweep =
          Task.async(fn ->
            send(parent, :sweep_started)
            RecoverySweeper.sweep_orphans()
          end)

        assert_receive :sweep_started

        {:ok, runtime_pid} = ConversationServer.ensure_started(conversation_id)
        assert {:ok, ^runtime_pid} = ConversationServer.lookup(conversation_id)

        {sweep, runtime_pid}
      end)

    assert :ok = Task.await(sweep, :infinity)
    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
    assert {:ok, ^runtime_pid} = ConversationServer.lookup(conversation_id)
    assert Process.alive?(runtime_pid)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, fixture.a)
  end

  test "terminal durable truth wins if recovery loses the orphan sweep" do
    fixture = conversation_fixture()
    conversation_id = fixture.conversation.conversation_id

    fixture.conversation
    |> Conversation.changeset(%{conversation_status: :PAUSED})
    |> Repo.update!()

    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
    assert :ok = RecoverySweeper.sweep_orphans()

    persisted = Repo.get!(Conversation, conversation_id)
    assert persisted.conversation_status == :ABANDONED
    assert persisted.ending_type == :TIMEOUT
    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)
    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
  end

  defp conversation_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, matching} =
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
        match_id: matching.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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

    %{conversation: conversation, a: a.participant_id, b: b.participant_id}
  end
end
