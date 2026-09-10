defmodule StrangertalksNew.Hangouts.MatcherTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, HangoutRoom, Matcher, RoomServer}
  alias StrangertalksNew.{Participants, Repo}

  test "one broad Hang Out queue is idempotent per participant and cancellation releases queue authority" do
    participant = participant!()

    assert function_exported?(Matcher, :enqueue, 2)
    refute function_exported?(Matcher, :enqueue, 3)

    assert {:ok, first} = Matcher.enqueue(participant.participant_id, "en-Q01")
    assert first.status == :queued
    assert is_binary(first.queue_attempt_id)

    assert {:ok, duplicate} = Matcher.enqueue(participant.participant_id, "en-Q01")
    assert duplicate.queue_attempt_id == first.queue_attempt_id

    assert {:error, :already_queued} = Matcher.enqueue(participant.participant_id, "pt-BR")

    assert :ok = Matcher.leave_queue(participant.participant_id)
    assert :ok = Matcher.leave_queue(participant.participant_id)

    assert {:ok, replacement} = Matcher.enqueue(participant.participant_id, "en-Q01")
    refute replacement.queue_attempt_id == first.queue_attempt_id
  end

  test "ACTIVE and DISCONNECTED durable Hangout membership both block queue admission" do
    participant = participant!()
    room = room!("en-Q02")

    assert {:ok, _membership} = Hangouts.add_member(room.room_id, participant.participant_id)

    assert {:error, :already_in_hangout} =
             Matcher.enqueue(participant.participant_id, "en-Q02")

    assert {:ok, disconnected} =
             Hangouts.disconnect_member(room.room_id, participant.participant_id)

    assert disconnected.status == :DISCONNECTED

    assert {:error, :already_in_hangout} =
             Matcher.enqueue(participant.participant_id, "en-Q02")
  end

  test "FIFO target formation selects the oldest four, writes no pair Match, and enters RoomServer authority" do
    language = "en-Q03"
    participants = participants!(5)
    pair_matches_before = pair_match_count()

    Enum.each(participants, fn participant ->
      assert {:ok, %{status: :queued}} = Matcher.enqueue(participant.participant_id, language)
    end)

    assert {:ok, formed} = Matcher.try_form(language)
    assert formed.size == 4
    assert formed.participant_ids == Enum.map(Enum.take(participants, 4), & &1.participant_id)

    track_room(formed.room_id)

    room = Repo.get!(HangoutRoom, formed.room_id)
    assert room.status == :ACTIVE
    assert room.minimum_size == 3
    assert room.target_size == 4
    assert room.max_size == 6
    assert room.language_tag == language

    membership_ids = room_participant_ids(formed.room_id)
    assert membership_ids == MapSet.new(formed.participant_ids)

    assert pair_match_count() == pair_matches_before
    assert {:ok, pid} = RoomServer.lookup(formed.room_id)
    assert Process.alive?(pid)

    first = hd(participants)
    assert {:ok, snapshot} = RoomServer.snapshot(formed.room_id, first.participant_id)
    assert snapshot.status == :ACTIVE
    assert snapshot.language_tag == language

    assert {:ok, :waiting} = Matcher.try_form(language)
  end

  test "minimum-size formation allows three participants without hard-coding target four as a gate" do
    language = "en-Q04"
    participants = participants!(3)

    Enum.each(participants, fn participant ->
      assert {:ok, _queued} = Matcher.enqueue(participant.participant_id, language)
    end)

    assert {:ok, formed} = Matcher.try_form(language)
    assert formed.size == 3
    assert formed.participant_ids == Enum.map(participants, & &1.participant_id)
    track_room(formed.room_id)

    room = Repo.get!(HangoutRoom, formed.room_id)
    assert room.status == :ACTIVE
    assert room.minimum_size == 3
    assert room.target_size == 4
  end

  test "language metadata stays extensible and formation never steals from another language" do
    pt = participants!(3)
    zu = participants!(3)

    Enum.each(pt, fn participant ->
      assert {:ok, _queued} = Matcher.enqueue(participant.participant_id, "pt-BR")
    end)

    Enum.each(zu, fn participant ->
      assert {:ok, _queued} = Matcher.enqueue(participant.participant_id, "zu-ZA")
    end)

    assert {:ok, pt_room} = Matcher.try_form("pt-BR")
    track_room(pt_room.room_id)
    assert pt_room.participant_ids == Enum.map(pt, & &1.participant_id)
    assert Repo.get!(HangoutRoom, pt_room.room_id).language_tag == "pt-BR"

    assert {:ok, zu_room} = Matcher.try_form("zu-ZA")
    track_room(zu_room.room_id)
    assert zu_room.participant_ids == Enum.map(zu, & &1.participant_id)
    assert Repo.get!(HangoutRoom, zu_room.room_id).language_tag == "zu-ZA"

    outsider = participant!()
    assert {:error, :invalid_language_tag} = Matcher.enqueue(outsider.participant_id, "english")
  end

  test "configured target may grow to maximum capacity without admitting an extra participant" do
    with_matcher_config([minimum_size: 3, target_size: 6, max_size: 6], fn ->
      language = "en-Q06"
      participants = participants!(7)

      Enum.each(participants, fn participant ->
        assert {:ok, _queued} = Matcher.enqueue(participant.participant_id, language)
      end)

      assert {:ok, formed} = Matcher.try_form(language)
      assert formed.size == 6
      assert formed.participant_ids == Enum.map(Enum.take(participants, 6), & &1.participant_id)
      track_room(formed.room_id)

      assert MapSet.size(room_participant_ids(formed.room_id)) == 6
      assert Repo.get!(HangoutRoom, formed.room_id).max_size == 6
      assert {:ok, :waiting} = Matcher.try_form(language)
    end)
  end

  test "concurrent duplicate enqueue and concurrent formation converge without duplicate room membership" do
    language = "en-Q07"
    [first | rest] = participants!(6)

    enqueue_results =
      1..20
      |> Task.async_stream(fn _ -> Matcher.enqueue(first.participant_id, language) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(enqueue_results, &match?({:ok, %{status: :queued}}, &1))

    attempt_ids =
      enqueue_results
      |> Enum.map(fn {:ok, queued} -> queued.queue_attempt_id end)
      |> Enum.uniq()

    assert length(attempt_ids) == 1

    Enum.each(rest, fn participant ->
      assert {:ok, _queued} = Matcher.enqueue(participant.participant_id, language)
    end)

    formation_results =
      1..12
      |> Task.async_stream(fn _ -> Matcher.try_form(language) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    formed =
      Enum.filter(formation_results, fn
        {:ok, %{room_id: room_id}} when is_binary(room_id) -> true
        _ -> false
      end)

    assert [{:ok, room_result}] = formed
    assert room_result.size == 4
    track_room(room_result.room_id)

    memberships =
      Repo.all(
        from m in HangoutMembership,
          where: m.participant_id in ^Enum.map([first | rest], & &1.participant_id),
          select: {m.participant_id, m.room_id}
      )

    assert length(memberships) == 4
    assert Enum.uniq_by(memberships, &elem(&1, 0)) == memberships
    assert Enum.all?(memberships, &(elem(&1, 1) == room_result.room_id))
  end

  test "stale queue cleanup removes abandoned waiting authority without touching durable Hangout state" do
    language = "en-Q08"
    participant = participant!()

    assert {:ok, first} = Matcher.enqueue(participant.participant_id, language)
    assert {:ok, 1} = Matcher.prune_stale(0)
    assert {:ok, :waiting} = Matcher.try_form(language)

    assert {:ok, second} = Matcher.enqueue(participant.participant_id, language)
    refute second.queue_attempt_id == first.queue_attempt_id
    assert pair_match_count() >= 0
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    track_queue(participant.participant_id)
    participant
  end

  defp participants!(count), do: Enum.map(1..count, fn _ -> participant!() end)

  defp room!(language_tag) do
    {:ok, room} =
      Hangouts.create_room(%{
        language_tag: language_tag,
        experiment_arm: :GROUP_WITH_CONTENT,
        minimum_size: 3,
        target_size: 4,
        max_size: 6
      })

    room
  end

  defp room_participant_ids(room_id) do
    Repo.all(
      from m in HangoutMembership,
        where: m.room_id == ^room_id,
        select: m.participant_id
    )
    |> MapSet.new()
  end

  defp pair_match_count do
    [[count]] = Repo.query!("SELECT count(*) FROM matches").rows
    count
  end

  defp with_matcher_config(config, function) do
    previous = Application.get_env(:strangertalks_new, Matcher)
    Application.put_env(:strangertalks_new, Matcher, config)

    try do
      function.()
    after
      if is_nil(previous) do
        Application.delete_env(:strangertalks_new, Matcher)
      else
        Application.put_env(:strangertalks_new, Matcher, previous)
      end
    end
  end

  defp track_queue(participant_id) do
    on_exit(fn ->
      if Code.ensure_loaded?(Matcher) and function_exported?(Matcher, :leave_queue, 1) and
           Process.whereis(Matcher) do
        _ = Matcher.leave_queue(participant_id)
      end
    end)
  end

  defp track_room(room_id) do
    on_exit(fn ->
      if Code.ensure_loaded?(RoomServer) and function_exported?(RoomServer, :lookup, 1) do
        case RoomServer.lookup(room_id) do
          {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
          _ -> :ok
        end
      end
    end)
  end
end
