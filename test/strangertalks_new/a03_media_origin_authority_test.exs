defmodule StrangertalksNew.A03MediaOriginAuthorityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.SafetyReviewAssistant
  alias StrangertalksNew.{Report, ReportSafetyMedia, Repo, Reports, SafetyReview}

  defmodule CaptureProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured("safety_review_assistant", payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :a03_media_origin_test_pid), {
        :a03_provider_payload,
        payload
      })

      needs_human_review = payload.media_attached == true

      {:ok,
       %{
         "severity" => "low",
         "recommendation" => "no_action",
         "rationale" => "Advisory outcome evaluated against bounded context.",
         "needs_human_review" => needs_human_review
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :a03_media_origin_test_pid)
    previous_agent = Application.get_env(:strangertalks_new, :safety_review_assistant)

    Application.put_env(:strangertalks_new, :a03_media_origin_test_pid, self())
    Application.put_env(:strangertalks_new, :safety_review_assistant, provider: CaptureProvider)

    on_exit(fn ->
      restore(:a03_media_origin_test_pid, previous_pid)
      restore(:safety_review_assistant, previous_agent)
    end)

    :ok
  end

  describe "A03 media origin authority" do
    test "NO_MEDIA report passes media_attached=false to provider" do
      %{report: report} = setup_report(media_origin: :NO_MEDIA, attach_bytes: false)

      assert {:ok, result} = SafetyReviewAssistant.review_report(report.report_id)
      assert result.mutation_authority == false

      assert_receive {:a03_provider_payload, payload}
      assert payload.media_attached == false
    end

    test "MEDIA_RETAINED report passes media_attached=true and requires human review" do
      %{report: report} = setup_report(media_origin: :MEDIA_ORIGIN, attach_bytes: true)

      assert {:ok, result} = SafetyReviewAssistant.review_report(report.report_id)
      assert result.mutation_authority == false
      assert result.needs_human_review == true

      assert_receive {:a03_provider_payload, payload}
      assert payload.media_attached == true
    end

    test "MEDIA_OMITTED report preserves media_attached=true despite omitted bytes" do
      %{report: report} = setup_report(media_origin: :MEDIA_ORIGIN, attach_bytes: false)

      assert {:ok, :MEDIA_OMITTED} = Reports.media_evidence_state(report.report_id)

      assert {:ok, result} = SafetyReviewAssistant.review_report(report.report_id)
      assert result.mutation_authority == false
      assert result.needs_human_review == true

      assert_receive {:a03_provider_payload, payload}
      assert payload.media_attached == true
    end

    test "fails closed before provider when media_origin is unavailable (legacy report)" do
      %{report: report} = setup_report(media_origin: nil, attach_bytes: false)

      assert {:error, :media_origin_unavailable} =
               SafetyReviewAssistant.review_report(report.report_id)

      refute_receive {:a03_provider_payload, _}, 20
    end

    test "fails closed before provider when media_origin state is contradictory" do
      %{report: report} = setup_report(media_origin: :NO_MEDIA, attach_bytes: true)

      assert {:error, :invalid_media_origin_state} =
               SafetyReviewAssistant.review_report(report.report_id)

      refute_receive {:a03_provider_payload, _}, 20
    end

    test "fails closed when report does not exist" do
      assert {:error, :report_not_found} =
               SafetyReviewAssistant.review_report(Ecto.UUID.generate())

      refute_receive {:a03_provider_payload, _}, 20
    end

    test "zero mutation authority on Report, SafetyReview, or ReportSafetyMedia" do
      %{report: report, review: review} =
        setup_report(media_origin: :MEDIA_ORIGIN, attach_bytes: true)

      initial_reports_count = Repo.aggregate(Report, :count)
      initial_reviews_count = Repo.aggregate(SafetyReview, :count)
      initial_media_count = Repo.aggregate(ReportSafetyMedia, :count)

      assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)

      assert Repo.aggregate(Report, :count) == initial_reports_count
      assert Repo.aggregate(SafetyReview, :count) == initial_reviews_count
      assert Repo.aggregate(ReportSafetyMedia, :count) == initial_media_count

      reloaded_report = Repo.get!(Report, report.report_id)
      reloaded_review = Repo.get!(SafetyReview, review.safety_review_id)

      assert reloaded_report.report_status == report.report_status
      assert reloaded_review.status == review.status
    end
  end

  defp setup_report(opts) do
    sender = participant_fixture()
    recipient = participant_fixture()
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

    report =
      Repo.insert!(%Report{
        conversation_id: conversation.conversation_id,
        reporting_participant_id: sender.participant_id,
        reported_participant_id: recipient.participant_id,
        report_category: :HARASSMENT,
        report_status: :SUBMITTED,
        reporter_context: "evidence text",
        media_origin: Keyword.get(opts, :media_origin, :NO_MEDIA),
        created_at: now,
        updated_at: now
      })

    review =
      Repo.insert!(%SafetyReview{
        report_id: report.report_id,
        status: :PENDING,
        created_at: now,
        updated_at: now
      })

    if Keyword.get(opts, :attach_bytes, false) do
      Repo.insert!(%ReportSafetyMedia{
        report_id: report.report_id,
        media_type: "image/png",
        media_bytes: <<1, 2, 3, 4>>,
        byte_size: 4,
        created_at: now
      })
    end

    %{report: report, review: review, conversation: conversation}
  end

  defp participant_fixture do
    assert {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
