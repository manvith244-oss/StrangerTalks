defmodule StrangertalksNew.C5PR229HostileTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matches
  alias StrangertalksNew.Repo

  test "C5 hostile: durable start mark is idempotent and preserves unrelated Match authority" do
    fixture = conversation_fixture("en")
    before = Matches.get_match(fixture.match.match_id)

    assert :ok = Matches.mark_conversation_started!(fixture.match.match_id)
    first = Matches.get_match(fixture.match.match_id)
    assert first.conversation_started == true

    assert :ok = Matches.mark_conversation_started!(fixture.match.match_id)
    second = Matches.get_match(fixture.match.match_id)
    assert second.conversation_started == true

    for field <- [
          :participant_a_id,
          :participant_b_id,
          :door_type,
          :participant_a_door_type,
          :participant_b_door_type,
          :conversation_language,
          :match_status,
          :match_strategy,
          :compatibility_score,
          :conversation_completed,
          :memory_created,
          :relationship_created,
          :reconnected_later,
          :report_generated,
          :block_generated,
          :safety_review_required,
          :learning_processed
        ] do
      assert Map.fetch!(second, field) == Map.fetch!(before, field),
             "mark_conversation_started!/1 changed unrelated field #{field}"
    end
  end

  test "C5 hostile: Match persistence failure cannot falsely retire starter across replacement" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id
    initial_pid = start_runtime(conversation_id, :c5_initial)

    assert {:ok, %{icebreaker: {:active, _identity}}} =
             ConversationServer.inspect_state(conversation_id)

    install_match_start_failure_trigger!()

    monitor = Process.monitor(initial_pid)

    result =
      ConversationServer.append_message(
        conversation_id,
        fixture.a,
        Ecto.UUID.generate(),
        "C5 persistence failure probe"
      )

    assert {:error, _reason} = result
    assert_receive {:DOWN, ^monitor, :process, ^initial_pid, _reason}, 1_000
    assert Matches.get_match(fixture.match.match_id).conversation_started == false

    remove_match_start_failure_trigger!()
    replacement_pid = start_runtime(conversation_id, :c5_replacement)
    refute replacement_pid == initial_pid

    assert {:ok, %{icebreaker: {:active, _identity}}} =
             ConversationServer.inspect_state(conversation_id)

    assert Matches.get_match(fixture.match.match_id).conversation_started == false
  end

  test "C5 hostile: durable text start dominates replacement and repeated channel sync without duplicate starter fanout" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id
    initial_pid = start_runtime(conversation_id, :c5_text_initial)

    assert {:ok, %{icebreaker: {:active, _identity}}} =
             ConversationServer.inspect_state(conversation_id)

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "C5 accepted text establishes durable start truth"
             )

    assert Matches.get_match(fixture.match.match_id).conversation_started == true
    assert {:ok, %{icebreaker: :retired}} = ConversationServer.inspect_state(conversation_id)

    drain_mailbox()
    replacement_pid = replace_runtime(conversation_id, initial_pid)
    refute replacement_pid == initial_pid

    assert {:ok, %{icebreaker: :retired}} = ConversationServer.inspect_state(conversation_id)

    assert {:ok, first_sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               fixture.a,
               self(),
               nil,
               0
             )

    assert first_sync.icebreaker == %{status: "retired"}
    drain_mailbox()

    assert {:ok, second_sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               fixture.a,
               self(),
               first_sync.epoch_id,
               0
             )

    assert second_sync.icebreaker == %{status: "retired"}
    refute_receive {:conversation_icebreaker, %{status: "active"}}, 50
  end

  defp install_match_start_failure_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION c5_fail_match_start() RETURNS trigger AS $$
    BEGIN
      IF NEW.conversation_started IS TRUE AND OLD.conversation_started IS FALSE THEN
        RAISE EXCEPTION 'C5 forced Conversation Start persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER c5_fail_match_start_trigger
    BEFORE UPDATE ON matches
    FOR EACH ROW EXECUTE FUNCTION c5_fail_match_start();
    """)
  end

  defp remove_match_start_failure_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS c5_fail_match_start_trigger ON matches")
    Repo.query!("DROP FUNCTION IF EXISTS c5_fail_match_start()")
  end

  defp drain_mailbox do
    receive do
      _message -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp start_runtime(conversation_id, generation) do
    start_supervised!(
      {ConversationServer, %{conversation_id: conversation_id}},
      id: {ConversationServer, conversation_id, generation},
      restart: :temporary
    )
  end

  defp replace_runtime(conversation_id, old_pid) do
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}
    start_runtime(conversation_id, :c5_replacement_runtime)
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