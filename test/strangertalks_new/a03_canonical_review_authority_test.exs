defmodule StrangertalksNew.A03CanonicalReviewAuthorityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.SafetyReviewAssistant
  alias StrangertalksNew.{Report, Repo, Reports, SafetyReview, SafetyReviews}

  defmodule CaptureProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured("safety_review_assistant", payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :a03_authority_test_pid), {
        :a03_provider_payload,
        payload
      })

      {:ok,
       %{
         "severity" => "low",
         "recommendation" => "no_action",
         "rationale" => "No stronger action is supported by the supplied evidence.",
         "needs_human_review" => false
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :a03_authority_test_pid)
    previous_agent = Application.get_env(:strangertalks_new, :safety_review_assistant)

    Application.put_env(:strangertalks_new, :a03_authority_test_pid, self())
    Application.put_env(:strangertalks_new, :safety_review_assistant, provider: CaptureProvider)

    on_exit(fn ->
      restore(:a03_authority_test_pid, previous_pid)
      restore(:safety_review_assistant, previous_agent)
    end)

    :ok
  end

  test "A03 reads canonical SafetyReview status instead of stale Report status" do
    %{report: report, review: review} = report_fixture()

    assert report.report_status == :SUBMITTED
    assert review.status == :PENDING
    assert {:ok, %{status: :IN_REVIEW}} = SafetyReviews.start_review(review.safety_review_id)
    assert Repo.get!(Report, report.report_id).report_status == :SUBMITTED

    assert {:ok, %{mutation_authority: false}} =
             SafetyReviewAssistant.review_report(report.report_id)

    assert_receive {:a03_provider_payload, payload}
    assert payload.status == "IN_REVIEW"
  end

  test "A03 fails closed before provider invocation when canonical SafetyReview is missing" do
    %{report: report, review: review} = report_fixture()
    Repo.delete!(review)

    assert {:error, :safety_review_unavailable} =
             SafetyReviewAssistant.review_report(report.report_id)

    refute_receive {:a03_provider_payload, _}, 20
  end

  defp report_fixture do
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

    assert {:ok, %Report{} = report} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               sender.participant_id,
               "HARASSMENT",
               "bounded canonical review evidence"
             )

    %{
      report: report,
      review: Repo.get_by!(SafetyReview, report_id: report.report_id)
    }
  end

  defp participant_fixture do
    assert {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
