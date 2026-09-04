defmodule StrangertalksNew.A03CanonicalReviewInputTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.SafetyReviewAssistant
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, ViewOnceMediaStore}
  alias StrangertalksNew.MatchingRules.BoundaryBlock

  alias StrangertalksNew.{
    Conversation,
    Matching,
    Report,
    ReportSafetyMedia,
    Repo,
    Reports,
    SafetyReview,
    SafetyReviews
  }

  defmodule CaptureProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured("safety_review_assistant", payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :a03_canonical_test_pid), {
        :a03_provider_payload,
        payload
      })

      case Application.get_env(:strangertalks_new, :a03_canonical_test_mode, :normal) do
        :normal ->
          {:ok,
           %{
             "severity" => "low",
             "recommendation" => "no_action",
             "rationale" => "No stronger action is supported by the supplied evidence.",
             "needs_human_review" => false
           }}

        :human_review ->
          {:ok,
           %{
             "severity" => "medium",
             "recommendation" => "warning",
             "rationale" => "The supplied evidence should be reviewed by a human.",
             "needs_human_review" => true
           }}

        :malformed ->
          {:ok, %{"severity" => "low"}}

        :high_without_human ->
          {:ok,
           %{
             "severity" => "high",
             "recommendation" => "warning",
             "rationale" => "High-severity output must not bypass human review.",
             "needs_human_review" => false
           }}

        :permanent_ban_without_human ->
          {:ok,
           %{
             "severity" => "medium",
             "recommendation" => "permanent_ban",
             "rationale" => "Punitive vocabulary must remain advisory.",
             "needs_human_review" => false
           }}

        :warning_human ->
          advisory("warning")

        :cooldown_human ->
          advisory("cooldown")

        :permanent_ban_human ->
          advisory("permanent_ban")
      end
    end

    defp advisory(recommendation) do
      {:ok,
       %{
         "severity" => if(recommendation == "permanent_ban", do: "critical", else: "medium"),
         "recommendation" => recommendation,
         "rationale" => "Recommendation vocabulary only; no enforcement mutation is authorized.",
         "needs_human_review" => true
       }}
    end
  end

  setup do
    keys = [
      :a03_canonical_test_pid,
      :a03_canonical_test_mode,
      :safety_review_assistant,
      :safety_media_aggregate_byte_limit
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:strangertalks_new, &1)})

    Application.put_env(:strangertalks_new, :a03_canonical_test_pid, self())
    Application.put_env(:strangertalks_new, :a03_canonical_test_mode, :normal)
    Application.put_env(:strangertalks_new, :safety_review_assistant, provider: CaptureProvider)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
    end)

    :ok
  end

  test "A03 uses canonical SafetyReview status instead of stale Report status" do
    %{report: report, review: review} = report_fixture("HARASSMENT", "canonical review status")

    assert report.report_status == :SUBMITTED
    assert review.status == :PENDING

    assert {:ok, %{status: :IN_REVIEW}} = SafetyReviews.start_review(review.safety_review_id)
    assert Repo.get!(Report, report.report_id).report_status == :SUBMITTED

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)

    assert_receive {:a03_provider_payload, payload}
    assert payload.status == "IN_REVIEW"
  end

  test "A03 reflects canonical PENDING review state" do
    %{report: report, review: review} = report_fixture("SPAM", "pending review status")
    assert review.status == :PENDING

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)
    assert_receive {:a03_provider_payload, payload}
    assert payload.status == "PENDING"
  end

  test "A03 reflects canonical RESOLVED review state" do
    %{report: report, review: review} = report_fixture("MALICIOUS_LINKS", "resolved review status")

    assert {:ok, %{status: :RESOLVED}} =
             SafetyReviews.resolve_review(
               review.safety_review_id,
               :LOW,
               "resolved by canonical review",
               "trusted review note"
             )

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)
    assert_receive {:a03_provider_payload, payload}
    assert payload.status == "RESOLVED"
  end

  test "A03 reflects canonical DISMISSED review state" do
    %{report: report, review: review} = report_fixture("SPAM", "dismissed review status")

    assert {:ok, %{status: :DISMISSED}} =
             SafetyReviews.dismiss_review(
               review.safety_review_id,
               "dismissed by canonical review",
               "trusted review note"
             )

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)
    assert_receive {:a03_provider_payload, payload}
    assert payload.status == "DISMISSED"
  end

  test "A03 fails closed when the canonical SafetyReview row is missing" do
    %{report: report, review: review} = report_fixture("THREATS", "missing review must fail closed")

    Repo.delete!(review)

    assert {:error, :safety_review_unavailable} =
             SafetyReviewAssistant.review_report(report.report_id)

    refute_receive {:a03_provider_payload, _}, 20
  end

  test "ordinary no-media report reaches A03 as media_attached false" do
    %{report: report} = report_fixture("HARASSMENT", "ordinary text evidence")

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)

    assert_receive {:a03_provider_payload, payload}
    assert payload.media_attached == false
    assert payload.evidence == "ordinary text evidence"
  end

  test "retained media-origin report reaches A03 with human-review media signal" do
    %{report: report} = media_report_fixture()

    assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
    Application.put_env(:strangertalks_new, :a03_canonical_test_mode, :human_review)

    assert {:ok, result} = SafetyReviewAssistant.review_report(report.report_id)
    assert result.needs_human_review == true

    assert_receive {:a03_provider_payload, payload}
    assert payload.media_attached == true
    assert payload.evidence == "[View-Once Photo Evidence Attached]"
  end

  test "capacity-omitted media-origin report loses the origin distinction in current A03 input" do
    fixture = media_message_fixture()
    current_bytes = Repo.aggregate(ReportSafetyMedia, :sum, :byte_size) || 0

    Application.put_env(
      :strangertalks_new,
      :safety_media_aggregate_byte_limit,
      current_bytes
    )

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation.conversation_id,
               fixture.recipient.participant_id,
               "THREATS",
               nil,
               fixture.client_message_id
             )

    assert report.reporter_context == "[View-Once Photo Evidence Attached]"
    assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id) == nil

    assert {:ok, result} = SafetyReviewAssistant.review_report(report.report_id)
    assert result.needs_human_review == false

    assert_receive {:a03_provider_payload, payload}
    assert payload.media_attached == false
    assert payload.evidence == "[View-Once Photo Evidence Attached]"
  end

  test "missing evidence and no-media evidence remain insufficient to prove media origin" do
    %{report: report} = report_fixture("SPAM", nil)

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)

    assert_receive {:a03_provider_payload, payload}
    assert payload.evidence == nil
    assert payload.media_attached == false
  end

  test "free-form email reaches the fake provider unchanged" do
    assert_sensitive_projection("contact me at alice@example.test")
  end

  test "free-form phone number reaches the fake provider unchanged" do
    assert_sensitive_projection("call +1 202-555-0100")
  end

  test "free-form address-like private information reaches the fake provider unchanged" do
    assert_sensitive_projection("meet at 123 Example Street, Test City")
  end

  test "free-form credential-like secret reaches the fake provider unchanged" do
    assert_sensitive_projection("credential sk-test-not-real-12345")
  end

  test "free-form unrelated private identifier reaches the fake provider unchanged" do
    assert_sensitive_projection("private identifier customer-secret-id-XYZ-123")
  end

  test "malformed structured provider output remains rejected" do
    Application.put_env(:strangertalks_new, :a03_canonical_test_mode, :malformed)

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "HARASSMENT",
               status: "PENDING",
               evidence: "bounded evidence",
               media_attached: false
             })
  end

  test "high recommendation without human review remains rejected" do
    Application.put_env(:strangertalks_new, :a03_canonical_test_mode, :high_without_human)

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "THREATS",
               status: "PENDING",
               evidence: "bounded threat evidence",
               media_attached: false
             })
  end

  test "permanent-ban recommendation without human review remains rejected" do
    Application.put_env(
      :strangertalks_new,
      :a03_canonical_test_mode,
      :permanent_ban_without_human
    )

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "HARASSMENT",
               status: "PENDING",
               evidence: "bounded evidence",
               media_attached: false
             })
  end

  test "warning cooldown and permanent-ban outputs remain recommendation vocabulary only" do
    %{report: report, review: review, conversation: conversation} =
      report_fixture("HARASSMENT", "authority regression evidence")

    report_count = Repo.aggregate(Report, :count)
    review_count = Repo.aggregate(SafetyReview, :count)
    block_count = Repo.aggregate(BoundaryBlock, :count)
    matching_count = Repo.aggregate(Matching, :count)
    provider_config = Application.get_env(:strangertalks_new, :safety_review_assistant)

    for mode <- [:warning_human, :cooldown_human, :permanent_ban_human] do
      Application.put_env(:strangertalks_new, :a03_canonical_test_mode, mode)

      assert {:ok, %{mutation_authority: false}} =
               SafetyReviewAssistant.review_report(report.report_id)

      assert_receive {:a03_provider_payload, _}
    end

    persisted_report = Repo.get!(Report, report.report_id)
    persisted_review = Repo.get!(SafetyReview, review.safety_review_id)
    persisted_conversation = Repo.get!(Conversation, conversation.conversation_id)

    assert Repo.aggregate(Report, :count) == report_count
    assert Repo.aggregate(SafetyReview, :count) == review_count
    assert Repo.aggregate(BoundaryBlock, :count) == block_count
    assert Repo.aggregate(Matching, :count) == matching_count

    assert persisted_report.report_status == :SUBMITTED
    assert persisted_review.status == :PENDING
    assert persisted_conversation.conversation_status == conversation.conversation_status

    assert Application.get_env(:strangertalks_new, :safety_review_assistant) == provider_config

    source = File.read!("lib/strangertalks_new/agent_systems/safety_review_assistant.ex")

    for forbidden <- [
          "Repo.insert",
          "Repo.update",
          "Repo.delete",
          "BoundaryBlock",
          "SafetyReviews.",
          "ConversationServer.",
          "MatchmakingEngine.",
          "Application.put_env",
          "Application.delete_env"
        ] do
      refute source =~ forbidden
    end
  end

  defp assert_sensitive_projection(evidence) do
    %{report: report} = report_fixture("HARASSMENT", evidence)

    assert {:ok, _result} = SafetyReviewAssistant.review_report(report.report_id)

    assert_receive {:a03_provider_payload, payload}
    assert payload.evidence == evidence
  end

  defp report_fixture(category, evidence) do
    fixture = conversation_fixture()

    assert {:ok, %Report{} = report} =
             Reports.submit_conversation_report(
               fixture.conversation.conversation_id,
               fixture.sender.participant_id,
               category,
               evidence
             )

    %{
      report: report,
      review: Repo.get_by!(SafetyReview, report_id: report.report_id),
      conversation: fixture.conversation,
      sender: fixture.sender,
      recipient: fixture.recipient
    }
  end

  defp media_report_fixture do
    fixture = media_message_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               fixture.conversation.conversation_id,
               fixture.recipient.participant_id,
               "HARASSMENT",
               nil,
               fixture.client_message_id
             )

    %{report: report, fixture: fixture}
  end

  defp media_message_fixture do
    fixture = conversation_fixture()

    _pid =
      start_supervised!(
        {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
      )

    media = valid_jpeg()

    assert {:ok, staging_token} =
             ViewOnceMediaStore.stage_media(
               fixture.conversation.conversation_id,
               fixture.sender.participant_id,
               media
             )

    client_message_id = Ecto.UUID.generate()

    assert {:ok, _result} =
             ConversationServer.append_view_once_photo(
               fixture.conversation.conversation_id,
               fixture.sender.participant_id,
               client_message_id,
               staging_token
             )

    Map.merge(fixture, %{client_message_id: client_message_id, media: media})
  end

  defp conversation_fixture do
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

    %{conversation: conversation, sender: sender, recipient: recipient}
  end

  defp participant_fixture do
    assert {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
