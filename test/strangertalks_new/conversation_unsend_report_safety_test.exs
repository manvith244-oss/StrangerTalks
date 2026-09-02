defmodule StrangertalksNew.ConversationUnsendReportSafetyTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.{Report, Reports, Repo}

  setup do
    fixture = conversation_fixture()

    start_supervised!(
      {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
    )

    Map.put(fixture, :task_supervisor, start_supervised!(Task.Supervisor))
  end

  test "REPORT-BEFORE-UNSEND captures current server evidence and remains stable after Unsend",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.author,
               target_id,
               "report first"
             )

    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation_id,
               context.reporter,
               "HARASSMENT",
               "browser claim must not win",
               target_id
             )

    assert report.reporter_context == "report first"

    assert {:ok, %{status: "applied"}} =
             ConversationServer.unsend_message(conversation_id, context.author, target_id, 0)

    retained = Reports.get_report(report.report_id)
    assert retained.reporter_context == "report first"
    assert retained.report_status == :SUBMITTED
  end

  test "UNSEND-BEFORE-REPORT consumes exactly the current-canonical private snapshot", context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.author,
               target_id,
               "original"
             )

    assert {:ok, _} =
             ConversationServer.edit_message(
               conversation_id,
               context.author,
               target_id,
               0,
               "edited current"
             )

    assert {:ok, _} =
             ConversationServer.unsend_message(conversation_id, context.author, target_id, 1)

    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation_id,
               context.reporter,
               "THREATS",
               "forged stale browser text",
               target_id
             )

    assert report.reporter_context == "edited current"
    refute report.reporter_context =~ "original"
    refute report.reporter_context =~ "forged"
  end

  test "REPORT-UNSEND-RACE capture wins before Unsend and accepted durable evidence stays stable",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.author,
               target_id,
               "captured winner"
             )

    parent = self()
    handler_id = "report-unsend-capture-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :report_evidence, :current_content],
        fn _event, _measurements, _metadata, _config ->
          send(parent, {:capture_reached, self()})

          receive do
            :release_report_capture -> :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    report_task =
      Task.Supervisor.async_nolink(context.task_supervisor, fn ->
        Reports.submit_conversation_report(
          conversation_id,
          context.reporter,
          "HARASSMENT",
          nil,
          target_id
        )
      end)

    assert_receive {:capture_reached, server_pid}

    unsend_task =
      Task.Supervisor.async_nolink(context.task_supervisor, fn ->
        ConversationServer.unsend_message(conversation_id, context.author, target_id, 0)
      end)

    send(server_pid, :release_report_capture)

    assert {:ok, report} = Task.await(report_task)
    assert {:ok, %{status: "applied"}} = Task.await(unsend_task)
    assert Reports.get_report(report.report_id).reporter_context == "captured winner"
  end

  test "REPORT-UNSEND-RACE Unsend wins and report capture uses snapshot before later pruning",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.author,
               target_id,
               "snapshot winner"
             )

    assert {:ok, _} =
             ConversationServer.unsend_message(conversation_id, context.author, target_id, 0)

    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation_id,
               context.reporter,
               "SPAM",
               "stale browser copy",
               target_id
             )

    for index <- 1..50 do
      message_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationServer.append_message(
                 conversation_id,
                 context.author,
                 message_id,
                 "prune #{index}"
               )

      assert {:ok, _} =
               ConversationServer.acknowledge_message(
                 conversation_id,
                 context.reporter,
                 message_id
               )
    end

    assert Reports.get_report(report.report_id).reporter_context == "snapshot winner"
  end

  test "SNAPSHOT-ABSENT stale browser evidence is never promoted into a durable targeted report",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()
    secret = "must disappear from authority"

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, context.author, target_id, secret)

    assert {:ok, _} =
             ConversationServer.unsend_message(conversation_id, context.author, target_id, 0)

    for index <- 1..50 do
      message_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationServer.append_message(
                 conversation_id,
                 context.author,
                 message_id,
                 "bounded #{index}"
               )

      assert {:ok, _} =
               ConversationServer.acknowledge_message(
                 conversation_id,
                 context.reporter,
                 message_id
               )
    end

    count_before = Repo.aggregate(Report, :count)

    assert {:error, :target_absent} =
             Reports.submit_conversation_report(
               conversation_id,
               context.reporter,
               "SPAM",
               secret,
               target_id
             )

    assert Repo.aggregate(Report, :count) == count_before
  end

  test "REPORT-ORACLE reported and unreported messages have identical sender-visible Unsend semantics",
       context do
    conversation_id = context.conversation.conversation_id
    reported_id = Ecto.UUID.generate()
    ordinary_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.author,
               reported_id,
               "reported"
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.author,
               ordinary_id,
               "ordinary"
             )

    assert {:ok, _report} =
             Reports.submit_conversation_report(
               conversation_id,
               context.reporter,
               "SPAM",
               nil,
               reported_id
             )

    assert {:ok, reported_result} =
             ConversationServer.unsend_message(conversation_id, context.author, reported_id, 0)

    assert {:ok, ordinary_result} =
             ConversationServer.unsend_message(conversation_id, context.author, ordinary_id, 0)

    assert Map.drop(reported_result, [:client_message_id, :message_id, :sequence]) ==
             Map.drop(ordinary_result, [:client_message_id, :message_id, :sequence])
  end

  defp conversation_fixture do
    {:ok, author} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, reporter} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: author.participant_id,
        participant_b_id: reporter.participant_id,
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
        match_id: match.match_id,
        participant_a_id: author.participant_id,
        participant_b_id: reporter.participant_id,
        conversation_status: :PENDING,
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
      author: author.participant_id,
      reporter: reporter.participant_id
    }
  end
end
