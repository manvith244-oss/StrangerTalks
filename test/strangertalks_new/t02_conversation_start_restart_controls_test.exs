defmodule StrangertalksNew.T02ConversationStartRestartControlsTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.IcebreakerCatalog
  alias StrangertalksNew.Matches

  test "rejected non-semantic input cannot become durable start truth across replacement" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id

    {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)
    cleanup(conversation_id)

    assert {:ok, %{icebreaker: {:active, identity}}} =
             ConversationServer.inspect_state(conversation_id)

    assert IcebreakerCatalog.approved?(identity)
    assert Matches.get_match(fixture.match.match_id).conversation_started == false

    assert {:error, :invalid_payload} =
             ConversationServer.append_expressive_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "forged-media"
             )

    assert Matches.get_match(fixture.match.match_id).conversation_started == false
    assert {:ok, %{icebreaker: {:active, ^identity}}} =
             ConversationServer.inspect_state(conversation_id)

    replacement_pid = replace_runtime(conversation_id, old_pid)
    refute replacement_pid == old_pid

    assert {:ok, %{icebreaker: {:active, ^identity}}} =
             ConversationServer.inspect_state(conversation_id)

    assert Matches.get_match(fixture.match.match_id).conversation_started == false
  end

  test "missing language stays fail-closed across real replacement without inventing a starter" do
    fixture = conversation_fixture(nil)
    conversation_id = fixture.conversation.conversation_id

    {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)
    cleanup(conversation_id)

    assert {:ok, %{icebreaker: :retired}} = ConversationServer.inspect_state(conversation_id)
    assert Matches.get_match(fixture.match.match_id).conversation_started == false

    replacement_pid = replace_runtime(conversation_id, old_pid)
    refute replacement_pid == old_pid

    assert {:ok, %{icebreaker: :retired}} = ConversationServer.inspect_state(conversation_id)

    assert {:ok, sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               fixture.a,
               self(),
               nil,
               0
             )

    assert sync.icebreaker == %{status: "retired"}
    assert Matches.get_match(fixture.match.match_id).conversation_started == false
  end

  defp replace_runtime(conversation_id, old_pid) do
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}
    assert {:ok, replacement_pid} = ConversationServer.ensure_started(conversation_id)
    replacement_pid
  end

  defp cleanup(conversation_id) do
    on_exit(fn ->
      case ConversationServer.lookup(conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)
  end

  defp conversation_fixture(language) do
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

    %{conversation: conversation, match: matching, a: a.participant_id, b: b.participant_id}
  end
end
