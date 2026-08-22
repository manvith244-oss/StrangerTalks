defmodule StrangertalksNew.CompanionConversationStartTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Companion.Context
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.IcebreakerCatalog

  setup do
    fixture = conversation_fixture("te")
    conversation_id = fixture.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, fixture.participant_a, self())
    :ok = ConversationServer.register_channel(conversation_id, fixture.participant_b, self())

    on_exit(fn ->
      case ConversationServer.lookup(conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    fixture
  end

  test "A01 projects the canonical language-qualified starter instead of inventing another one", context do
    assert {:ok, captured} =
             Context.capture(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "icebreaker",
               "tone" => "natural"
             })

    assert %{status: "active", identity: identity, text: text} = captured.conversation_start
    assert String.starts_with?(identity, "te/")
    assert {:ok, %{language: "te", text: ^text}} = IcebreakerCatalog.fetch(identity)

    public = Context.public_context(captured)
    assert public.conversation_start == captured.conversation_start
    refute Map.has_key?(public, :participant_id)
    refute Map.has_key?(public, :peer_id)
  end

  test "human conversation retires the canonical starter and A01 sees no parallel active starter", context do
    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               context.conversation.conversation_id,
               context.participant_a,
               Ecto.UUID.generate(),
               "హలో"
             )

    assert {:ok, captured} =
             Context.capture(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "continue",
               "tone" => "natural"
             })

    assert captured.conversation_start == nil
  end

  defp conversation_fixture(language) do
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
        conversation_language: language,
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
      match: match,
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
