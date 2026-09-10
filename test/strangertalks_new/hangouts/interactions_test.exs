defmodule StrangertalksNew.Hangouts.InteractionsTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, RoomServer}
  alias StrangertalksNew.{Participants, Repo}

  @pubsub StrangertalksNew.PubSub

  test "ACTIVE member reaction is private-safe, idempotent, and replaceable" do
    {room, [first | participants]} = active_room!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert :ok = Phoenix.PubSub.subscribe(@pubsub, topic(room.room_id))
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, first_result} =
             RoomServer.add_reaction(
               room.room_id,
               first.participant_id,
               current.sequence,
               "laugh"
             )

    assert first_result.content_sequence == current.sequence
    assert first_result.reaction == "laugh"
    assert first_result.counts == %{"laugh" => 1}
    assert Map.keys(first_result.actor) |> Enum.sort() == [:emoji, :label, :slot]
    assert_receive {:hangout_event, "reaction:updated", ^first_result}

    assert {:ok, duplicate} =
             RoomServer.add_reaction(
               room.room_id,
               first.participant_id,
               current.sequence,
               "laugh"
             )

    assert duplicate == first_result
    refute_receive {:hangout_event, "reaction:updated", _payload}, 50

    assert {:ok, replacement} =
             RoomServer.add_reaction(
               room.room_id,
               first.participant_id,
               current.sequence,
               "fire"
             )

    assert replacement.reaction == "fire"
    assert replacement.counts == %{"fire" => 1}
    assert_receive {:hangout_event, "reaction:updated", ^replacement}

    encoded = inspect(replacement)
    refute encoded =~ first.participant_id

    for participant <- participants do
      refute encoded =~ participant.participant_id
    end

    for membership <- memberships(room.room_id) do
      refute encoded =~ membership.membership_id
    end
  end

  test "reaction rejects unauthorized, stale, invalid, terminal, and no-content intents" do
    {room, [active, left, removed]} = active_room!(3)
    outsider = participant!()
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:error, :membership_not_found} =
             RoomServer.add_reaction(
               room.room_id,
               outsider.participant_id,
               current.sequence,
               "laugh"
             )

    assert {:error, :invalid_reaction} =
             RoomServer.add_reaction(
               room.room_id,
               active.participant_id,
               current.sequence,
               "not-a-reaction"
             )

    assert {:error, :stale_content} =
             RoomServer.add_reaction(
               room.room_id,
               active.participant_id,
               current.sequence - 1,
               "laugh"
             )

    assert {:ok, _membership} = Hangouts.leave_room(room.room_id, left.participant_id)
    mark_removed!(room.room_id, removed.participant_id)

    assert {:error, :membership_not_active} =
             RoomServer.add_reaction(
               room.room_id,
               left.participant_id,
               current.sequence,
               "laugh"
             )

    assert {:error, :membership_not_active} =
             RoomServer.add_reaction(
               room.room_id,
               removed.participant_id,
               current.sequence,
               "laugh"
             )

    {control, [control_member | _]} = active_room!(3, :GROUP_NO_CONTENT)
    assert {:ok, _pid} = RoomServer.ensure_started(control.room_id)

    assert {:error, :content_disabled} =
             RoomServer.add_reaction(control.room_id, control_member.participant_id, 0, "laugh")

    {terminal, [terminal_member | _]} = active_room!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(terminal.room_id)
    assert {:ok, terminal_content} = RoomServer.current_content(terminal.room_id)
    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(terminal.room_id)

    assert {:error, :terminal_room} =
             RoomServer.add_reaction(
               terminal.room_id,
               terminal_member.participant_id,
               terminal_content.sequence,
               "laugh"
             )
  end

  test "skip vote is one per ACTIVE member and strict majority advances once" do
    {room, [first, second, third, _fourth]} = active_room!(4)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, first_vote} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    assert first_vote == %{
             advanced: false,
             content_sequence: current.sequence,
             required_votes: 3,
             votes: 1
           }

    assert {:ok, duplicate} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    assert duplicate == first_vote

    assert {:ok, second_vote} =
             RoomServer.vote_skip(room.room_id, second.participant_id, current.sequence)

    assert second_vote.advanced == false
    assert second_vote.votes == 2
    assert second_vote.required_votes == 3
    assert {:ok, unchanged} = RoomServer.current_content(room.room_id)
    assert unchanged.sequence == current.sequence

    assert {:ok, final_vote} =
             RoomServer.vote_skip(room.room_id, third.participant_id, current.sequence)

    assert final_vote.advanced == true
    assert final_vote.previous_content_sequence == current.sequence
    assert final_vote.content.sequence == current.sequence + 1

    assert {:ok, advanced} = RoomServer.current_content(room.room_id)
    assert advanced.sequence == current.sequence + 1
  end

  test "DISCONNECTED members are excluded from the live skip quorum" do
    {room, [first, second, _third, disconnected]} = active_room!(4)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, %{advanced: false, required_votes: 3, votes: 1}} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    assert {:ok, _snapshot} = RoomServer.disconnect(room.room_id, disconnected.participant_id)

    assert {:ok, advanced} =
             RoomServer.vote_skip(room.room_id, second.participant_id, current.sequence)

    assert advanced.advanced == true
    assert advanced.previous_content_sequence == current.sequence
    assert advanced.content.sequence == current.sequence + 1
  end

  test "LEFT and REMOVED members neither vote nor inflate the quorum denominator" do
    {room, [first, second, _third, left, removed]} = active_room!(5)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, _membership} = Hangouts.leave_room(room.room_id, left.participant_id)
    mark_removed!(room.room_id, removed.participant_id)

    assert {:error, :membership_not_active} =
             RoomServer.vote_skip(room.room_id, left.participant_id, current.sequence)

    assert {:error, :membership_not_active} =
             RoomServer.vote_skip(room.room_id, removed.participant_id, current.sequence)

    assert {:ok, %{advanced: false, required_votes: 2, votes: 1}} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    assert {:ok, advanced} =
             RoomServer.vote_skip(room.room_id, second.participant_id, current.sequence)

    assert advanced.advanced == true
    assert advanced.content.sequence == current.sequence + 1
  end

  test "concurrent final skip votes cannot double-advance and delayed old votes are stale" do
    {room, [first, second, third, fourth]} = active_room!(4)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, %{advanced: false}} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    assert {:ok, %{advanced: false}} =
             RoomServer.vote_skip(room.room_id, second.participant_id, current.sequence)

    results =
      [third, fourth]
      |> Task.async_stream(
        fn participant ->
          RoomServer.vote_skip(room.room_id, participant.participant_id, current.sequence)
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{advanced: true}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :stale_content}, &1)) == 1

    assert {:ok, after_concurrency} = RoomServer.current_content(room.room_id)
    assert after_concurrency.sequence == current.sequence + 1

    assert {:error, :stale_content} =
             RoomServer.vote_skip(room.room_id, fourth.participant_id, current.sequence)
  end

  test "advancing content clears reactions and skip voters from the previous sequence" do
    {room, [first, second, third]} = active_room!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    assert {:ok, %{counts: %{"laugh" => 1}}} =
             RoomServer.add_reaction(
               room.room_id,
               first.participant_id,
               current.sequence,
               "laugh"
             )

    assert {:ok, %{counts: reaction_counts}} =
             RoomServer.add_reaction(
               room.room_id,
               second.participant_id,
               current.sequence,
               "fire"
             )

    assert reaction_counts == %{"fire" => 1, "laugh" => 1}

    assert {:ok, %{advanced: false, votes: 1}} =
             RoomServer.vote_skip(room.room_id, first.participant_id, current.sequence)

    assert {:ok, %{advanced: true, content: next_content}} =
             RoomServer.vote_skip(room.room_id, second.participant_id, current.sequence)

    assert next_content.sequence == current.sequence + 1

    assert {:ok, next_reaction} =
             RoomServer.add_reaction(
               room.room_id,
               third.participant_id,
               next_content.sequence,
               "wow"
             )

    assert next_reaction.counts == %{"wow" => 1}

    assert {:ok, next_skip} =
             RoomServer.vote_skip(room.room_id, third.participant_id, next_content.sequence)

    assert next_skip == %{
             advanced: false,
             content_sequence: next_content.sequence,
             required_votes: 2,
             votes: 1
           }
  end

  test "RoomServer restart reconstructs durable reactions and skip-vote progress" do
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

    assert {:ok, %{advanced: false, votes: 1}} =
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

  test "skip quorum ratio is configurable and invalid configuration is rejected" do
    previous = Application.get_env(:strangertalks_new, :hangout_skip_quorum_ratio)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:strangertalks_new, :hangout_skip_quorum_ratio)
      else
        Application.put_env(:strangertalks_new, :hangout_skip_quorum_ratio, previous)
      end
    end)

    Application.put_env(:strangertalks_new, :hangout_skip_quorum_ratio, 0.75)

    {room, participants} = active_room!(4)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, current} = RoomServer.current_content(room.room_id)

    for participant <- Enum.take(participants, 3) do
      assert {:ok, %{advanced: false, required_votes: 4}} =
               RoomServer.vote_skip(room.room_id, participant.participant_id, current.sequence)
    end

    fourth = Enum.at(participants, 3)

    assert {:ok, %{advanced: true}} =
             RoomServer.vote_skip(room.room_id, fourth.participant_id, current.sequence)

    Application.put_env(:strangertalks_new, :hangout_skip_quorum_ratio, 1.0)

    {invalid_room, [invalid_member | _]} = active_room!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(invalid_room.room_id)
    assert {:ok, invalid_content} = RoomServer.current_content(invalid_room.room_id)

    assert {:error, :invalid_skip_quorum_ratio} =
             RoomServer.vote_skip(
               invalid_room.room_id,
               invalid_member.participant_id,
               invalid_content.sequence
             )
  end

  test "GROUP_NO_CONTENT and terminal rooms reject skip interaction" do
    {control, [control_member | _]} = active_room!(3, :GROUP_NO_CONTENT)
    assert {:ok, _pid} = RoomServer.ensure_started(control.room_id)

    assert {:error, :content_disabled} =
             RoomServer.vote_skip(control.room_id, control_member.participant_id, 0)

    {terminal, [member | _]} = active_room!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(terminal.room_id)
    assert {:ok, current} = RoomServer.current_content(terminal.room_id)
    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(terminal.room_id)

    assert {:error, :terminal_room} =
             RoomServer.vote_skip(terminal.room_id, member.participant_id, current.sequence)
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

  defp memberships(room_id) do
    Repo.all(from m in HangoutMembership, where: m.room_id == ^room_id)
  end

  defp membership!(room_id, participant_id) do
    Repo.one!(
      from m in HangoutMembership,
        where: m.room_id == ^room_id and m.participant_id == ^participant_id
    )
  end

  defp mark_removed!(room_id, participant_id) do
    membership = membership!(room_id, participant_id)

    membership
    |> HangoutMembership.changeset(
      %{status: :REMOVED, left_at: DateTime.utc_now(), last_seen_at: DateTime.utc_now()},
      room_id,
      participant_id
    )
    |> Repo.update!()
  end

  defp topic(room_id), do: "hangout:#{room_id}"

  defp track_room(room_id) do
    on_exit(fn ->
      case RoomServer.lookup(room_id) do
        {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
        _ -> :ok
      end
    end)
  end
end
