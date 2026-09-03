defmodule StrangertalksNew.T02RecoveryConvergenceHostileTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  @rounds 40
  @concurrent_starters 32

  test "crash recovery never returns more than one replacement ConversationServer authority" do
    for round <- 1..@rounds do
      fixture = conversation_fixture()
      conversation_id = fixture.conversation.conversation_id
      {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)

      monitor = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

      parent = self()

      tasks =
        for _ <- 1..@concurrent_starters do
          Task.async(fn ->
            send(parent, {:t02_ready, self()})

            receive do
              :t02_start -> ConversationServer.ensure_started(conversation_id)
            end
          end)
        end

      task_pids =
        for _ <- 1..@concurrent_starters do
          assert_receive {:t02_ready, task_pid}
          task_pid
        end

      Enum.each(task_pids, &send(&1, :t02_start))
      results = Enum.map(tasks, &Task.await(&1, :infinity))

      assert Enum.all?(results, &match?({:ok, pid} when is_pid(pid), &1)),
             "round #{round} returned non-success recovery results: #{inspect(results)}"

      replacement_pids = Enum.map(results, fn {:ok, pid} -> pid end)
      unique_replacements = Enum.uniq(replacement_pids)

      assert [replacement] = unique_replacements,
             "round #{round} returned multiple replacement authorities: #{inspect(unique_replacements)}"

      refute replacement == old_pid
      assert Process.alive?(replacement)
      assert {:ok, ^replacement} = ConversationServer.lookup(conversation_id)

      assert :ok =
               DynamicSupervisor.terminate_child(
                 StrangertalksNew.ConversationDynamicSupervisor,
                 replacement
               )

      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
    end
  end

  defp conversation_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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

    %{conversation: conversation}
  end
end
