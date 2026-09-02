defmodule StrangertalksNew.RuntimeTerminalContractTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.{Matching, Repo}

  test "realtime terminal classifier recognizes exactly canonical T01 terminal statuses" do
    for status <- [:ENDED, :ABANDONED, :FAILED] do
      assert ConversationServer.release_terminal_status?(status)
    end

    for status <- [:PENDING, :ACTIVE, :PAUSED, :COMPLETED] do
      refute ConversationServer.release_terminal_status?(status)
    end
  end

  test "durable ENDED ABANDONED and FAILED conversations refuse runtime startup" do
    for status <- [:ENDED, :ABANDONED, :FAILED] do
      fixture = conversation_fixture(status)
      conversation_id = fixture.conversation.conversation_id

      assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)
      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
      assert Repo.get!(Conversation, conversation_id).conversation_status == status
    end
  end

  test "PENDING ACTIVE and PAUSED conversations may reconstruct runtime without rewriting durable status" do
    for status <- [:PENDING, :ACTIVE, :PAUSED] do
      fixture = conversation_fixture(status)
      conversation_id = fixture.conversation.conversation_id

      assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      assert {:ok, ^pid} = ConversationServer.lookup(conversation_id)
      assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
      assert state.lifecycle_status == :ACTIVE
      assert state.conversation.conversation_status == status
      assert Repo.get!(Conversation, conversation_id).conversation_status == status

      assert :ok =
               DynamicSupervisor.terminate_child(
                 StrangertalksNew.ConversationDynamicSupervisor,
                 pid
               )

      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
    end
  end

  test "terminal durable truth survives death of previously live runtime authority" do
    for status <- [:ENDED, :ABANDONED, :FAILED] do
      fixture = conversation_fixture(:ACTIVE)
      conversation_id = fixture.conversation.conversation_id
      assert {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)

      terminalize!(fixture.conversation, status)

      assert :ok =
               DynamicSupervisor.terminate_child(
                 StrangertalksNew.ConversationDynamicSupervisor,
                 old_pid
               )

      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
      assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)
      assert {:error, :not_started} = ConversationServer.lookup(conversation_id)
      assert Repo.get!(Conversation, conversation_id).conversation_status == status
    end
  end

  test "ACTIVE ConversationServer crash reconstructs one fresh epoch and loses only live buffer state" do
    fixture = conversation_fixture(:ACTIVE)
    conversation_id = fixture.conversation.conversation_id
    assert {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, fixture.a, self())
    :ok = ConversationServer.register_channel(conversation_id, fixture.b, self())
    assert {:ok, before} = ConversationServer.inspect_state(conversation_id)

    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation_id,
               fixture.a,
               message_id,
               "restart-boundary"
             )

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    assert {:ok, replacement} = ConversationServer.ensure_started(conversation_id)
    refute replacement == old_pid
    assert {:ok, after_crash} = ConversationServer.inspect_state(conversation_id)
    refute after_crash.epoch_id == before.epoch_id
    assert after_crash.pending_count == 0
    assert after_crash.recent_messages == []
    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
  end

  test "old epoch callback cannot mutate replacement ConversationServer generation" do
    fixture = conversation_fixture(:ACTIVE)
    conversation_id = fixture.conversation.conversation_id
    assert {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, fixture.a, self())
    :ok = ConversationServer.register_channel(conversation_id, fixture.b, self())
    assert {:ok, before} = ConversationServer.inspect_state(conversation_id)

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    assert {:ok, replacement} = ConversationServer.ensure_started(conversation_id)
    refute replacement == old_pid
    assert {:ok, replacement_before} = ConversationServer.inspect_state(conversation_id)
    refute replacement_before.epoch_id == before.epoch_id

    assert {:ok, %{status: "stale", highest_contiguous_sequence: 0}} =
             ConversationServer.report_delivery_progress(
               conversation_id,
               fixture.b,
               self(),
               before.epoch_id,
               0
             )

    assert {:ok, replacement_after} = ConversationServer.inspect_state(conversation_id)
    assert replacement_after.epoch_id == replacement_before.epoch_id
    assert replacement_after.delivery_progress == replacement_before.delivery_progress
    assert replacement_after.pending_count == replacement_before.pending_count
    assert replacement_after.recent_messages == replacement_before.recent_messages
  end

  defp terminalize!(conversation, status) do
    attrs =
      case status do
        :ENDED ->
          %{
            conversation_status: :ENDED,
            conversation_completed: true,
            ending_type: :NATURAL_END,
            ended_at: DateTime.utc_now()
          }

        :ABANDONED ->
          %{
            conversation_status: :ABANDONED,
            conversation_completed: false,
            ending_type: :TIMEOUT,
            ended_at: DateTime.utc_now()
          }

        :FAILED ->
          %{
            conversation_status: :FAILED,
            conversation_completed: false,
            ending_type: :DISCONNECT,
            ended_at: DateTime.utc_now()
          }
      end

    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update!()
  end

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

    conversation =
      if status == :PENDING do
        conversation
      else
        attrs =
          if status in [:ENDED, :ABANDONED, :FAILED] do
            terminal_attrs(status)
          else
            %{conversation_status: status}
          end

        conversation
        |> Conversation.changeset(attrs)
        |> Repo.update!()
      end

    %{conversation: conversation, a: a.participant_id, b: b.participant_id}
  end

  defp terminal_attrs(:ENDED),
    do: %{
      conversation_status: :ENDED,
      conversation_completed: true,
      ending_type: :NATURAL_END,
      ended_at: DateTime.utc_now()
    }

  defp terminal_attrs(:ABANDONED),
    do: %{
      conversation_status: :ABANDONED,
      conversation_completed: false,
      ending_type: :TIMEOUT,
      ended_at: DateTime.utc_now()
    }

  defp terminal_attrs(:FAILED),
    do: %{
      conversation_status: :FAILED,
      conversation_completed: false,
      ending_type: :DISCONNECT,
      ended_at: DateTime.utc_now()
    }
end
