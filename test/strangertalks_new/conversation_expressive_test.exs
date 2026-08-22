defmodule StrangertalksNew.ConversationExpressiveTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  setup do
    fixture = conversation_fixture()
    {:ok, pid} = ConversationServer.ensure_started(fixture.conversation.conversation_id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
    end)

    fixture
  end

  test "approved expressive identity uses catalog truth, normal sequence, replay, and bounded bytes",
       context do
    id = Ecto.UUID.generate()
    conversation_id = context.conversation.conversation_id

    assert {:ok, %{sequence: 1, expressive: expressive}} =
             ConversationServer.append_expressive_message(
               conversation_id,
               context.participant_a,
               id,
               "warm-wave"
             )

    assert expressive == %{
             id: "warm-wave",
             kind: "sticker",
             asset_path: "/assets/expressive/warm-wave.svg",
             label: "A friendly wave"
           }

    state = :sys.get_state(ConversationServer.lookup(conversation_id) |> elem(1))
    assert state.pending_bytes == byte_size("expressive:warm-wave")
    assert state.replay_bytes == byte_size("expressive:warm-wave")

    assert {:ok, sync} =
             ConversationServer.get_messages_after(conversation_id, context.participant_b, 0)

    assert [%{type: "expressive", client_message_id: ^id, sequence: 1, expressive: ^expressive}] =
             sync.messages

    assert {:ok, joined} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               context.participant_b,
               self(),
               nil,
               0
             )

    assert [%{type: "expressive", client_message_id: ^id, sequence: 1}] = joined.messages
  end

  test "unknown identity and forged metadata create no canonical message", context do
    conversation_id = context.conversation.conversation_id

    assert {:error, :invalid_payload} =
             ConversationServer.append_expressive_message(
               conversation_id,
               context.participant_a,
               Ecto.UUID.generate(),
               "https://evil.invalid/a.gif"
             )

    state = :sys.get_state(ConversationServer.lookup(conversation_id) |> elem(1))
    assert state.recent_messages == []
    assert state.pending_count == 0
  end

  test "accepted retry is generic idempotency and conflicting same-ID retry is rejected",
       context do
    conversation_id = context.conversation.conversation_id
    id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_expressive_message(
               conversation_id,
               context.participant_a,
               id,
               "happy-bounce"
             )

    assert {:ok, %{sequence: 1, duplicate: true}} =
             ConversationServer.append_expressive_message(
               conversation_id,
               context.participant_a,
               id,
               "happy-bounce"
             )

    assert {:error, :message_id_conflict} =
             ConversationServer.append_expressive_message(
               conversation_id,
               context.participant_a,
               id,
               "calm-breathe"
             )

    state = :sys.get_state(ConversationServer.lookup(conversation_id) |> elem(1))
    assert length(state.recent_messages) == 1
  end

  test "concurrent expressive messages share canonical sequence", context do
    conversation_id = context.conversation.conversation_id
    ids = for _ <- 1..8, do: Ecto.UUID.generate()

    results =
      Task.async_stream(
        ids,
        &ConversationServer.append_expressive_message(
          conversation_id,
          context.participant_a,
          &1,
          "bright-spark"
        ),
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.sort(for {:ok, {:ok, %{sequence: sequence}}} <- results, do: sequence) ==
             Enum.to_list(1..8)
  end

  defp conversation_fixture do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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

    %{
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
