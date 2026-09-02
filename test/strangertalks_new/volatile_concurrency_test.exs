defmodule StrangertalksNew.VolatileConcurrencyTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ConversationLifecycle.VoiceNoteStore
  alias StrangertalksNew.QueueEngine.ParticipantConnectionTracker
  alias StrangertalksNew.RateLimiter

  test "RateLimiter atomically enforces a shared boundary and isolates actors" do
    actor = make_ref()
    results = race(8, fn -> RateLimiter.allow(:race_test, actor, 5, 60_000) end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, _retry_after}, &1)) == 3
    assert :ok = RateLimiter.allow(:race_test, make_ref(), 5, 60_000)
    assert :ok = RateLimiter.allow(:other_race_test, actor, 5, 60_000)
  end

  test "RateLimiter atomically replaces an expired fixed window" do
    bucket = :stale_window_test
    actor = make_ref()
    key = {bucket, :crypto.hash(:sha256, :erlang.term_to_binary(actor))}

    true = :ets.insert(RateLimiter, {key, 1, -2, -1})

    assert :ok = RateLimiter.allow(bucket, actor, 1, 60_000)
    assert {:error, retry_after_ms} = RateLimiter.allow(bucket, actor, 1, 60_000)
    assert retry_after_ms > 0
  end

  test "VoiceNoteStore serializes same-ID idempotency and per-conversation capacity" do
    conversation_id = Ecto.UUID.generate()
    note_id = Ecto.UUID.generate()
    note = note(conversation_id, note_id, "same")

    results = race(2, fn -> VoiceNoteStore.put(note) end)
    assert Enum.count(results, &match?({:ok, _, :inserted}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == 1

    assert {:error, :voice_note_id_conflict} =
             VoiceNoteStore.put(%{note | content_hash: "different"})

    capacity_results =
      race(
        for index <- 1..3 do
          candidate = note(conversation_id, Ecto.UUID.generate(), Integer.to_string(index))
          fn -> VoiceNoteStore.put(candidate) end
        end
      )

    assert Enum.count(capacity_results, &match?({:ok, _, :inserted}, &1)) == 2
    assert Enum.count(capacity_results, &(&1 == {:error, :voice_note_pending_limit})) == 1

    assert VoiceNoteStore.inspect_metadata().notes
           |> Enum.count(&(&1.conversation_id == conversation_id)) == 3

    VoiceNoteStore.delete_conversation(conversation_id)
    on_exit(fn -> VoiceNoteStore.delete_conversation(conversation_id) end)
  end

  test "ParticipantConnectionTracker keeps a new registration after an old channel exits" do
    participant_id = Ecto.UUID.generate()
    old_channel = spawn(fn -> receive do: (:stop -> :ok) end)
    new_channel = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok = ParticipantConnectionTracker.register(participant_id, old_channel)
    assert :ok = ParticipantConnectionTracker.register(participant_id, new_channel)

    state = :sys.get_state(ParticipantConnectionTracker)

    {old_ref, {^old_channel, ^participant_id}} =
      Enum.find(state.monitor_refs, fn {_ref, registration} ->
        registration == {old_channel, participant_id}
      end)

    send(ParticipantConnectionTracker, {:DOWN, old_ref, :process, old_channel, :killed})

    state = :sys.get_state(ParticipantConnectionTracker)
    assert state.participants[participant_id] == MapSet.new([new_channel])
    assert Enum.count(state.monitor_refs, fn {_ref, {_pid, id}} -> id == participant_id end) == 1

    Process.exit(old_channel, :kill)
    assert :ok = ParticipantConnectionTracker.unregister(participant_id, new_channel)
    Process.exit(new_channel, :kill)
    refute Map.has_key?(:sys.get_state(ParticipantConnectionTracker).participants, participant_id)
  end

  defp note(conversation_id, voice_note_id, content_hash) do
    now = DateTime.utc_now()

    %{
      conversation_id: conversation_id,
      voice_note_id: voice_note_id,
      sender_id: Ecto.UUID.generate(),
      recipient_id: Ecto.UUID.generate(),
      media_type: "audio/webm",
      duration_ms: 10,
      byte_size: 1,
      content_hash: content_hash,
      binary: <<0>>,
      inserted_at: now,
      expires_at: DateTime.add(now, 60, :second)
    }
  end

  defp race(count, operation), do: race(List.duplicate(operation, count))

  defp race(operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> operation.()
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      task_pid = task.pid
      assert_receive {:ready, ^task_pid}
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, :infinity))
  end
end
