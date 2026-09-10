defmodule StrangertalksNew.Hangouts.DurableInteractionsContractTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.RoomServer
  alias StrangertalksNew.{Participants, Repo}

  @durable_tables ~w(
    hangout_content_items
    hangout_room_content
    hangout_reactions
    hangout_skip_votes
  )

  test "approved Hangouts durable interaction tables exist" do
    for table <- @durable_tables do
      [[exists]] = Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["public.#{table}"]).rows
      assert exists, "expected public.#{table} to exist"
    end
  end

  test "RoomServer restart reconstructs reaction and skip-vote progress from durable truth" do
    {room, [first, second | _]} = active_room!(3)
    assert {:ok, pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, %{counts: %{"laugh" => 1}}} =
             RoomServer.add_reaction(
               room.room_id,
               first.participant_id,
               current.sequence,
               "laugh"
             )

    assert {:ok, %{advanced: false, votes: 1, required_votes: 2}} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert {:ok, replacement} = RoomServer.ensure_started(room.room_id)
    refute replacement == pid

    assert {:ok, rebuilt_content} = RoomServer.current_content(room.room_id)
    assert rebuilt_content == current

    assert {:ok, rebuilt_reaction} =
             RoomServer.add_reaction(
               room.room_id,
               second.participant_id,
               current.sequence,
               "fire"
             )

    assert rebuilt_reaction.counts == %{"fire" => 1, "laugh" => 1}

    assert {:ok, rebuilt_skip} =
             RoomServer.vote_skip(room.room_id, second.participant_id, current.sequence)

    assert rebuilt_skip.advanced == true
    assert rebuilt_skip.previous_content_sequence == current.sequence
    assert rebuilt_skip.content.sequence == current.sequence + 1
  end

  test "authoritative content sequences are recorded exactly once and catalogue truth is durable" do
    {room, [_first | _]} = active_room!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert room_content_count(room.room_id, current.sequence) == 1
    assert durable_content_item?(current.content.id)

    assert {:ok, next} = RoomServer.advance_content(room.room_id)
    assert next.sequence == current.sequence + 1
    assert room_content_count(room.room_id, current.sequence) == 1
    assert room_content_count(room.room_id, next.sequence) == 1
    assert durable_content_item?(next.content.id)
  end

  test "GROUP_NO_CONTENT creates no durable room-content interaction state" do
    {room, _participants} = active_room!(3, :GROUP_NO_CONTENT)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, nil} = RoomServer.current_content(room.room_id)

    assert Repo.query!(
             "SELECT count(*) FROM hangout_room_content WHERE room_id = $1::uuid",
             [room.room_id]
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM hangout_reactions WHERE room_id = $1::uuid",
             [room.room_id]
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM hangout_skip_votes WHERE room_id = $1::uuid",
             [room.room_id]
           ).rows == [[0]]
  end

  defp active_room!(count, experiment_arm \\ :GROUP_WITH_CONTENT) do
    participants = for _ <- 1..count, do: participant!()

    {:ok, %{room: room}} =
      Hangouts.create_formed_room(
        Enum.map(participants, & &1.participant_id),
        %{
          language_tag: "en",
          experiment_arm: experiment_arm,
          minimum_size: min(3, count),
          target_size: max(4, count),
          max_size: max(6, count)
        }
      )

    track_room(room.room_id)
    {room, participants}
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp room_content_count(room_id, sequence) do
    Repo.query!(
      "SELECT count(*) FROM hangout_room_content WHERE room_id = $1::uuid AND sequence = $2",
      [room_id, sequence]
    ).rows
    |> hd()
    |> hd()
  end

  defp durable_content_item?(content_id) do
    Repo.query!(
      """
      SELECT count(*) = 1
      FROM hangout_content_items
      WHERE content_id = $1
        AND source = 'FIRST_PARTY'
        AND safety_status = 'APPROVED'
        AND publication_status = 'ACTIVE'
      """,
      [content_id]
    ).rows == [[true]]
  end

  defp track_room(room_id) do
    on_exit(fn ->
      case RoomServer.lookup(room_id) do
        {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
        _ -> :ok
      end
    end)
  end
end
