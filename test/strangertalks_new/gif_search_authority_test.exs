defmodule StrangertalksNew.GifSearchAuthorityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.GifSearchAuthority
  alias StrangertalksNew.Repo

  setup do
    fixture = conversation_fixture()
    {:ok, _pid} = ConversationServer.ensure_started(fixture.conversation.conversation_id)

    on_exit(fn ->
      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    fixture
  end

  test "current member captures live authority and terminal transition invalidates it", context do
    assert {:ok, authority} =
             GifSearchAuthority.capture(
               context.conversation.conversation_id,
               context.participant_a
             )

    assert is_binary(authority.epoch_id)

    assert {:ok, _ended} =
             context.conversation
             |> Ecto.Changeset.change(conversation_status: :ENDED)
             |> Repo.update()

    assert {:error, :conversation_unavailable} =
             GifSearchAuthority.capture(
               context.conversation.conversation_id,
               context.participant_a
             )

    assert {:error, :conversation_stale} = GifSearchAuthority.revalidate(authority)
  end

  test "outsider cannot capture provider-search authority", context do
    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})

    assert {:error, :not_conversation_member} =
             GifSearchAuthority.capture(
               context.conversation.conversation_id,
               outsider.participant_id
             )
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
        conversation_language: "en",
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
