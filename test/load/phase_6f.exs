#!/usr/bin/env elixir

# LOCAL DEVELOPMENT / TEST LOAD ONLY.
# Run with: MIX_ENV=test mix run test/load/phase_6f.exs

if Mix.env() != :test do
  raise "Phase 6F load harness refuses to run outside MIX_ENV=test"
end

alias Ecto.Adapters.SQL.Sandbox
alias StrangertalksNew.ConversationLifecycle.{ConversationServer, VoiceNoteStore}
alias StrangertalksNew.Matchmaking.MatchmakingEngine
alias StrangertalksNew.QueueEngine.QueueState
alias StrangertalksNew.{Conversation, Matching, RateLimiter, Repo}

defmodule Phase6F do
  @repo_event [:strangertalks_new, :repo, :query]

  def run do
    owner = Sandbox.start_owner!(Repo, shared: true)
    :telemetry.attach("phase-6f-repo", @repo_event, &__MODULE__.repo_event/4, self())

    try do
      IO.inspect(sample("LOCAL BASELINE"), label: "SAMPLE")
      Repo.query!("SELECT 1")
      IO.inspect(repo_summary(), label: "REPO BASELINE")
      fixtures = idle_ramp()
      light_activity(Enum.take(fixtures, 10))
      sustained_activity(Enum.take(fixtures, 10))
      hot_conversation(hd(fixtures))
      repeated_bursts(Enum.at(fixtures, 1))
      rate_limiter_cleanup()
      reconnect_catchup(Enum.take(fixtures, 10))
      voice_observation()
      stop_servers(fixtures)
      queue_load()
      IO.inspect(sample("LOCAL FINAL DRAIN"), label: "SAMPLE")
      IO.inspect(repo_summary(), label: "REPO")
    after
      :telemetry.detach("phase-6f-repo")
      Sandbox.stop_owner(owner)
    end

    IO.puts("PHASE_6F_COMPLETE")
  end

  def repo_event(_event, measurements, _metadata, owner) do
    send(owner, {:repo_timing, measurements})
  end

  defp idle_ramp do
    Enum.reduce([5, 10, 25, 50], [], fn target, fixtures ->
      fixtures = fixtures ++ Enum.map(1..(target - length(fixtures)), fn _ -> fixture() end)

      Enum.each(fixtures, fn fixture ->
        {:ok, _pid} = ConversationServer.ensure_started(fixture.conversation.conversation_id)
      end)

      IO.inspect(sample("IDLE #{target}"), label: "SAMPLE")
      fixtures
    end)
  end

  defp light_activity(fixtures) do
    latencies =
      Enum.flat_map(fixtures, fn fixture ->
        register(fixture)

        for index <- 1..5 do
          id = Ecto.UUID.generate()
          {send_us, {:ok, _}} = timed(fn -> append(fixture, id, "light-#{index}") end)
          {ack_us, {:ok, _}} = timed(fn -> ack(fixture, id) end)
          [send_us, ack_us]
        end
      end)
      |> List.flatten()

    IO.inspect(
      %{
        scenario: "DISTRIBUTED LIGHT",
        operations: length(latencies),
        latency_us: stats(latencies),
        runtime: sample(nil)
      },
      label: "RESULT"
    )
  end

  defp hot_conversation(fixture) do
    register(fixture)

    {results, latencies} =
      60
      |> race(fn index -> append(fixture, Ecto.UUID.generate(), "hot-#{index}") end)

    accepted =
      for {{:ok, result}, _latency} <- Enum.zip(results, latencies), do: result.message_id

    rejects =
      Enum.frequencies(
        for {{:error, reason}, _latency} <- Enum.zip(results, latencies), do: reason
      )

    state_at_capacity = state(fixture)
    drain_started = System.monotonic_time()
    Enum.each(accepted, fn id -> {:ok, _} = ack(fixture, id) end)

    drain_us =
      System.convert_time_unit(System.monotonic_time() - drain_started, :native, :microsecond)

    IO.inspect(
      %{
        scenario: "HOT STRICT CAPACITY",
        attempted: 60,
        accepted: length(accepted),
        rejected: rejects,
        latency_us: stats(latencies),
        pending_peak: state_at_capacity.pending_count,
        pending_bytes_peak: state_at_capacity.pending_bytes,
        pending_after_ack: state(fixture).pending_count,
        drain_us: drain_us
      },
      label: "RESULT"
    )

    strict_byte_capacity(fixture)

    pressure_policy(fixture, 101, :soft)
    pressure_policy(fixture, 501, :hard)
  end

  defp strict_byte_capacity(fixture) do
    content = :binary.copy("b", 16_384)

    {results, latencies} =
      17
      |> race(fn _index -> append(fixture, Ecto.UUID.generate(), content) end)

    accepted = for {:ok, result} <- results, do: result.message_id
    rejects = for {:error, reason} <- results, do: reason
    at_capacity = state(fixture)
    Enum.each(accepted, fn id -> {:ok, _} = ack(fixture, id) end)

    IO.inspect(
      %{
        scenario: "HOT STRICT BYTE CAPACITY",
        attempted: 17,
        accepted: length(accepted),
        rejected: Enum.frequencies(rejects),
        latency_us: stats(latencies),
        pending_peak: at_capacity.pending_count,
        pending_bytes_peak: at_capacity.pending_bytes,
        pending_after_ack: state(fixture).pending_count
      },
      label: "RESULT"
    )
  end

  defp sustained_activity(fixtures) do
    Enum.each(fixtures, &register/1)
    deadline = System.monotonic_time(:millisecond) + 5_000

    {attempted, accepted, delivered, rejects, latencies, mailbox_max} =
      sustained_loop(fixtures, deadline, 0, 0, 0, %{}, [], 0)

    IO.inspect(
      %{
        scenario: "SUSTAINED MESSAGE",
        duration_ms: 5_000,
        attempted: attempted,
        accepted: accepted,
        delivered: delivered,
        rejected: rejects,
        latency_us: stats(latencies),
        mailbox_max: mailbox_max,
        runtime: sample(nil)
      },
      label: "RESULT"
    )
  end

  defp sustained_loop(
         fixtures,
         deadline,
         attempted,
         accepted,
         delivered,
         rejects,
         latencies,
         mailbox_max
       ) do
    if System.monotonic_time(:millisecond) >= deadline do
      {attempted, accepted, delivered, rejects, latencies, mailbox_max}
    else
      {attempted, accepted, delivered, rejects, latencies} =
        Enum.reduce(fixtures, {attempted, accepted, delivered, rejects, latencies}, fn fixture,
                                                                                       {a, ok,
                                                                                        acked,
                                                                                        errors,
                                                                                        samples} ->
          id = Ecto.UUID.generate()
          {latency, result} = timed(fn -> append(fixture, id, "sustained") end)

          case result do
            {:ok, _} ->
              {:ok, _} = ack(fixture, id)
              {a + 1, ok + 1, acked + 1, errors, [latency | samples]}

            {:error, reason} ->
              {a + 1, ok, acked, Map.update(errors, reason, 1, &(&1 + 1)), [latency | samples]}
          end
        end)

      current_mailbox_max =
        fixtures
        |> Enum.map(fn fixture ->
          {:ok, pid} = ConversationServer.lookup(fixture.conversation.conversation_id)
          elem(Process.info(pid, :message_queue_len), 1)
        end)
        |> Enum.max(fn -> 0 end)

      receive do
      after
        100 ->
          sustained_loop(
            fixtures,
            deadline,
            attempted,
            accepted,
            delivered,
            rejects,
            latencies,
            max(mailbox_max, current_mailbox_max)
          )
      end
    end
  end

  defp pressure_policy(fixture, callers, kind) do
    {:ok, pid} = ConversationServer.lookup(fixture.conversation.conversation_id)
    :ok = :sys.suspend(pid)

    tasks = for _ <- 1..callers, do: Task.async(fn -> state(fixture) end)
    wait_for_mailbox(pid, callers, System.monotonic_time(:millisecond) + 2_000)

    result =
      case kind do
        :soft ->
          %{
            typing:
              ConversationServer.start_typing(fixture.conversation.conversation_id, fixture.a),
            sync:
              ConversationServer.get_messages_after(
                fixture.conversation.conversation_id,
                fixture.a,
                0
              )
          }

        :hard ->
          %{
            message: append(fixture, Ecto.UUID.generate(), "hard-guard"),
            voice: ConversationServer.admit_voice_note(fixture.conversation.conversation_id)
          }
      end

    mailbox = elem(Process.info(pid, :message_queue_len), 1)
    :ok = :sys.resume(pid)
    Enum.each(tasks, &Task.await(&1, :infinity))

    IO.inspect(
      %{
        scenario: "#{String.upcase(to_string(kind))} PRESSURE",
        held_callers: callers,
        mailbox: mailbox,
        admission: result,
        drained_mailbox: elem(Process.info(pid, :message_queue_len), 1)
      },
      label: "RESULT"
    )
  end

  defp repeated_bursts(fixture) do
    register(fixture)

    for cycle <- 1..5 do
      ids =
        for index <- 1..20 do
          id = Ecto.UUID.generate()
          {:ok, _} = append(fixture, id, "cycle-#{cycle}-#{index}")
          id
        end

      Enum.each(ids, fn id -> {:ok, _} = ack(fixture, id) end)
      IO.inspect(sample("BURST DRAIN #{cycle}"), label: "SAMPLE")
    end
  end

  defp rate_limiter_cleanup do
    before_count = RateLimiter.size()
    Enum.each(1..100, fn index -> :ok = RateLimiter.allow(:phase_6f, index, 2, 1) end)
    after_insert = RateLimiter.size()

    receive do
    after
      3 -> :ok
    end

    send(RateLimiter, :cleanup)
    _ = :sys.get_state(RateLimiter)

    IO.inspect(
      %{
        scenario: "RATE LIMITER CLEANUP",
        before: before_count,
        after_insert: after_insert,
        after_cleanup: RateLimiter.size()
      },
      label: "RESULT"
    )
  end

  defp reconnect_catchup(fixtures) do
    latencies =
      Enum.map(fixtures, fn fixture ->
        register(fixture)

        :ok =
          ConversationServer.unregister_channel(
            fixture.conversation.conversation_id,
            fixture.b,
            self()
          )

        ids =
          for index <- 1..5,
              do: elem(append(fixture, Ecto.UUID.generate(), "replay-#{index}"), 1).message_id

        {latency, {:ok, sync}} =
          timed(fn ->
            ConversationServer.sync_and_register_channel(
              fixture.conversation.conversation_id,
              fixture.b,
              self(),
              nil,
              0
            )
          end)

        assert_sequences(sync.messages, ids)
        Enum.each(ids, fn id -> {:ok, _} = ack(fixture, id) end)
        latency
      end)

    IO.inspect(
      %{
        scenario: "RECONNECT CATCHUP",
        conversations: length(fixtures),
        latency_us: stats(latencies),
        runtime: sample(nil)
      },
      label: "RESULT"
    )
  end

  defp voice_observation do
    conversation_id = Ecto.UUID.generate()
    before_memory = :erlang.memory(:binary)

    results =
      for index <- 1..4 do
        VoiceNoteStore.put(%{
          conversation_id: conversation_id,
          voice_note_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          recipient_id: Ecto.UUID.generate(),
          media_type: "audio/webm",
          duration_ms: 10,
          byte_size: 32,
          content_hash: "phase-6f-#{index}",
          binary: :binary.copy(<<index>>, 32),
          inserted_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })
      end

    occupied = VoiceNoteStore.inspect_metadata()
    :ok = VoiceNoteStore.delete_conversation(conversation_id)
    after_cleanup = VoiceNoteStore.inspect_metadata()
    global_results = global_voice_capacity()

    IO.inspect(
      %{
        scenario: "VOICE RESOURCE",
        results: Enum.map(results, &result_kind/1),
        global_results: Enum.map(global_results, &result_kind/1),
        added_bytes: occupied.total_bytes - after_cleanup.total_bytes,
        binary_memory_delta: :erlang.memory(:binary) - before_memory
      },
      label: "RESULT"
    )
  end

  defp global_voice_capacity do
    key = :voice_note_global_byte_limit
    previous = Application.get_env(:strangertalks_new, key)
    Application.put_env(:strangertalks_new, key, 64)

    try do
      {results, conversation_ids} =
        Enum.map_reduce(1..3, [], fn index, ids ->
          conversation_id = Ecto.UUID.generate()

          result =
            VoiceNoteStore.put(%{
              conversation_id: conversation_id,
              voice_note_id: Ecto.UUID.generate(),
              sender_id: Ecto.UUID.generate(),
              recipient_id: Ecto.UUID.generate(),
              media_type: "audio/webm",
              duration_ms: 10,
              byte_size: 32,
              content_hash: "phase-6f-global-#{index}",
              binary: :binary.copy(<<index>>, 32),
              inserted_at: DateTime.utc_now(),
              expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
            })

          {result, [conversation_id | ids]}
        end)

      Enum.each(conversation_ids, &VoiceNoteStore.delete_conversation/1)
      results
    after
      if is_nil(previous) do
        Application.delete_env(:strangertalks_new, key)
      else
        Application.put_env(:strangertalks_new, key, previous)
      end
    end
  end

  defp queue_load do
    _prior_repo_timings = repo_summary()
    Agent.update(QueueState, fn _ -> %{} end)

    participants =
      for _ <- 1..50 do
        {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
        participant
      end

    {_join_results, join_latencies} =
      race(50, fn index ->
        participant = Enum.at(participants, index - 1)
        MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)
      end)

    {match_us, {:ok, match_ids}} = timed(&MatchmakingEngine.evaluate_pending_matches/0)
    matches = Repo.aggregate(Matching, :count, :match_id)
    conversations = Repo.aggregate(Conversation, :count, :conversation_id)

    IO.inspect(
      %{
        scenario: "QUEUE MATCHMAKING",
        participants: 50,
        created_in_run: length(match_ids),
        durable_matches_in_transaction: matches,
        durable_conversations_in_transaction: conversations,
        join_latency_us: stats(join_latencies),
        evaluation_us: match_us,
        queue_remaining: map_size(Agent.get(QueueState, & &1)),
        runtime: sample(nil),
        repo: repo_summary()
      },
      label: "RESULT"
    )
  end

  defp fixture do
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

  defp register(fixture) do
    {:ok, _} = ConversationServer.ensure_started(fixture.conversation.conversation_id)

    :ok =
      ConversationServer.register_channel(fixture.conversation.conversation_id, fixture.a, self())

    :ok =
      ConversationServer.register_channel(fixture.conversation.conversation_id, fixture.b, self())
  end

  defp append(fixture, id, content),
    do:
      ConversationServer.append_message(
        fixture.conversation.conversation_id,
        fixture.a,
        id,
        content
      )

  defp ack(fixture, id),
    do:
      ConversationServer.acknowledge_message(fixture.conversation.conversation_id, fixture.b, id)

  defp state(fixture),
    do: elem(ConversationServer.inspect_state(fixture.conversation.conversation_id), 1)

  defp stop_servers(fixtures) do
    Enum.each(fixtures, fn fixture ->
      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        _ ->
          :ok
      end
    end)
  end

  defp sample(label) do
    servers =
      StrangertalksNew.ConversationDynamicSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

    memories = Enum.map(servers, fn pid -> elem(Process.info(pid, :memory), 1) end)
    mailboxes = Enum.map(servers, fn pid -> elem(Process.info(pid, :message_queue_len), 1) end)
    memory = Map.new(:erlang.memory())

    %{
      label: label,
      vm_total_bytes: memory.total,
      process_memory_bytes: memory.processes,
      ets_bytes: memory.ets,
      binary_bytes: memory.binary,
      atom_bytes: memory.atom,
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      run_queue: :erlang.statistics(:run_queue),
      conversation_servers: length(servers),
      conversation_memory_total: Enum.sum(memories),
      conversation_memory_average: average(memories),
      conversation_memory_max: Enum.max(memories, fn -> 0 end),
      mailbox_total: Enum.sum(mailboxes),
      mailbox_average: average(mailboxes),
      mailbox_max: Enum.max(mailboxes, fn -> 0 end),
      mailboxes_nonzero: Enum.count(mailboxes, &(&1 > 0)),
      queue_entries: map_size(Agent.get(QueueState, & &1)),
      rate_limiter_entries: RateLimiter.size(),
      voice_note_bytes: VoiceNoteStore.inspect_metadata().total_bytes
    }
  end

  defp race(count, operation) do
    parent = self()

    tasks =
      for index <- 1..count,
          do:
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> timed(fn -> operation.(index) end)
              end
            end)

    Enum.each(tasks, fn task ->
      receive do
        {:ready, pid} when pid == task.pid -> :ok
      end
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    {latencies, results} = tasks |> Enum.map(&Task.await(&1, :infinity)) |> Enum.unzip()
    {results, latencies}
  end

  defp timed(function) do
    started = System.monotonic_time()
    result = function.()
    {System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond), result}
  end

  defp stats([]), do: %{samples: 0, p50: 0, p95: 0, max: 0, average: 0}

  defp stats(values) do
    sorted = Enum.sort(values)

    %{
      samples: length(values),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      max: List.last(sorted),
      average: average(values)
    }
  end

  defp percentile(sorted, fraction),
    do: Enum.at(sorted, max(0, ceil(length(sorted) * fraction) - 1))

  defp average([]), do: 0
  defp average(values), do: div(Enum.sum(values), length(values))

  defp wait_for_mailbox(pid, target, deadline) do
    current = elem(Process.info(pid, :message_queue_len), 1)

    cond do
      current >= target ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "mailbox pressure did not reach target"

      true ->
        receive do
        after
          1 -> wait_for_mailbox(pid, target, deadline)
        end
    end
  end

  defp assert_sequences(messages, ids) do
    received = Enum.map(messages, & &1.message_id)

    unless Enum.take(received, -length(ids)) == ids,
      do: raise("replay sequence invariant failed")
  end

  defp result_kind({:ok, _, kind}), do: kind
  defp result_kind({:error, reason}), do: reason

  defp repo_summary do
    timings = drain_repo_timings([])
    query = Enum.map(timings, &native_us(Map.get(&1, :query_time, 0)))
    queue = Enum.map(timings, &native_us(Map.get(&1, :queue_time, 0)))

    total =
      Enum.map(timings, fn item ->
        native_us(
          Map.get(
            item,
            :total_time,
            Map.get(item, :query_time, 0) + Map.get(item, :queue_time, 0)
          )
        )
      end)

    %{
      samples: length(timings),
      query_time_us: stats(query),
      queue_time_us: stats(queue),
      total_time_us: stats(total)
    }
  end

  defp drain_repo_timings(acc) do
    receive do
      {:repo_timing, measurements} -> drain_repo_timings([measurements | acc])
    after
      0 -> acc
    end
  end

  defp native_us(value), do: System.convert_time_unit(value, :native, :microsecond)
end

Phase6F.run()
