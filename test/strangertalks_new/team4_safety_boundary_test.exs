defmodule StrangertalksNew.Team4SafetyBoundaryTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{Conversation, MatchingRules, Report, Repo, Reports, SafetyReview}

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "RECOVERY-BLOCK crash recovery cannot resurrect Conversation after Block becomes authoritative" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               b.participant_id,
               self(),
               nil,
               0
             )

    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE

    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    recovery_task =
      Task.async(fn ->
        case ConversationServer.ensure_started(conversation_id) do
          {:ok, _replacement} ->
            ConversationServer.sync_and_register_channel(
              conversation_id,
              b.participant_id,
              self(),
              nil,
              0
            )

          error ->
            error
        end
      end)

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(conversation_id, a.participant_id)

    _recovery_result = Task.await(recovery_task, 5_000)

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :BLOCK
    assert terminal.ending_initiator == a.participant_id
    assert terminal.safety_flagged == true
    assert terminal.conversation_completed == false

    assert_eventually(fn ->
      ConversationServer.lookup(conversation_id) == {:error, :not_started}
    end)

    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)

    assert {:error, :conversation_unavailable} =
             ConversationServer.append_message(
               conversation_id,
               b.participant_id,
               Ecto.UUID.generate(),
               "stale recovery send must lose"
             )

    assert MatchingRules.check_safety_veto?(a.participant_id, b.participant_id)
  end

  test "REPORT-BLOCK both orderings preserve one-way safety authority without changing report evidence" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id

    assert {:ok, %Report{} = before_block} =
             Reports.submit_conversation_report(
               conversation_id,
               a.participant_id,
               "HARASSMENT",
               "participant context before block"
             )

    assert before_block.reporting_participant_id == a.participant_id
    assert before_block.reported_participant_id == b.participant_id

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(conversation_id, a.participant_id)

    assert Reports.get_report(before_block.report_id).reporter_context ==
             "participant context before block"

    assert {:ok, %Report{} = after_block} =
             Reports.submit_conversation_report(
               conversation_id,
               a.participant_id,
               "THREATS",
               "participant context after block"
             )

    assert after_block.reporting_participant_id == a.participant_id
    assert after_block.reported_participant_id == b.participant_id
    assert Repo.get_by!(SafetyReview, report_id: after_block.report_id).status == :PENDING
    assert MatchingRules.check_safety_veto?(a.participant_id, b.participant_id)
  end

  test "REPORT-AUTHORITY rejects malformed category, nonmember and wrong Conversation while deriving peer" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    outsider = participant_fixture()

    assert {:error, :invalid_report_category} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               a.participant_id,
               "NOT_A_REAL_CATEGORY",
               nil
             )

    assert {:error, :not_conversation_member} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               outsider.participant_id,
               "SPAM",
               nil
             )

    assert {:error, :conversation_not_found} =
             Reports.submit_conversation_report(
               Ecto.UUID.generate(),
               a.participant_id,
               "SPAM",
               nil
             )

    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               a.participant_id,
               "SPAM",
               "bounded context"
             )

    assert report.reporting_participant_id == a.participant_id
    assert report.reported_participant_id == b.participant_id
  end

  test "REPORT-END remains available to a Conversation member without resurrecting terminal authority" do
    %{conversation: conversation, a: a} = queue_match()
    conversation_id = conversation.conversation_id
    _pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    assert {:ok, _result} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    assert_eventually(fn ->
      ConversationServer.lookup(conversation_id) == {:error, :not_started}
    end)

    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation_id,
               a.participant_id,
               "SPAM",
               "bounded post-end safety context"
             )

    assert report.report_status == :SUBMITTED
    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)
  end

  test "EDIT-REPORT evidence freezes the current targeted snapshot at report creation only" do
    %{conversation: conversation, a: author, b: reporter} = queue_match()
    conversation_id = conversation.conversation_id
    _pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               author.participant_id,
               self(),
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               reporter.participant_id,
               self(),
               nil,
               0
             )

    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               author.participant_id,
               message_id,
               "message v1"
             )

    assert {:ok, report_v1} =
             Reports.submit_conversation_report(
               conversation_id,
               reporter.participant_id,
               "HARASSMENT",
               "browser evidence must not win",
               message_id
             )

    assert report_v1.reporter_context == "message v1"

    assert {:ok, %{status: "applied", content_revision: 1}} =
             ConversationServer.edit_message(
               conversation_id,
               author.participant_id,
               message_id,
               0,
               "message v2"
             )

    assert Reports.get_report(report_v1.report_id).reporter_context == "message v1"

    assert {:ok, report_v2} =
             Reports.submit_conversation_report(
               conversation_id,
               reporter.participant_id,
               "THREATS",
               "stale browser evidence",
               message_id
             )

    assert report_v2.reporter_context == "message v2"
    refute report_v2.reporter_context =~ "v1"
  end

  defp queue_match do
    a = participant_fixture()
    b = participant_fixture()

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    %{
      conversation: Repo.get_by!(Conversation, match_id: match_id),
      a: a,
      b: b
    }
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
