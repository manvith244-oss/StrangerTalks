defmodule StrangertalksNew.Hangouts.SafetyTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint
  @wire_categories ~w(harassment sexual_content hate threat spam_scam personal_information other)

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{
    HangoutMembership,
    HangoutReport,
    HangoutRoom,
    Matcher,
    RoomServer,
    Safety
  }

  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.{Participants, Repo}
  alias StrangertalksNewWeb.{HangoutChannel, ParticipantToken, UserSocket}

  test "authenticated report resolves a room-scoped temporary slot, stays private-safe, and retries idempotently" do
    {room, [reporter, target | others]} = active_room!(4, "en-S01")
    target_identity = identity_for(room.room_id, target.participant_id)

    assert Safety.report_categories() == @wire_categories

    assert {:ok, _snapshot, socket} = join_room(reporter, room.room_id)

    payload = %{
      "client_report_id" => "report-1",
      "target_identity_slot" => target_identity.slot,
      "category" => "harassment",
      "evidence" => "repeated insulting messages"
    }

    ref = push(socket, "safety:report", payload)
    assert_reply ref, :ok, accepted

    assert accepted == %{
             status: "submitted",
             category: "harassment",
             target: target_identity
           }

    refute_push "safety:report", _payload

    encoded = inspect(accepted)
    refute encoded =~ reporter.participant_id
    refute encoded =~ target.participant_id

    for participant <- others do
      refute encoded =~ participant.participant_id
    end

    persisted = Repo.one!(from r in HangoutReport, where: r.room_id == ^room.room_id)
    assert persisted.reporting_participant_id == reporter.participant_id
    assert persisted.reported_participant_id == target.participant_id
    assert persisted.category == :HARASSMENT
    assert persisted.status == :SUBMITTED
    assert persisted.evidence == "repeated insulting messages"
    assert is_binary(persisted.deduplication_key)
    refute persisted.deduplication_key =~ "report-1"

    retry_ref = push(socket, "safety:report", payload)
    assert_reply retry_ref, :ok, ^accepted
    assert Repo.aggregate(HangoutReport, :count, :report_id) == 1

    conflict_ref = push(socket, "safety:report", Map.put(payload, "category", "threat"))
    assert_reply conflict_ref, :error, %{reason: "idempotency_conflict"}
    assert Repo.aggregate(HangoutReport, :count, :report_id) == 1
  end

  test "report wire categories are finite and spoofed actor or malformed intent is rejected" do
    {room, [reporter, target | _]} = active_room!(3, "en-S02")
    target_identity = identity_for(room.room_id, target.participant_id)
    assert {:ok, _snapshot, socket} = join_room(reporter, room.room_id)

    Enum.with_index(@wire_categories, 1)
    |> Enum.each(fn {category, index} ->
      ref =
        push(socket, "safety:report", %{
          "client_report_id" => "allowed-#{index}",
          "target_identity_slot" => target_identity.slot,
          "category" => category,
          "evidence" => nil
        })

      assert_reply ref, :ok, %{category: ^category, status: "submitted"}
    end)

    invalid_ref =
      push(socket, "safety:report", %{
        "client_report_id" => "bad-category",
        "target_identity_slot" => target_identity.slot,
        "category" => "anything_goes",
        "evidence" => nil
      })

    assert_reply invalid_ref, :error, %{reason: "invalid_report_category"}

    spoof_ref =
      push(socket, "safety:report", %{
        "client_report_id" => "spoof",
        "target_identity_slot" => target_identity.slot,
        "category" => "harassment",
        "evidence" => nil,
        "reporting_participant_id" => Ecto.UUID.generate()
      })

    assert_reply spoof_ref, :error, %{reason: "invalid_report_intent"}
  end

  test "report rejects self, nonexistent target, oversized evidence, terminal room, and outsider authority" do
    {room, [reporter, _target | _]} = active_room!(3, "en-S03")
    self_identity = identity_for(room.room_id, reporter.participant_id)
    assert {:ok, _snapshot, socket} = join_room(reporter, room.room_id)

    self_ref =
      push(socket, "safety:report", %{
        "client_report_id" => "self",
        "target_identity_slot" => self_identity.slot,
        "category" => "harassment",
        "evidence" => nil
      })

    assert_reply self_ref, :error, %{reason: "self_report"}

    missing_ref =
      push(socket, "safety:report", %{
        "client_report_id" => "missing",
        "target_identity_slot" => 999,
        "category" => "harassment",
        "evidence" => nil
      })

    assert_reply missing_ref, :error, %{reason: "invalid_report_target"}

    large_ref =
      push(socket, "safety:report", %{
        "client_report_id" => "large",
        "target_identity_slot" => 2,
        "category" => "harassment",
        "evidence" => String.duplicate("é", div(HangoutReport.max_evidence_bytes(), 2) + 1)
      })

    assert_reply large_ref, :error, %{reason: "report_evidence_too_large"}

    outsider = participant!()

    assert {:error, :membership_not_active} =
             Safety.submit_report(room.room_id, outsider.participant_id, %{
               client_report_id: "outsider",
               target_identity_slot: 2,
               category: "harassment",
               evidence: nil
             })

    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(room.room_id)

    assert {:error, :terminal_room} =
             Safety.submit_report(room.room_id, reporter.participant_id, %{
               client_report_id: "ended",
               target_identity_slot: 2,
               category: "harassment",
               evidence: nil
             })
  end

  test "LEFT and REMOVED former room members remain deliberately reportable by their room-scoped slot" do
    {room, [reporter, left, removed | _]} = active_room!(4, "en-S04")
    left_identity = identity_for(room.room_id, left.participant_id)
    removed_identity = identity_for(room.room_id, removed.participant_id)

    assert {:ok, _membership} = Hangouts.leave_room(room.room_id, left.participant_id)
    mark_removed!(room.room_id, removed.participant_id)

    assert {:ok, left_report} =
             Safety.submit_report(room.room_id, reporter.participant_id, %{
               client_report_id: "left-target",
               target_identity_slot: left_identity.slot,
               category: "harassment",
               evidence: nil
             })

    assert left_report.target == left_identity

    assert {:ok, removed_report} =
             Safety.submit_report(room.room_id, reporter.participant_id, %{
               client_report_id: "removed-target",
               target_identity_slot: removed_identity.slot,
               category: "threat",
               evidence: nil
             })

    assert removed_report.target == removed_identity
  end

  test "authenticated block reuses canonical BoundaryBlock authority without destroying the current Hangout" do
    {room, [blocker, target | _]} = active_room!(3, "en-S05")
    target_identity = identity_for(room.room_id, target.participant_id)
    assert {:ok, _snapshot, socket} = join_room(blocker, room.room_id)

    block_ref =
      push(socket, "safety:block", %{"target_identity_slot" => target_identity.slot})

    assert_reply block_ref, :ok,
                 %{status: "blocked", target: ^target_identity} = accepted

    encoded = inspect(accepted)
    refute encoded =~ blocker.participant_id
    refute encoded =~ target.participant_id

    assert MatchingRules.check_safety_veto?(blocker.participant_id, target.participant_id)
    assert Repo.get!(HangoutRoom, room.room_id).status == :ACTIVE
    assert membership!(room.room_id, blocker.participant_id).status == :ACTIVE
    assert membership!(room.room_id, target.participant_id).status == :ACTIVE

    retry_ref = push(socket, "safety:block", %{"target_identity_slot" => target_identity.slot})
    assert_reply retry_ref, :ok, ^accepted

    spoof_ref =
      push(socket, "safety:block", %{
        "target_identity_slot" => target_identity.slot,
        "blocker_participant_id" => Ecto.UUID.generate()
      })

    assert_reply spoof_ref, :error, %{reason: "invalid_block_intent"}

    self_identity = identity_for(room.room_id, blocker.participant_id)
    self_ref = push(socket, "safety:block", %{"target_identity_slot" => self_identity.slot})
    assert_reply self_ref, :error, %{reason: "self_block"}

    missing_ref = push(socket, "safety:block", %{"target_identity_slot" => 999})
    assert_reply missing_ref, :error, %{reason: "invalid_block_target"}
  end

  test "blocked pairs cannot form a Hangout and FIFO-compatible participants are not poisoned" do
    language = "en-S06"
    [a, b, c, d, e, f] = participants!(6)

    assert {:ok, _block} = MatchingRules.enforce_block(a.participant_id, c.participant_id, "HANGOUT")

    Enum.each([a, b, c, d], fn participant ->
      assert {:ok, %{status: :queued}} = Matcher.enqueue(participant.participant_id, language)
    end)

    assert {:ok, first_room} = Matcher.try_form(language)
    track_room(first_room.room_id)

    assert first_room.size == 3
    assert first_room.participant_ids == [a.participant_id, b.participant_id, d.participant_id]
    refute c.participant_id in first_room.participant_ids
    assert pairwise_safe?(first_room.participant_ids)

    Enum.each([e, f], fn participant ->
      assert {:ok, %{status: :queued}} = Matcher.enqueue(participant.participant_id, language)
    end)

    assert {:ok, second_room} = Matcher.try_form(language)
    track_room(second_room.room_id)

    assert second_room.participant_ids == [c.participant_id, e.participant_id, f.participant_id]
    assert pairwise_safe?(second_room.participant_ids)
  end

  defp join_room(participant, room_id) do
    participant
    |> connected_socket()
    |> subscribe_and_join(HangoutChannel, "hangout:#{room_id}", %{})
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp active_room!(count, language) do
    participants = participants!(count)

    {:ok, %{room: room}} =
      Hangouts.create_formed_room(
        Enum.map(participants, & &1.participant_id),
        %{
          language_tag: language,
          experiment_arm: :GROUP_WITH_CONTENT,
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
    track_queue(participant.participant_id)
    participant
  end

  defp participants!(count), do: Enum.map(1..count, fn _ -> participant!() end)

  defp membership!(room_id, participant_id) do
    Repo.one!(
      from m in HangoutMembership,
        where: m.room_id == ^room_id and m.participant_id == ^participant_id
    )
  end

  defp identity_for(room_id, participant_id) do
    membership = membership!(room_id, participant_id)

    %{
      slot: membership.temporary_identity_slot,
      label: membership.temporary_identity_label,
      emoji: membership.temporary_identity_emoji
    }
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

  defp pairwise_safe?(participant_ids) do
    participant_ids
    |> Enum.with_index()
    |> Enum.all?(fn {left, index} ->
      participant_ids
      |> Enum.drop(index + 1)
      |> Enum.all?(fn right -> not MatchingRules.check_safety_veto?(left, right) end)
    end)
  end

  defp track_queue(participant_id) do
    on_exit(fn ->
      try do
        Matcher.leave_queue(participant_id)
      catch
        :exit, _reason -> :ok
      end
    end)
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
