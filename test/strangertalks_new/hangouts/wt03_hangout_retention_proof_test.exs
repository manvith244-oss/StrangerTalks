defmodule StrangertalksNew.Hangouts.WT03HangoutRetentionProofTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query

  alias StrangertalksNew.Hangouts

  alias StrangertalksNew.Hangouts.{
    HangoutMembership,
    HangoutMessage,
    HangoutReport,
    HangoutRoom,
    RoomServer,
    Safety
  }

  alias StrangertalksNew.{Participants, Repo, RetentionCleanup}

  test "WT-03 records Hangout persistence across normal end and two aged retention passes" do
    reference_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    unique = System.unique_integer([:positive, :monotonic])
    message_marker = "WT03_HANGOUT_RETENTION_FIXTURE_#{unique}"
    report_marker = "WT03_HANGOUT_REPORT_FIXTURE_#{unique}"

    participants =
      for _ <- 1..3 do
        {:ok, participant} =
          Participants.create_participant(%{
            presence_state: :ONLINE,
            created_at: reference_now,
            last_active_at: reference_now
          })

        participant
      end

    participant_ids = Enum.map(participants, & &1.participant_id)
    [reporter, target, sender] = participants

    assert {:ok, %{room: room, memberships: memberships}} =
             Hangouts.create_formed_room(participant_ids, %{
               language_tag: "en-WT03",
               experiment_arm: :GROUP_WITH_CONTENT,
               minimum_size: 3,
               target_size: 3,
               max_size: 3
             })

    target_membership = Enum.find(memberships, &(&1.participant_id == target.participant_id))

    assert {:ok, %{sequence: 1, body: ^message_marker}} =
             RoomServer.send_message(room.room_id, sender.participant_id, %{
               client_message_id: "wt03-message-#{unique}",
               body: message_marker
             })

    assert {:ok, %{status: "submitted"}} =
             Safety.submit_report(room.room_id, reporter.participant_id, %{
               client_report_id: "wt03-report-#{unique}",
               target_identity_slot: target_membership.temporary_identity_slot,
               category: "harassment",
               evidence: report_marker
             })

    pre_end = fixture_snapshot(room.room_id, message_marker, report_marker)
    emit_snapshot("WT03_PRE_END", pre_end)

    assert pre_end.room.count == 1
    assert pre_end.room.status == :ACTIVE
    assert pre_end.memberships.count == 3
    assert pre_end.message.count == 1
    assert pre_end.message.marker_present
    assert pre_end.report.count == 1
    assert pre_end.report.evidence_marker_present

    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(room.room_id)

    post_end = fixture_snapshot(room.room_id, message_marker, report_marker)
    emit_snapshot("WT03_POST_END", post_end)

    assert post_end.room.count == 1
    assert post_end.room.status == :ENDED
    assert not is_nil(post_end.room.ended_at)

    aged_now = DateTime.add(reference_now, 365 * 86_400, :second)

    IO.inspect(
      %{
        age_days: 365,
        clock_mechanism: :retention_cleanup_now_argument,
        rows_manually_timestamp_adjusted: false,
        reference_now: reference_now,
        synthetic_now: aged_now
      },
      label: "WT03_AGED_FIXTURE",
      limit: :infinity
    )

    cleanup_pass_1 = RetentionCleanup.run(aged_now)
    IO.inspect(cleanup_pass_1, label: "WT03_CLEANUP_PASS_1_RESULT", limit: :infinity)

    after_pass_1 = fixture_snapshot(room.room_id, message_marker, report_marker)
    emit_snapshot("WT03_AFTER_CLEANUP_PASS_1", after_pass_1)

    cleanup_pass_2 = RetentionCleanup.run(aged_now)
    IO.inspect(cleanup_pass_2, label: "WT03_CLEANUP_PASS_2_RESULT", limit: :infinity)

    after_pass_2 = fixture_snapshot(room.room_id, message_marker, report_marker)
    emit_snapshot("WT03_AFTER_CLEANUP_PASS_2", after_pass_2)

    assert is_map(cleanup_pass_1)
    assert is_map(cleanup_pass_2)
    assert is_map(after_pass_1)
    assert is_map(after_pass_2)
  end

  defp fixture_snapshot(room_id, message_marker, report_marker) do
    room = Repo.get(HangoutRoom, room_id)

    memberships =
      Repo.all(
        from m in HangoutMembership,
          where: m.room_id == ^room_id,
          order_by: [asc: m.temporary_identity_slot]
      )

    messages =
      Repo.all(
        from m in HangoutMessage,
          where: m.room_id == ^room_id,
          order_by: [asc: m.sequence]
      )

    reports =
      Repo.all(
        from r in HangoutReport,
          where: r.room_id == ^room_id,
          order_by: [asc: r.created_at]
      )

    %{
      room: %{
        count: if(is_nil(room), do: 0, else: 1),
        id: room && room.room_id,
        status: room && room.status,
        created_at: room && room.created_at,
        ended_at: room && room.ended_at
      },
      memberships: %{
        count: length(memberships),
        ids: Enum.map(memberships, & &1.membership_id),
        participant_ids: Enum.map(memberships, & &1.participant_id),
        statuses: Enum.map(memberships, & &1.status),
        joined_at: Enum.map(memberships, & &1.joined_at),
        left_at: Enum.map(memberships, & &1.left_at),
        temporary_identity_slots: Enum.map(memberships, & &1.temporary_identity_slot)
      },
      message: %{
        count: length(messages),
        id: first_field(messages, :message_id),
        membership_id: first_field(messages, :membership_id),
        room_id: first_field(messages, :room_id),
        sequence: first_field(messages, :sequence),
        created_at: first_field(messages, :created_at),
        marker_present: Enum.any?(messages, &(&1.body == message_marker))
      },
      report: %{
        count: length(reports),
        id: first_field(reports, :report_id),
        room_id: first_field(reports, :room_id),
        reporting_participant_id: first_field(reports, :reporting_participant_id),
        reported_participant_id: first_field(reports, :reported_participant_id),
        status: first_field(reports, :status),
        created_at: first_field(reports, :created_at),
        evidence_marker_present: Enum.any?(reports, &(&1.evidence == report_marker))
      }
    }
  end

  defp first_field([], _field), do: nil
  defp first_field([row | _], field), do: Map.fetch!(row, field)

  defp emit_snapshot(label, snapshot) do
    IO.inspect(snapshot, label: label, limit: :infinity)
  end
end
