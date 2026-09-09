defmodule StrangertalksNew.T02ConversationStartRestartControlsTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.IcebreakerCatalog
  alias StrangertalksNew.Matches

  test "rejected non-semantic input cannot become durable start truth across replacement" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id

    old_pid = start_runtime(conversation_id, :initial)

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

    old_pid = start_runtime(conversation_id, :initial)

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

  test "authoritative supported languages remain active while durable start truth is false" do
    for language <- ~w(en te hi) do
      fixture = conversation_fixture(language)
      conversation_id = fixture.conversation.conversation_id

      _pid = start_runtime(conversation_id, {:language, language})

      assert {:ok, %{icebreaker: {:active, identity}}} =
               ConversationServer.inspect_state(conversation_id)

      assert String.starts_with?(identity, language <> "/")
      assert IcebreakerCatalog.approved?(identity)
      assert Matches.get_match(fixture.match.match_id).conversation_started == false
    end
  end

  test "accepted expressive content establishes durable start truth before success" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id

    _pid = start_runtime(conversation_id, :expressive)

    assert Matches.get_match(fixture.match.match_id).conversation_started == false

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_expressive_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "warm-wave"
             )

    assert Matches.get_match(fixture.match.match_id).conversation_started == true
    assert {:ok, %{icebreaker: :retired}} = ConversationServer.inspect_state(conversation_id)
  end

  test "accepted voice content establishes durable start truth before success" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id
    binary = <<"RIFF", 0, 0, 0, 0, "WAVEfmt ">>
    voice_note_id = Ecto.UUID.generate()

    _pid = start_runtime(conversation_id, :voice)

    assert Matches.get_match(fixture.match.match_id).conversation_started == false

    assert {:ok, %{voice_note_id: ^voice_note_id, status: "sent_to_server"}} =
             ConversationServer.append_voice_note(
               conversation_id,
               fixture.a,
               %{
                 voice_note_id: voice_note_id,
                 media_type: "audio/wav",
                 duration_ms: 1_200,
                 byte_size: byte_size(binary),
                 content_hash: :crypto.hash(:sha256, binary)
               },
               binary
             )

    assert Matches.get_match(fixture.match.match_id).conversation_started == true
    assert {:ok, %{icebreaker: :retired}} = ConversationServer.inspect_state(conversation_id)
  end

  test "later accepted content skips durable Match start persistence after the first start" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id
    binary = <<"RIFF", 0, 0, 0, 0, "WAVEfmt ">>

    _pid = start_runtime(conversation_id, :one_time_persistence)

    assert {:ok, %{sequence: 1, status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "first accepted human message"
             )

    assert Matches.get_match(fixture.match.match_id).conversation_started == true

    capture = start_match_query_capture!()

    assert {:ok, %{sequence: 2, status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "later accepted human message"
             )

    assert {:ok, %{sequence: 3}} =
             ConversationServer.append_expressive_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "warm-wave"
             )

    voice_note_id = Ecto.UUID.generate()

    assert {:ok, %{voice_note_id: ^voice_note_id, status: "sent_to_server"}} =
             ConversationServer.append_voice_note(
               conversation_id,
               fixture.a,
               %{
                 voice_note_id: voice_note_id,
                 media_type: "audio/wav",
                 duration_ms: 1_200,
                 byte_size: byte_size(binary),
                 content_hash: :crypto.hash(:sha256, binary)
               },
               binary
             )

    assert stop_match_query_capture!(capture) == []
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
    start_runtime(conversation_id, :replacement)
  end

  defp start_match_query_capture! do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :repo, :query],
        fn _event, _measurements, metadata, target ->
          query = metadata[:query] |> to_string()

          if String.contains?(query, ~s("matches")) do
            send(target, {:match_query, query})
          end
        end,
        parent
      )

    handler_id
  end

  defp stop_match_query_capture!(handler_id) do
    :ok = :telemetry.detach(handler_id)
    collect_match_queries([])
  end

  defp collect_match_queries(acc) do
    receive do
      {:match_query, query} -> collect_match_queries([query | acc])
    after
      25 -> Enum.reverse(acc)
    end
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
