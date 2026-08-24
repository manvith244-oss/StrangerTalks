defmodule StrangertalksNew.RelationshipConsentSafetyReviewTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{
    Conversation,
    Relationship,
    RelationshipConsent,
    Report,
    SafetyEvent,
    SafetyReview
  }

  alias StrangertalksNew.{Relationships, Reports, Repo, SafetyReviews}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "mutual consent creates exactly one canonical relationship with unbuilt outputs nil" do
    {conversation, participant_a, participant_b} = completed_conversation_fixture()

    assert {:ok, %{status: "waiting_for_mutual_consent"}} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_a.participant_id
             )

    assert Repo.aggregate(RelationshipConsent, :count) == 1
    assert Repo.aggregate(Relationship, :count) == 0

    assert {:ok, %{status: "created", relationship_id: relationship_id}} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_b.participant_id
             )

    relationship = Repo.get!(Relationship, relationship_id)

    assert {relationship.participant_a_id, relationship.participant_b_id} ==
             Enum.sort([participant_a.participant_id, participant_b.participant_id])
             |> List.to_tuple()

    assert Repo.aggregate(Relationship, :count) == 1
    assert is_nil(relationship.learning_version)
    assert is_nil(relationship.learning_processed)
    assert is_nil(relationship.reconnection_priority)
    assert is_nil(relationship.relationship_strength_score)
    assert is_nil(relationship.continuation_probability)
    assert is_nil(relationship.relationship_temperature)
    assert is_nil(relationship.atmosphere_history)
    assert is_nil(relationship.relationship_summary)

    assert {:ok, %{status: "created", relationship_id: ^relationship_id}} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_b.participant_id
             )

    assert Repo.aggregate(Relationship, :count) == 1
  end

  test "concurrent second consent creates one relationship" do
    {conversation, participant_a, participant_b} = completed_conversation_fixture()

    assert {:ok, _} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_a.participant_id
             )

    results =
      [participant_b.participant_id, participant_b.participant_id]
      |> Task.async_stream(
        &Relationships.consent_to_relationship(conversation.conversation_id, &1),
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %{status: "created"}}}, &1))
    assert Repo.aggregate(RelationshipConsent, :count) == 2
    assert Repo.aggregate(Relationship, :count) == 1
  end

  test "nonmembers and ineligible endings cannot consent" do
    {conversation, participant_a, _participant_b} = completed_conversation_fixture()
    outsider = participant_fixture()

    assert {:error, :not_conversation_member} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               outsider.participant_id
             )

    for {status, completed, ending_type} <- [
          {:ABANDONED, false, :DISCONNECT},
          {:ENDED, false, :SAFETY_ACTION}
        ] do
      conversation
      |> Conversation.changeset(%{
        conversation_status: status,
        conversation_completed: completed,
        ending_type: ending_type
      })
      |> Repo.update!()

      assert {:error, :conversation_inactive} =
               Relationships.consent_to_relationship(
                 conversation.conversation_id,
                 participant_a.participant_id
               )
    end

    assert Repo.aggregate(RelationshipConsent, :count) == 0
  end

  test "report atomically creates one pending review and review transitions are explicit" do
    {conversation, participant_a, _participant_b} = completed_conversation_fixture()

    submit = fn ->
      Reports.submit_conversation_report(
        conversation.conversation_id,
        participant_a.participant_id,
        "HARASSMENT",
        "exact evidence"
      )
    end

    results =
      [1, 2]
      |> Task.async_stream(fn _ -> submit.() end, max_concurrency: 2, timeout: :infinity)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %Report{}}}, &1))
    assert Repo.aggregate(Report, :count) == 1
    assert Repo.aggregate(SafetyReview, :count) == 1
    assert Repo.aggregate(SafetyEvent, :count) == 0

    review = Repo.one!(SafetyReview)
    assert review.status == :PENDING
    assert is_nil(review.severity_level)

    assert {:error, :invalid_review_decision} =
             SafetyReviews.resolve_review(review.safety_review_id, :UNKNOWN, "done", nil)

    assert {:error, :invalid_review_decision} =
             SafetyReviews.resolve_review(review.safety_review_id, :LOW, "", nil)

    assert {:ok, %{status: :IN_REVIEW}} = SafetyReviews.start_review(review.safety_review_id)

    assert {:ok, resolved} =
             SafetyReviews.resolve_review(
               review.safety_review_id,
               :HIGH,
               "action recorded",
               "trusted note"
             )

    assert {:ok, ^resolved} =
             SafetyReviews.resolve_review(
               review.safety_review_id,
               :HIGH,
               "action recorded",
               "trusted note"
             )

    assert {:error, :conflicting_terminal_decision} =
             SafetyReviews.dismiss_review(review.safety_review_id, "different", nil)
  end

  test "concurrent identical terminal SafetyReview retries converge idempotently" do
    review = pending_review_fixture("HARASSMENT", "identical retry evidence")

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          SafetyReviews.resolve_review(
            review.safety_review_id,
            :HIGH,
            "same terminal decision",
            "same trusted note"
          )
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %SafetyReview{status: :RESOLVED}}, &1))

    persisted = Repo.get!(SafetyReview, review.safety_review_id)
    assert persisted.status == :RESOLVED
    assert persisted.severity_level == :HIGH
    assert persisted.resolution == "same terminal decision"
    assert persisted.review_notes == "same trusted note"
    assert Repo.aggregate(SafetyEvent, :count) == 0
  end

  test "conflicting concurrent terminal safety review decisions serialize to one winner" do
    review = pending_review_fixture("THREATS", "concurrent terminal decision evidence")
    parent = self()

    resolve_task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go ->
            SafetyReviews.resolve_review(
              review.safety_review_id,
              :CRITICAL,
              "escalate",
              "resolve path"
            )
        end
      end)

    dismiss_task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> SafetyReviews.dismiss_review(review.safety_review_id, "dismiss", "dismiss path")
        end
      end)

    assert_receive {:ready, resolve_pid}, 1_000
    assert_receive {:ready, dismiss_pid}, 1_000
    send(resolve_pid, :go)
    send(dismiss_pid, :go)

    assert_one_terminal_winner(
      review.safety_review_id,
      Task.await(resolve_task, 5_000),
      Task.await(dismiss_task, 5_000)
    )
  end

  test "reverse-release dismiss versus resolve conflict still has one terminal winner" do
    review = pending_review_fixture("SPAM", "reverse conflict evidence")
    parent = self()

    dismiss_task =
      Task.async(fn ->
        send(parent, {:dismiss_ready, self()})

        receive do
          :go ->
            SafetyReviews.dismiss_review(review.safety_review_id, "dismiss-first", "dismiss path")
        end
      end)

    resolve_task =
      Task.async(fn ->
        send(parent, {:resolve_ready, self()})

        receive do
          :go ->
            SafetyReviews.resolve_review(
              review.safety_review_id,
              :MEDIUM,
              "resolve-second",
              "resolve path"
            )
        end
      end)

    assert_receive {:dismiss_ready, dismiss_pid}, 1_000
    assert_receive {:resolve_ready, resolve_pid}, 1_000
    send(dismiss_pid, :go)
    Process.sleep(5)
    send(resolve_pid, :go)

    assert_one_terminal_winner(
      review.safety_review_id,
      Task.await(dismiss_task, 5_000),
      Task.await(resolve_task, 5_000)
    )
  end

  test "failed terminal update rolls back cleanly and a later retry remains safe" do
    review = pending_review_fixture("MALICIOUS_LINKS", "rollback evidence")

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION team4_fail_safety_review_update()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'team4 forced safety review update failure';
      END;
      $$ LANGUAGE plpgsql
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER team4_fail_safety_review_update
      BEFORE UPDATE ON safety_reviews
      FOR EACH ROW EXECUTE FUNCTION team4_fail_safety_review_update()
      """,
      []
    )

    try do
      assert_raise Postgrex.Error, fn ->
        SafetyReviews.resolve_review(
          review.safety_review_id,
          :LOW,
          "must roll back",
          "must not persist"
        )
      end
    after
      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP TRIGGER IF EXISTS team4_fail_safety_review_update ON safety_reviews",
        []
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP FUNCTION IF EXISTS team4_fail_safety_review_update()",
        []
      )
    end

    rolled_back = Repo.get!(SafetyReview, review.safety_review_id)
    assert rolled_back.status == :PENDING
    assert is_nil(rolled_back.severity_level)
    assert is_nil(rolled_back.resolution)
    assert is_nil(rolled_back.review_notes)
    assert is_nil(rolled_back.reviewed_at)
    assert Repo.aggregate(SafetyEvent, :count) == 0

    assert {:ok, retried} =
             SafetyReviews.resolve_review(
               review.safety_review_id,
               :LOW,
               "retry succeeds",
               "trusted after rollback"
             )

    assert retried.status == :RESOLVED
    assert retried.resolution == "retry succeeds"
  end

  defp assert_one_terminal_winner(review_id, first_result, second_result) do
    results = [first_result, second_result]
    assert Enum.count(results, &match?({:ok, %SafetyReview{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflicting_terminal_decision}, &1)) == 1

    persisted = Repo.get!(SafetyReview, review_id)
    assert persisted.status in [:RESOLVED, :DISMISSED]

    case persisted.status do
      :RESOLVED ->
        assert persisted.severity_level in [:MEDIUM, :CRITICAL]
        assert persisted.resolution in ["escalate", "resolve-second"]
        assert persisted.review_notes == "resolve path"

      :DISMISSED ->
        assert is_nil(persisted.severity_level)
        assert persisted.resolution in ["dismiss", "dismiss-first"]
        assert persisted.review_notes == "dismiss path"
    end

    assert Repo.aggregate(SafetyEvent, :count) == 0
  end

  defp pending_review_fixture(category, evidence) do
    {conversation, participant_a, _participant_b} = completed_conversation_fixture()

    assert {:ok, %Report{} = report} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               participant_a.participant_id,
               category,
               evidence
             )

    Repo.get_by!(SafetyReview, report_id: report.report_id)
  end

  defp completed_conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, _} =
      MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, _} =
      MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, [_]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.one!(from c in Conversation, order_by: [desc: c.created_at], limit: 1)

    conversation =
      conversation
      |> Conversation.changeset(%{
        conversation_status: :ENDED,
        conversation_completed: true,
        ending_type: :NATURAL_END,
        ended_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {conversation, participant_a, participant_b}
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end
end
