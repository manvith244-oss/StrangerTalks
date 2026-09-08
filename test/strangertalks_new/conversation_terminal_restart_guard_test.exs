defmodule StrangertalksNew.ConversationTerminalRestartGuardTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Repo

  defp conversation_fixture(status) do
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
        conversation_status: status,
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

    on_exit(fn ->
      case ConversationServer.lookup(conversation.conversation_id) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            DynamicSupervisor.terminate_child(
              StrangertalksNew.ConversationDynamicSupervisor,
              pid
            )
          end

        {:error, :not_started} ->
          :ok
      end
    end)

    %{conversation: conversation, a: a.participant_id, b: b.participant_id}
  end

  describe "canonical durable-End restart guard" do
    test "active Conversation can start normally and repeated calls return the same alive process" do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      assert Process.alive?(pid)
      assert {:ok, ^pid} = ConversationServer.lookup(conversation_id)

      # Repeated calls return the active process
      assert {:ok, ^pid} = ConversationServer.ensure_started(conversation_id)
      assert {:ok, ^pid} = ConversationServer.ensure_started(conversation_id)
    end

    test "durably ended Conversation cannot restart after complete_conversation" do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      monitor = Process.monitor(pid)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, fixture.a)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

      # Durable record is ENDED
      terminal = Repo.get!(Conversation, conversation_id)
      assert terminal.conversation_status == :ENDED

      # Canonical restart denial: must NOT regain active Conversation authority
      assert {:error, :terminal_conversation} =
               ConversationServer.ensure_started(conversation_id)

      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
    end

    test "repeated ensure_started calls after durable End consistently remain terminal" do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      monitor = Process.monitor(pid)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, fixture.a)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

      # Sequential repeated ensure_started calls
      for _ <- 1..5 do
        assert {:error, :terminal_conversation} =
                 ConversationServer.ensure_started(conversation_id)
      end

      # Concurrent restart attempts fail closed
      results =
        1..10
        |> Task.async_stream(
          fn _ -> ConversationServer.ensure_started(conversation_id) end,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &(&1 == {:error, :terminal_conversation}))
      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
    end

    test "restart denial comes from canonical durable authority, not an in-memory-only flag" do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      assert Process.alive?(pid)

      # Mutate durable state in the database directly to each terminal status
      for terminal_status <- [:ENDED, :ABANDONED, :FAILED] do
        {1, _} =
          Repo.update_all(
            from(c in Conversation, where: c.conversation_id == ^conversation_id),
            set: [conversation_status: terminal_status]
          )

        # Even if a caller calls ensure_started, durable state denies authority
        assert {:error, :terminal_conversation} =
                 ConversationServer.ensure_started(conversation_id)

        assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
      end
    end

    test "ensure_started cleans up stale in-memory process if conversation is durably terminal" do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      assert Process.alive?(pid)

      # Mark durable status as ENDED behind the running process
      {1, _} =
        Repo.update_all(
          from(c in Conversation, where: c.conversation_id == ^conversation_id),
          set: [conversation_status: :ENDED]
        )

      # ensure_started must deny active authority AND clean up the stale process
      assert {:error, :terminal_conversation} =
               ConversationServer.ensure_started(conversation_id)

      refute Process.alive?(pid)
      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
    end

    test "reconnect and recovery attempts fail closed on durably terminal conversation" do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      monitor = Process.monitor(pid)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, fixture.a)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

      # Reconnect / sync / message append cannot restart or gain authority
      assert {:error, :terminal_conversation} =
               ConversationServer.ensure_started(conversation_id)

      assert {:error, :conversation_unavailable} =
               ConversationServer.register_channel(conversation_id, fixture.a, self())

      assert {:error, :conversation_unavailable} =
               ConversationServer.append_message(
                 conversation_id,
                 fixture.a,
                 Ecto.UUID.generate(),
                 "stale write"
               )
    end
  end
end
