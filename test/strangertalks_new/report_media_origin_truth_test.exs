defmodule StrangertalksNew.ReportMediaOriginTruthTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, ViewOnceMediaStore}
  alias StrangertalksNew.{ReportSafetyMedia, Repo, Reports}

  setup do
    previous_limit = Application.get_env(:strangertalks_new, :safety_media_aggregate_byte_limit)

    on_exit(fn ->
      if is_nil(previous_limit) do
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      else
        Application.put_env(
          :strangertalks_new,
          :safety_media_aggregate_byte_limit,
          previous_limit
        )
      end
    end)

    :ok
  end

  test "canonical report truth distinguishes an ordinary no-media report" do
    fixture = conversation_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation_id,
               fixture.sender_id,
               "SPAM",
               "ordinary text evidence"
             )

    assert report.media_origin == :NO_MEDIA
    assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id) == nil
    assert Reports.media_evidence_state(report.report_id) == {:ok, :NO_MEDIA}
  end

  test "canonical report truth distinguishes media origin with retained safety bytes" do
    fixture = media_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation_id,
               fixture.recipient_id,
               "HARASSMENT",
               nil,
               fixture.client_message_id
             )

    assert report.media_origin == :MEDIA_ORIGIN
    assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
    assert Reports.media_evidence_state(report.report_id) == {:ok, :MEDIA_RETAINED}
  end

  test "canonical report truth preserves media origin when safety bytes are omitted by capacity" do
    fixture = media_fixture()
    current_bytes = Repo.aggregate(ReportSafetyMedia, :sum, :byte_size) || 0

    Application.put_env(
      :strangertalks_new,
      :safety_media_aggregate_byte_limit,
      current_bytes
    )

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation_id,
               fixture.recipient_id,
               "THREATS",
               nil,
               fixture.client_message_id
             )

    assert report.reporter_context == "[View-Once Photo Evidence Attached]"
    assert report.media_origin == :MEDIA_ORIGIN
    assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id) == nil
    assert Reports.media_evidence_state(report.report_id) == {:ok, :MEDIA_OMITTED}
  end

  test "missing durable media-origin authority fails closed" do
    fixture = conversation_fixture()
    now = DateTime.utc_now()

    assert {:ok, report} =
             Reports.create_report(%{
               created_at: now,
               updated_at: now,
               reporting_participant_id: fixture.sender_id,
               reported_participant_id: fixture.recipient_id,
               conversation_id: fixture.conversation_id,
               report_category: :SPAM,
               report_status: :SUBMITTED,
               reporter_context: "legacy report without structured media origin"
             })

    assert Reports.media_evidence_state(report.report_id) == {:error, :media_origin_unavailable}
  end

  test "free-form text that looks like media evidence never becomes media-origin authority" do
    fixture = conversation_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation_id,
               fixture.sender_id,
               "SPAM",
               "[View-Once Photo Evidence Attached]"
             )

    assert report.reporter_context == "[View-Once Photo Evidence Attached]"
    assert report.media_origin == :NO_MEDIA
    assert Reports.media_evidence_state(report.report_id) == {:ok, :NO_MEDIA}
  end

  test "deleting retained safety bytes does not erase durable media origin" do
    fixture = media_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation_id,
               fixture.recipient_id,
               "HARASSMENT",
               nil,
               fixture.client_message_id
             )

    safety_media = Repo.get_by!(ReportSafetyMedia, report_id: report.report_id)
    Repo.delete!(safety_media)

    assert Reports.get_report(report.report_id).media_origin == :MEDIA_ORIGIN
    assert Reports.media_evidence_state(report.report_id) == {:ok, :MEDIA_OMITTED}
  end

  test "contradictory no-media origin plus retained safety bytes fails closed" do
    fixture = conversation_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation_id,
               fixture.sender_id,
               "SPAM",
               "ordinary text evidence"
             )

    media = valid_jpeg()

    assert {:ok, _safety_media} =
             %ReportSafetyMedia{}
             |> ReportSafetyMedia.changeset(%{
               report_id: report.report_id,
               media_bytes: media,
               media_type: "image/jpeg",
               byte_size: byte_size(media),
               created_at: DateTime.utc_now()
             })
             |> Repo.insert()

    assert Reports.media_evidence_state(report.report_id) ==
             {:error, :invalid_media_origin_state}
  end

  defp media_fixture do
    fixture = conversation_fixture()
    media = valid_jpeg()

    assert {:ok, staging_token} =
             ViewOnceMediaStore.stage_media(
               fixture.conversation_id,
               fixture.sender_id,
               media
             )

    client_message_id = Ecto.UUID.generate()

    assert {:ok, _result} =
             ConversationServer.append_view_once_photo(
               fixture.conversation_id,
               fixture.sender_id,
               client_message_id,
               staging_token
             )

    Map.merge(fixture, %{client_message_id: client_message_id, media: media})
  end

  defp conversation_fixture do
    assert {:ok, sender} = StrangertalksNew.Participants.create_participant(%{})
    assert {:ok, recipient} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    assert {:ok, matching} =
             StrangertalksNew.Matches.create_match(%{
               created_at: now,
               door_type: :JUST_TALK,
               match_status: :CREATED,
               match_strategy: :COMPATIBILITY,
               participant_a_id: sender.participant_id,
               participant_b_id: recipient.participant_id,
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

    assert {:ok, conversation} =
             StrangertalksNew.Conversations.create_conversation(%{
               created_at: now,
               match_id: matching.match_id,
               participant_a_id: sender.participant_id,
               participant_b_id: recipient.participant_id,
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

    start_supervised!({ConversationServer, %{conversation_id: conversation.conversation_id}})

    %{
      conversation_id: conversation.conversation_id,
      sender_id: sender.participant_id,
      recipient_id: recipient.participant_id
    }
  end

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end
end
