defmodule StrangertalksNew.RecoveryRestartTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation

  alias StrangertalksNew.ConversationLifecycle.{
    ConversationServer,
    RecoverySweeper,
    VoiceNoteStore
  }

  alias StrangertalksNew.QueueEngine.{ParticipantConnectionTracker, QueueState}
  alias StrangertalksNew.{Matching, RateLimiter, Repo}

  test "ConversationServer crash creates one fresh epoch and concurrent recovery converges" do
    fixture = conversation_fixture()
    conversation_id = fixture.conversation.conversation_id
    {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, fixture.a, self())
    :ok = ConversationServer.register_channel(conversation_id, fixture.b, self())
    {:ok, before} = ConversationServer.inspect_state(conversation_id)
    durable_status = Repo.get!(Conversation, conversation_id).conversation_status
    redacted = ConversationServer.format_status(%{state: before, message: "synthetic-private"})
    assert redacted.state == :redacted
    assert redacted.message == :redacted

    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation_id,
               fixture.a,
               message_id,
               "synthetic"
             )

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    results =
      1..12
      |> Task.async_stream(fn _ -> ConversationServer.ensure_started(conversation_id) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [{:ok, replacement}] = Enum.uniq(results)
    refute replacement == old_pid
    assert {:ok, ^replacement} = ConversationServer.lookup(conversation_id)
    assert {:ok, after_crash} = ConversationServer.inspect_state(conversation_id)
    refute after_crash.epoch_id == before.epoch_id
    assert after_crash.pending_count == 0
    assert after_crash.recent_messages == []

    assert {:ok, sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               fixture.b,
               self(),
               before.epoch_id,
               1
             )

    assert sync.status == "epoch_changed"
    assert sync.messages == []
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert Repo.get!(Conversation, conversation_id).conversation_status == durable_status
  end

  test "terminal durable Conversation refuses runtime resurrection" do
    fixture = conversation_fixture()

    fixture.conversation
    |> Conversation.changeset(%{
      conversation_status: :ENDED,
      conversation_completed: true,
      ending_type: :NATURAL_END,
      ended_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert {:error, :terminal_conversation} =
             ConversationServer.ensure_started(fixture.conversation.conversation_id)

    assert {:error, :not_started} =
             ConversationServer.lookup(fixture.conversation.conversation_id)
  end

  test "same-epoch ambiguous send and ACK retries remain idempotent" do
    fixture = conversation_fixture()
    id = fixture.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(id)
    :ok = ConversationServer.register_channel(id, fixture.a, self())
    :ok = ConversationServer.register_channel(id, fixture.b, self())
    message_id = Ecto.UUID.generate()

    assert {:ok, first} =
             ConversationServer.append_message(id, fixture.a, message_id, "synthetic")

    assert {:ok, retry} =
             ConversationServer.append_message(id, fixture.a, message_id, "synthetic")

    assert first.sequence == retry.sequence
    assert {:ok, delivered} = ConversationServer.acknowledge_message(id, fixture.b, message_id)

    assert {:ok, duplicate_ack} =
             ConversationServer.acknowledge_message(id, fixture.b, message_id)

    assert delivered.status == "delivered"
    assert duplicate_ack.status == "delivered"
    assert {:ok, state} = ConversationServer.inspect_state(id)
    assert state.pending_count == 0
    assert map_size(state.completed) == 1
    assert state.next_sequence == 2
  end

  test "volatile supervised owners restart empty and accept new state" do
    participant_id = Ecto.UUID.generate()
    channel = spawn(fn -> receive do: (:stop -> :ok) end)
    :ok = ParticipantConnectionTracker.register(participant_id, channel)

    Agent.update(
      QueueState,
      &Map.put(&1, participant_id, %{
        door_selection: :EXPLORE,
        queue_attempt_id: Ecto.UUID.generate()
      })
    )

    :ok = RateLimiter.allow(:recovery_restart, participant_id, 1, 60_000)

    assert {:error, _retry_after} =
             RateLimiter.allow(:recovery_restart, participant_id, 1, 60_000)

    conversation_id = Ecto.UUID.generate()
    note = voice_note(conversation_id)
    assert {:ok, _, :inserted} = VoiceNoteStore.put(note)

    tracker = restart_named_child(ParticipantConnectionTracker)
    queue = restart_named_child(QueueState)
    limiter = restart_named_child(RateLimiter)
    voice = restart_named_child(VoiceNoteStore)

    assert is_pid(tracker) and is_pid(queue) and is_pid(limiter) and is_pid(voice)
    assert :sys.get_state(ParticipantConnectionTracker).participants == %{}
    assert Agent.get(QueueState, & &1) == %{}
    assert RateLimiter.size() == 0
    assert :ok = RateLimiter.allow(:recovery_restart, participant_id, 1, 60_000)
    assert VoiceNoteStore.inspect_metadata().total_bytes == 0

    assert {:error, :voice_note_unavailable} =
             VoiceNoteStore.fetch(conversation_id, note.voice_note_id, note.recipient_id)

    new_conv_id = Ecto.UUID.generate()
    assert {:ok, _, :inserted} = VoiceNoteStore.put(voice_note(new_conv_id))
    VoiceNoteStore.delete_conversation(new_conv_id)
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 0
    send(channel, :stop)
  end

  test "RecoverySweeper abandons durable ACTIVE Conversation when runtime is gone and nobody returns" do
    fixture = conversation_fixture()
    conversation_id = fixture.conversation.conversation_id

    fixture.conversation
    |> Conversation.changeset(%{
      conversation_status: :ACTIVE,
      created_at: DateTime.add(DateTime.utc_now(), -300, :second)
    })
    |> Repo.update!()

    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)

    RecoverySweeper.sweep_orphans()

    recovered = Repo.get!(Conversation, conversation_id)
    assert recovered.conversation_status == :ABANDONED
    assert recovered.ending_type == :TIMEOUT
    assert recovered.ended_at
    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
  end

  test "RecoverySweeper abandons durable PAUSED Conversation when runtime is gone and nobody returns" do
    fixture = conversation_fixture()
    conversation_id = fixture.conversation.conversation_id

    fixture.conversation
    |> Conversation.changeset(%{
      conversation_status: :PAUSED,
      created_at: DateTime.add(DateTime.utc_now(), -300, :second)
    })
    |> Repo.update!()

    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)

    RecoverySweeper.sweep_orphans()

    recovered = Repo.get!(Conversation, conversation_id)
    assert recovered.conversation_status == :ABANDONED
    assert recovered.ending_type == :TIMEOUT
    assert recovered.ended_at
    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
  end

  test "runtime restart racing orphan sweep always converges to one authority" do
    for _ <- 1..12 do
      fixture = conversation_fixture()
      conversation_id = fixture.conversation.conversation_id

      fixture.conversation
      |> Conversation.changeset(%{conversation_status: :ACTIVE})
      |> Repo.update!()

      sweep = Task.async(&RecoverySweeper.sweep_orphans/0)
      restart = Task.async(fn -> ConversationServer.ensure_started(conversation_id) end)

      assert :ok = Task.await(sweep, :infinity)
      restart_result = Task.await(restart, :infinity)
      persisted = Repo.get!(Conversation, conversation_id)

      case persisted.conversation_status do
        :ABANDONED ->
          assert persisted.ending_type == :TIMEOUT
          assert {:error, :not_started} = ConversationServer.lookup(conversation_id)

          assert restart_result in [{:error, :terminal_conversation}, {:error, :not_started}] or
                   match?({:ok, _pid}, restart_result)

        :ACTIVE ->
          assert {:ok, pid} = ConversationServer.lookup(conversation_id)
          assert Process.alive?(pid)

          assert {:ok, _terminal} =
                   ConversationServer.complete_conversation(conversation_id, fixture.a)

        other ->
          flunk("unexpected durable status after restart/sweep race: #{inspect(other)}")
      end
    end
  end

  test "RecoverySweeper and SessionReconciliation produce one orphan transition" do
    fixture = conversation_fixture()

    fixture.conversation
    |> Conversation.changeset(%{created_at: DateTime.add(DateTime.utc_now(), -300, :second)})
    |> Repo.update!()

    parent = self()
    handler_id = "phase-6g-orphan-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :conversation, :transitioned],
        fn _event, _measurements, metadata, receiver ->
          send(receiver, {:transitioned, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    tasks = [
      Task.async(&RecoverySweeper.sweep_orphans/0),
      Task.async(fn -> StrangertalksNew.SessionReconciliation.reconcile(fixture.a) end)
    ]

    Enum.each(tasks, &Task.await(&1, :infinity))

    assert Repo.get!(Conversation, fixture.conversation.conversation_id).conversation_status ==
             :ABANDONED

    transitions = collect_transitions([])

    assert Enum.count(transitions, fn metadata ->
             metadata.from_status == :PENDING and metadata.to_status == :ABANDONED
           end) == 1
  end

  defp restart_named_child(name) do
    old_pid = Process.whereis(name)
    monitor = Process.monitor(old_pid)
    assert :ok = Supervisor.terminate_child(StrangertalksNew.Supervisor, name)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :shutdown}
    assert {:ok, replacement} = Supervisor.restart_child(StrangertalksNew.Supervisor, name)
    refute replacement == old_pid
    assert Process.whereis(name) == replacement
    replacement
  end

  defp collect_transitions(acc) do
    receive do
      {:transitioned, metadata} -> collect_transitions([metadata | acc])
    after
      0 -> acc
    end
  end

  defp voice_note(conversation_id) do
    %{
      conversation_id: conversation_id,
      voice_note_id: Ecto.UUID.generate(),
      sender_id: Ecto.UUID.generate(),
      recipient_id: Ecto.UUID.generate(),
      media_type: "audio/webm",
      duration_ms: 10,
      byte_size: 1,
      content_hash: "synthetic",
      binary: <<1>>,
      inserted_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }
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
