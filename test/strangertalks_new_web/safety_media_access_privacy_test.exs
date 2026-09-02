defmodule StrangertalksNewWeb.SafetyMediaAccessPrivacyTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.{ReportSafetyMedia, Repo, Reports}
  alias StrangertalksNewWeb.ParticipantToken

  @secret_bytes <<0, 255, 17, 34, 51, 68, 85, 102>>

  test "durable safety copy is unreachable by submitter, reported participant, outsider, and normal media routes",
       %{
         conn: conn
       } do
    fixture = conversation_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation.conversation_id,
               fixture.participant_a.participant_id,
               "HARASSMENT",
               "bounded participant-context evidence"
             )

    media =
      %ReportSafetyMedia{}
      |> ReportSafetyMedia.changeset(%{
        report_id: report.report_id,
        media_bytes: @secret_bytes,
        media_type: "image/jpeg",
        byte_size: byte_size(@secret_bytes),
        created_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    safety_id = media.safety_media_id
    conversation_id = fixture.conversation.conversation_id

    routes =
      StrangertalksNewWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)

    refute Enum.any?(routes, &String.contains?(&1, "report_safety_media"))
    refute Enum.any?(routes, &String.contains?(&1, "safety-media"))

    submitter_token = ParticipantToken.sign(fixture.participant_a.participant_id)
    reported_token = ParticipantToken.sign(fixture.participant_b.participant_id)
    outsider_token = ParticipantToken.sign(fixture.outsider.participant_id)

    for token <- [submitter_token, reported_token] do
      normal =
        authorized_get(
          conn,
          token,
          "/api/conversations/#{conversation_id}/normal-media/#{safety_id}"
        )

      assert normal.status == 404
      assert :binary.match(normal.resp_body, @secret_bytes) == :nomatch

      view_once =
        authorized_get(
          conn,
          token,
          "/api/conversations/#{conversation_id}/view-once/#{safety_id}?token=guessed"
        )

      refute view_once.status == 200
      assert :binary.match(view_once.resp_body, @secret_bytes) == :nomatch
    end

    outsider_normal =
      authorized_get(
        conn,
        outsider_token,
        "/api/conversations/#{conversation_id}/normal-media/#{safety_id}"
      )

    assert outsider_normal.status == 403
    assert :binary.match(outsider_normal.resp_body, @secret_bytes) == :nomatch

    outsider_view_once =
      authorized_get(
        conn,
        outsider_token,
        "/api/conversations/#{conversation_id}/view-once/#{safety_id}?token=guessed"
      )

    assert outsider_view_once.status == 403
    assert :binary.match(outsider_view_once.resp_body, @secret_bytes) == :nomatch
  end

  defp authorized_get(conn, token, path) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(path)
  end

  defp conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    outsider = participant_fixture()
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
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
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b,
      outsider: outsider
    }
  end

  defp participant_fixture do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: DateTime.utc_now(),
        last_active_at: DateTime.utc_now()
      })

    participant
  end
end
