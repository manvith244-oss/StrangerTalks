defmodule StrangertalksNew.Team4ReportBlockAbuseClosureTest do
  use StrangertalksNew.DataCase, async: false

  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint
  @message_limit 20
  @message_window_ms 10_000

  alias StrangertalksNew.{
    Conversation,
    Conversations,
    Matches,
    Participants,
    RateLimiter,
    Report,
    Reports,
    Repo,
    SafetyEvent,
    SafetyReview
  }

  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.MatchingRules.BoundaryBlock
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "outsider cannot report or block a conversation through domain authority" do
    {conversation, _participant_a, _participant_b} = conversation_fixture()
    outsider = participant_fixture()

    assert {:error, :not_conversation_member} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               outsider.participant_id,
               "SPAM",
               "outsider attempt"
             )

    assert {:error, :not_conversation_member} =
             MatchingRules.block_conversation_participant(
               conversation.conversation_id,
               outsider.participant_id
             )

    assert Repo.aggregate(Report, :count, :report_id) == 0
    assert Repo.aggregate(SafetyReview, :count, :safety_review_id) == 0
    assert Repo.aggregate(BoundaryBlock, :count) == 0
  end

  test "channel payload cannot spoof report or block actor identity" do
    {conversation, participant_a, participant_b} = conversation_fixture()
    socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

    report_ref =
      push(socket_a, "conversation:report", %{
        "category" => "SPAM",
        "evidence" => "spoof attempt",
        "participant_id" => participant_b.participant_id
      })

    assert_reply report_ref, :error, %{code: "INVALID_PAYLOAD"}

    block_ref =
      push(socket_a, "conversation:block", %{
        "participant_id" => participant_b.participant_id
      })

    assert_reply block_ref, :error, %{code: "INVALID_PAYLOAD"}

    assert Repo.aggregate(Report, :count, :report_id) == 0
    assert Repo.aggregate(SafetyReview, :count, :safety_review_id) == 0
    assert Repo.aggregate(BoundaryBlock, :count) == 0
  end

  test "identical report retries across sibling tabs converge on one report and one review" do
    {conversation, participant_a, _participant_b} = conversation_fixture()
    socket_a1 = joined_conversation_socket(participant_a, conversation.conversation_id)
    socket_a2 = joined_conversation_socket(participant_a, conversation.conversation_id)
    payload = %{"category" => "HARASSMENT", "evidence" => "same evidence"}

    ref1 = push(socket_a1, "conversation:report", payload)
    assert_reply ref1, :ok, %{report_id: report_id, status: "submitted"}

    ref2 = push(socket_a2, "conversation:report", payload)
    assert_reply ref2, :ok, %{report_id: ^report_id, status: "submitted"}

    assert Repo.aggregate(Report, :count, :report_id) == 1
    assert Repo.aggregate(SafetyReview, :count, :safety_review_id) == 1
    assert Repo.aggregate(SafetyEvent, :count, :safety_event_id) == 0
  end

  test "distinct report attempts are participant-bounded across sibling tabs" do
    {conversation, participant_a, _participant_b} = conversation_fixture()
    socket_a1 = joined_conversation_socket(participant_a, conversation.conversation_id)
    socket_a2 = joined_conversation_socket(participant_a, conversation.conversation_id)

    for i <- 1..10 do
      socket = if rem(i, 2) == 0, do: socket_a2, else: socket_a1

      ref =
        push(socket, "conversation:report", %{
          "category" => "SPAM",
          "evidence" => "distinct evidence #{i}"
        })

      assert_reply ref, :ok, %{status: "submitted"}
    end

    overflow_ref =
      push(socket_a2, "conversation:report", %{
        "category" => "SPAM",
        "evidence" => "distinct evidence 11"
      })

    assert_reply overflow_ref, :error, %{code: "RATE_LIMITED"}

    assert Repo.aggregate(Report, :count, :report_id) == 10
    assert Repo.aggregate(SafetyReview, :count, :safety_review_id) == 10
    assert Repo.aggregate(SafetyEvent, :count, :safety_event_id) == 0
  end

  test "malformed report and block payloads create no durable safety state" do
    {conversation, participant_a, participant_b} = conversation_fixture()
    socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

    invalid_category =
      push(socket_a, "conversation:report", %{
        "category" => "NOT_A_CATEGORY",
        "evidence" => "invalid category"
      })

    assert_reply invalid_category, :error, %{code: "INVALID_REQUEST"}

    oversized =
      push(socket_a, "conversation:report", %{
        "category" => "SPAM",
        "evidence" => String.duplicate("x", Reports.max_evidence_bytes() + 1)
      })

    assert_reply oversized, :error, %{code: "INVALID_PAYLOAD"}

    extra_report_key =
      push(socket_a, "conversation:report", %{
        "category" => "SPAM",
        "evidence" => "ignored",
        "reported_participant_id" => participant_b.participant_id
      })

    assert_reply extra_report_key, :error, %{code: "INVALID_PAYLOAD"}

    malformed_block =
      push(socket_a, "conversation:block", %{"reason" => "client-controlled"})

    assert_reply malformed_block, :error, %{code: "INVALID_PAYLOAD"}

    assert Repo.aggregate(Report, :count, :report_id) == 0
    assert Repo.aggregate(SafetyReview, :count, :safety_review_id) == 0
    assert Repo.aggregate(SafetyEvent, :count, :safety_event_id) == 0
    assert Repo.aggregate(BoundaryBlock, :count) == 0
  end

  test "message-send exhaustion does not consume End Report or Block authority" do
    {end_conversation, end_actor, _end_peer} = conversation_fixture()
    end_socket = joined_conversation_socket(end_actor, end_conversation.conversation_id)
    exhaust_message_bucket(end_actor.participant_id)

    blocked_message =
      push(end_socket, "message:send", %{
        "message_id" => Ecto.UUID.generate(),
        "content" => "must be throttled"
      })

    assert_reply blocked_message, :error, %{code: "RATE_LIMITED"}
    end_ref = push(end_socket, "conversation:end", %{})
    assert_reply end_ref, :ok, %{status: "ended"}

    {report_conversation, report_actor, _report_peer} = conversation_fixture()
    report_socket = joined_conversation_socket(report_actor, report_conversation.conversation_id)
    exhaust_message_bucket(report_actor.participant_id)

    report_ref =
      push(report_socket, "conversation:report", %{
        "category" => "SPAM",
        "evidence" => "safety stays available"
      })

    assert_reply report_ref, :ok, %{status: "submitted"}

    {block_conversation, block_actor, _block_peer} = conversation_fixture()
    block_socket = joined_conversation_socket(block_actor, block_conversation.conversation_id)
    exhaust_message_bucket(block_actor.participant_id)

    block_ref = push(block_socket, "conversation:block", %{})
    assert_reply block_ref, :ok, %{status: "blocked"}
  end

  test "sibling-tab Block retries create one durable veto" do
    {conversation, participant_a, participant_b} = conversation_fixture()
    socket_a1 = joined_conversation_socket(participant_a, conversation.conversation_id)
    socket_a2 = joined_conversation_socket(participant_a, conversation.conversation_id)

    first_ref = push(socket_a1, "conversation:block", %{})
    assert_reply first_ref, :ok, %{status: "blocked"}

    second_ref = push(socket_a2, "conversation:block", %{})
    assert_reply second_ref, :ok, %{status: "blocked"}

    assert Repo.aggregate(BoundaryBlock, :count) == 1
    assert MatchingRules.check_safety_veto?(participant_a.participant_id, participant_b.participant_id)
  end

  test "terminal report is rejected while post-terminal Block preserves canonical ending and future veto" do
    {conversation, participant_a, participant_b} = conversation_fixture()
    socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

    end_ref = push(socket_a, "conversation:end", %{})
    assert_reply end_ref, :ok, %{status: "ended"}

    report_ref =
      push(socket_a, "conversation:report", %{
        "category" => "SPAM",
        "evidence" => "stale report"
      })

    assert_reply report_ref, :error, %{code: "CONVERSATION_UNAVAILABLE"}
    assert Repo.aggregate(Report, :count, :report_id) == 0

    block_ref = push(socket_a, "conversation:block", %{})
    assert_reply block_ref, :ok, %{status: "blocked"}

    terminal = Repo.get!(Conversation, conversation.conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :NATURAL_END
    assert Repo.aggregate(BoundaryBlock, :count) == 1
    assert MatchingRules.check_safety_veto?(participant_a.participant_id, participant_b.participant_id)
  end

  test "repeated Block does not rebroadcast terminal authority after the first applied action" do
    {conversation, participant_a, _participant_b} = conversation_fixture()
    topic = "conversation:#{conversation.conversation_id}"
    :ok = @endpoint.subscribe(topic)

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(
               conversation.conversation_id,
               participant_a.participant_id
             )

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "conversation:ended"}

    assert {:ok, _same_block} =
             MatchingRules.block_conversation_participant(
               conversation.conversation_id,
               participant_a.participant_id
             )

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "conversation:ended"}, 100
    assert Repo.aggregate(BoundaryBlock, :count) == 1
  end

  defp exhaust_message_bucket(participant_id) do
    for _ <- 1..@message_limit do
      assert :ok =
               RateLimiter.allow(
                 :message_send,
                 participant_id,
                 @message_limit,
                 @message_window_ms
               )
    end

    assert {:error, retry_after_ms} =
             RateLimiter.allow(
               :message_send,
               participant_id,
               @message_limit,
               @message_window_ms
             )

    assert retry_after_ms > 0
  end

  defp joined_conversation_socket(participant, conversation_id) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation_id}")

    socket
  end

  defp conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    now = DateTime.utc_now()

    {:ok, matching} =
      Matches.create_match(%{
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
      Conversations.create_conversation(%{
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

    {conversation, participant_a, participant_b}
  end

  defp participant_fixture do
    {:ok, participant} =
      Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: DateTime.utc_now(),
        last_active_at: DateTime.utc_now()
      })

    participant
  end
end
