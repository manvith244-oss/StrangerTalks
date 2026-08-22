defmodule StrangertalksNew.ConversationIcebreakerTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.IcebreakerCatalog

  setup do
    fixture = conversation_fixture("en")

    pid =
      start_supervised!(
        {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
      )

    Map.put(fixture, :pid, pid)
  end

  test "new runtime owns exactly one approved ACTIVE bridge shared by both JOIN projections",
       context do
    assert {:ok, state} = inspect_state(context)
    assert {:active, identity} = state.icebreaker
    assert String.starts_with?(identity, "en/")
    assert IcebreakerCatalog.approved?(identity)
    refute is_list(state.icebreaker)

    assert {:ok, join_a} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert {:ok, join_b} = join_runtime(context, context.participant_b, self(), nil, 0)
    assert join_a.icebreaker == %{status: "active", identity: identity}
    assert join_b.icebreaker == join_a.icebreaker
    assert Map.keys(join_a.icebreaker) |> Enum.sort() == [:identity, :status]
    refute Map.has_key?(join_a.icebreaker, :client_message_id)
    refute Map.has_key?(join_a.icebreaker, :sequence)
    refute Map.has_key?(join_a.icebreaker, :delivery_status)
  end

  test "catalog is bounded first-party en/te/hi authority and unknown identity cannot become canonical",
       context do
    identities = IcebreakerCatalog.identities()
    assert length(identities) == 21
    assert Enum.uniq(identities) == identities
    assert IcebreakerCatalog.languages() == ["en", "te", "hi"]

    for language <- IcebreakerCatalog.languages() do
      assert length(IcebreakerCatalog.identities(language)) == 7
      assert Enum.all?(IcebreakerCatalog.identities(language), &String.starts_with?(&1, "#{language}/"))
    end

    assert Enum.all?(
             identities,
             &match?(
               {:ok, %{language: language, text: text}}
               when language in ["en", "te", "hi"] and is_binary(text),
               IcebreakerCatalog.fetch(&1)
             )
           )

    assert {:error, :unknown_identity} = IcebreakerCatalog.fetch("<script>alert(1)</script>")
    assert {:error, :unknown_identity} = IcebreakerCatalog.fetch("https://example.invalid/bridge")
    assert {:ok, %{icebreaker: {:active, canonical}}} = inspect_state(context)
    assert canonical in identities
  end

  test "persisted Match language is the sole Conversation Start language authority", _context do
    for language <- ["en", "te", "hi"] do
      fixture = conversation_fixture(language)

      pid =
        start_supervised!(
          {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
        )

      assert {:ok, %{icebreaker: {:active, identity}}} =
               ConversationServer.inspect_state(fixture.conversation.conversation_id)

      assert String.starts_with?(identity, "#{language}/")
      assert {:ok, %{language: ^language, text: text}} = IcebreakerCatalog.fetch(identity)
      assert is_binary(text) and text != ""

      assert {:ok, joined} =
               ConversationServer.sync_and_register_channel(
                 fixture.conversation.conversation_id,
                 fixture.participant_a,
                 self(),
                 nil,
                 0
               )

      assert joined.icebreaker == %{status: "active", identity: identity}

      assert StrangertalksNew.Repo.get!(StrangertalksNew.Matching, fixture.match.match_id).conversation_language ==
               language

      assert :ok =
               stop_supervised({ConversationServer, fixture.conversation.conversation_id})

      refute Process.alive?(pid)
    end
  end

  test "missing persisted Match language fails Conversation Start closed with no English fallback",
       _context do
    fixture = conversation_fixture(nil)

    _pid =
      start_supervised!(
        {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
      )

    assert {:ok, %{icebreaker: :retired}} =
             ConversationServer.inspect_state(fixture.conversation.conversation_id)

    assert {:ok, joined} =
             ConversationServer.sync_and_register_channel(
               fixture.conversation.conversation_id,
               fixture.participant_a,
               self(),
               nil,
               0
             )

    assert joined.icebreaker == %{status: "retired"}
  end

  test "first canonical text retires once while preserving ordinary sequence and delivery",
       context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1, status: "sent"}} =
             append_text(context, context.participant_a, message_id, "Hello from the bridge")

    assert_retirement_once_per_registered_channel()
    assert {:ok, %{icebreaker: :retired, next_sequence: 2}} = inspect_state(context)
    assert {:ok, sync} = reconcile(context, context.participant_b, 0)
    assert sync.icebreaker == %{status: "retired"}
    assert [%{type: "text", sequence: 1, content: "Hello from the bridge"}] = sync.messages
  end

  test "first Reply-bearing canonical message retires without changing Reply semantics",
       context do
    target_id = Ecto.UUID.generate()
    target = delivered_reply_target(target_id, context.participant_b)

    :sys.replace_state(context.pid, fn state ->
      %{
        state
        | recent_messages: [target],
          next_sequence: 2,
          replay_bytes: byte_size(target.content)
      }
    end)

    reply_id = Ecto.UUID.generate()

    assert {:ok,
            %{
              sequence: 2,
              reply_to_client_message_id: ^target_id,
              reply_author_relation: "other_participant",
              reply_snippet: "Earlier canonical context"
            }} =
             ConversationServer.append_message(
               conversation_id(context),
               context.participant_a,
               reply_id,
               "A real reply",
               target_id
             )

    assert {:ok, %{icebreaker: :retired}} = inspect_state(context)
    assert {:ok, joined} = join_runtime(context, context.participant_b, self(), nil, 1)

    assert %{reply_to_client_message_id: ^target_id, content: "A real reply"} =
             List.last(joined.messages)
  end

  test "first expressive GIF or sticker retires while preserving its canonical media", context do
    assert {:ok, %{sequence: 1, expressive: %{id: "warm-wave"}}} =
             ConversationServer.append_expressive_message(
               conversation_id(context),
               context.participant_a,
               Ecto.UUID.generate(),
               "warm-wave"
             )

    assert {:ok, %{icebreaker: :retired}} = inspect_state(context)
    assert {:ok, sync} = reconcile(context, context.participant_b, 0)
    assert sync.icebreaker == %{status: "retired"}
    assert [%{type: "expressive", expressive: %{id: "warm-wave"}, sequence: 1}] = sync.messages
  end

  test "first voice note retires only after actual volatile acceptance succeeds", context do
    binary = <<"RIFF", 0, 0, 0, 0, "WAVEfmt ">>
    voice_note_id = Ecto.UUID.generate()

    attrs = %{
      voice_note_id: voice_note_id,
      media_type: "audio/wav",
      duration_ms: 1_200,
      byte_size: byte_size(binary),
      content_hash: :crypto.hash(:sha256, binary)
    }

    assert {:ok, %{voice_note_id: ^voice_note_id, sequence: 1, status: "sent_to_server"}} =
             ConversationServer.append_voice_note(
               conversation_id(context),
               context.participant_a,
               attrs,
               binary
             )

    assert {:ok, %{icebreaker: :retired}} = inspect_state(context)
    assert {:ok, sync} = reconcile(context, context.participant_b, 0)
    assert sync.icebreaker == %{status: "retired"}
    assert [%{type: "voice_note", voice_note_id: ^voice_note_id, sequence: 1}] = sync.messages
  end

  test "rejected expressive input cannot retire ACTIVE", context do
    assert {:error, :invalid_payload} =
             ConversationServer.append_expressive_message(
               conversation_id(context),
               context.participant_a,
               Ecto.UUID.generate(),
               "forged-media"
             )

    assert {:ok, %{icebreaker: {:active, _identity}}} = inspect_state(context)
  end

  test "JOIN reconnect and sync reconcile leave ACTIVE unchanged", context do
    assert {:ok, first} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert first.icebreaker.status == "active"

    assert {:ok, reconnect} =
             join_runtime(context, context.participant_a, self(), first.epoch_id, 0)

    assert reconnect.icebreaker == first.icebreaker
    assert {:ok, sync} = reconcile(context, context.participant_a, 0)
    assert sync.icebreaker == first.icebreaker
    assert {:ok, %{icebreaker: {:active, _identity}}} = inspect_state(context)
  end

  test "presence delivery progress and typing operational events do not retire ACTIVE", context do
    assert {:ok, joined} = join_runtime(context, context.participant_a, self(), nil, 0)

    assert {:ok, :applied} =
             ConversationServer.update_session_visibility(
               conversation_id(context),
               context.participant_a,
               self(),
               :hidden
             )

    assert {:ok, %{status: "no_op", highest_contiguous_sequence: 0}} =
             ConversationServer.report_delivery_progress(
               conversation_id(context),
               context.participant_a,
               self(),
               joined.epoch_id,
               0
             )

    assert :ok = ConversationServer.start_typing(conversation_id(context), context.participant_a)

    assert :ok = ConversationServer.stop_typing(conversation_id(context), context.participant_a)

    assert {:ok, %{icebreaker: {:active, _identity}}} = inspect_state(context)
  end

  test "reaction and pin attempts without a human timeline target do not retire ACTIVE",
       context do
    missing = Ecto.UUID.generate()

    assert {:error, :target_absent} =
             ConversationServer.mutate_reaction(
               conversation_id(context),
               context.participant_a,
               missing,
               "❤️",
               0
             )

    assert {:error, :target_absent} =
             ConversationServer.mutate_pin(
               conversation_id(context),
               context.participant_a,
               missing,
               true,
               0
             )

    assert {:ok, %{icebreaker: {:active, _identity}}} = inspect_state(context)
  end

  test "simultaneous first messages keep contiguous ordering and emit one retirement fanout",
       context do
    register_both(context)

    tasks = [
      Task.async(fn ->
        append_text(context, context.participant_a, Ecto.UUID.generate(), "first contender")
      end),
      Task.async(fn ->
        append_text(context, context.participant_b, Ecto.UUID.generate(), "second contender")
      end)
    ]

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &match?({:ok, %{status: "sent"}}, &1))
    assert Enum.sort(Enum.map(results, fn {:ok, result} -> result.sequence end)) == [1, 2]
    assert_retirement_once_per_registered_channel()
    assert {:ok, %{icebreaker: :retired, next_sequence: 3}} = inspect_state(context)
  end

  test "RETIRED is irreversible across later messages silence away and reconnect", context do
    assert {:ok, %{sequence: 1}} =
             append_text(context, context.participant_a, Ecto.UUID.generate(), "first")

    assert {:ok, %{sequence: 2}} =
             append_text(context, context.participant_b, Ecto.UUID.generate(), "later")

    assert {:ok, joined} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert joined.icebreaker == %{status: "retired"}

    assert {:ok, :applied} =
             ConversationServer.update_session_visibility(
               conversation_id(context),
               context.participant_a,
               self(),
               :hidden
             )

    assert {:ok, reconnect} =
             join_runtime(context, context.participant_a, self(), joined.epoch_id, 2)

    assert reconnect.icebreaker == %{status: "retired"}
    assert {:ok, %{icebreaker: :retired}} = inspect_state(context)
  end

  test "Conversation end destroys the runtime-owned Icebreaker with no history", context do
    register_both(context)
    monitor = Process.monitor(context.pid)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(
               conversation_id(context),
               context.participant_a
             )

    assert_receive {:DOWN, ^monitor, :process, pid, :normal} when pid == context.pid
  end

  defp conversation_id(context), do: context.conversation.conversation_id

  defp inspect_state(context), do: ConversationServer.inspect_state(conversation_id(context))

  defp append_text(context, participant_id, message_id, content) do
    ConversationServer.append_message(
      conversation_id(context),
      participant_id,
      message_id,
      content
    )
  end

  defp join_runtime(context, participant_id, channel_pid, epoch_id, sequence) do
    ConversationServer.sync_and_register_channel(
      conversation_id(context),
      participant_id,
      channel_pid,
      epoch_id,
      sequence
    )
  end

  defp reconcile(context, participant_id, sequence) do
    ConversationServer.get_messages_after(conversation_id(context), participant_id, sequence)
  end

  defp register_both(context) do
    assert :ok =
             ConversationServer.register_channel(
               conversation_id(context),
               context.participant_a,
               self()
             )

    assert :ok =
             ConversationServer.register_channel(
               conversation_id(context),
               context.participant_b,
               self()
             )
  end

  defp assert_retirement_once_per_registered_channel do
    assert_receive {:conversation_icebreaker, %{status: "retired"}}
    assert_receive {:conversation_icebreaker, %{status: "retired"}}
    refute_receive {:conversation_icebreaker, _payload}, 20
  end

  defp delivered_reply_target(message_id, sender_id) do
    %{
      type: :text,
      client_message_id: message_id,
      message_id: message_id,
      sender_id: sender_id,
      content: "Earlier canonical context",
      sequence: 1,
      sent_at: DateTime.utc_now(),
      delivery_status: :delivered,
      reply_to_client_message_id: nil,
      reply_author_relation: nil,
      reply_snippet: nil,
      reactions: %{},
      expressive: nil
    }
  end

  defp conversation_fixture(language \\ "en") do
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
