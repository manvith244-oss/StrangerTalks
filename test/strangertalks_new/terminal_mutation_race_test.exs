defmodule StrangertalksNew.TerminalMutationRaceTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{Conversation, Repo}
  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  setup do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: true,
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

    {:ok, server_pid} = ConversationServer.ensure_started(conversation.conversation_id)
    :ok = ConversationServer.register_channel(conversation.conversation_id, participant_a.participant_id, self())

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation.conversation_id,
               participant_a.participant_id,
               message_id,
               "race seed"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(
               conversation.conversation_id,
               participant_b.participant_id,
               message_id
             )

    on_exit(fn ->
      case ConversationServer.lookup(conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    %{
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b,
      server_pid: server_pid,
      message_id: message_id
    }
  end

  test "End vs edit: terminal commit wins first", context do
    assert_terminal_wins(context, :edit)
  end

  test "End vs edit: edit commits first", context do
    assert_mutation_wins(context, :edit)
  end

  test "End vs unsend: terminal commit wins first", context do
    assert_terminal_wins(context, :unsend)
  end

  test "End vs unsend: unsend commits first", context do
    assert_mutation_wins(context, :unsend)
  end

  test "End vs reaction: terminal commit wins first", context do
    assert_terminal_wins(context, :reaction)
  end

  test "End vs reaction: reaction commits first", context do
    assert_mutation_wins(context, :reaction)
  end

  test "End vs pin: terminal commit wins first", context do
    assert_terminal_wins(context, :pin)
  end

  test "End vs pin: pin commits first", context do
    assert_mutation_wins(context, :pin)
  end

  defp assert_terminal_wins(context, mutation) do
    server_pid = context.server_pid
    monitor_ref = Process.monitor(server_pid)
    :ok = :sys.suspend(server_pid)

    end_task =
      staged_task(fn ->
        ConversationServer.complete_conversation(
          context.conversation.conversation_id,
          context.participant_a.participant_id
        )
      end)

    release_and_wait_for_call(server_pid, end_task, :complete_conversation)

    mutation_task = staged_task(fn -> perform_mutation(mutation, context) end)
    release_and_wait_for_call(server_pid, mutation_task, mutation_call_tag(mutation))

    :ok = :sys.resume(server_pid)

    assert {:ok, %{status: "ended"}} = Task.await(end_task, 5_000)
    assert {:error, :conversation_unavailable} = Task.await(mutation_task, 5_000)
    assert_receive {:DOWN, ^monitor_ref, :process, ^server_pid, :normal}

    assert_terminal_truth(context)
    assert_terminal_client_event_once()
    assert {:error, :conversation_unavailable} = perform_mutation(mutation, context)
  end

  defp assert_mutation_wins(context, mutation) do
    server_pid = context.server_pid
    monitor_ref = Process.monitor(server_pid)
    :ok = :sys.suspend(server_pid)

    mutation_task = staged_task(fn -> perform_mutation(mutation, context) end)
    release_and_wait_for_call(server_pid, mutation_task, mutation_call_tag(mutation))

    end_task =
      staged_task(fn ->
        ConversationServer.complete_conversation(
          context.conversation.conversation_id,
          context.participant_a.participant_id
        )
      end)

    release_and_wait_for_call(server_pid, end_task, :complete_conversation)

    :ok = :sys.resume(server_pid)

    assert {:ok, %{status: "applied"}} = Task.await(mutation_task, 5_000)
    assert {:ok, %{status: "ended"}} = Task.await(end_task, 5_000)
    assert_receive {:DOWN, ^monitor_ref, :process, ^server_pid, :normal}

    assert_terminal_truth(context)
    assert_terminal_client_event_once()
    assert {:error, :conversation_unavailable} = perform_mutation(mutation, context)
  end

  defp staged_task(fun) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:race_task_ready, self()})

        receive do
          :race_go -> fun.()
        end
      end)

    assert_receive {:race_task_ready, task_pid}
    assert task_pid == task.pid
    task
  end

  defp release_and_wait_for_call(server_pid, task, call_tag) do
    send(task.pid, :race_go)
    assert_call_queued(server_pid, call_tag)
  end

  defp assert_call_queued(server_pid, call_tag, attempts \\ 10_000)
  defp assert_call_queued(_server_pid, call_tag, 0), do: flunk("#{call_tag} call was not queued")

  defp assert_call_queued(server_pid, call_tag, attempts) do
    queued? =
      case Process.info(server_pid, :messages) do
        {:messages, messages} -> Enum.any?(messages, &queued_call?(&1, call_tag))
        nil -> false
      end

    if queued? do
      :ok
    else
      :erlang.yield()
      assert_call_queued(server_pid, call_tag, attempts - 1)
    end
  end

  defp queued_call?({:"$gen_call", _from, request}, call_tag) when is_tuple(request) do
    tuple_size(request) > 0 and elem(request, 0) == call_tag
  end

  defp queued_call?(_message, _call_tag), do: false

  defp perform_mutation(:edit, context) do
    ConversationServer.edit_message(
      context.conversation.conversation_id,
      context.participant_a.participant_id,
      context.message_id,
      0,
      "edited before terminal"
    )
  end

  defp perform_mutation(:unsend, context) do
    ConversationServer.unsend_message(
      context.conversation.conversation_id,
      context.participant_a.participant_id,
      context.message_id,
      0
    )
  end

  defp perform_mutation(:reaction, context) do
    ConversationServer.mutate_reaction(
      context.conversation.conversation_id,
      context.participant_a.participant_id,
      context.message_id,
      "❤️",
      0
    )
  end

  defp perform_mutation(:pin, context) do
    ConversationServer.mutate_pin(
      context.conversation.conversation_id,
      context.participant_a.participant_id,
      context.message_id,
      true,
      0
    )
  end

  defp mutation_call_tag(:edit), do: :edit_message
  defp mutation_call_tag(:unsend), do: :unsend_message
  defp mutation_call_tag(:reaction), do: :mutate_reaction
  defp mutation_call_tag(:pin), do: :mutate_pin

  defp assert_terminal_truth(context) do
    terminal = Repo.get!(Conversation, context.conversation.conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator == context.participant_a.participant_id
    assert terminal.conversation_completed == true
    assert terminal.safety_flagged == false
    assert ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}

    assert {:error, :terminal_conversation} =
             ConversationServer.ensure_started(context.conversation.conversation_id)
  end

  defp assert_terminal_client_event_once do
    assert_receive {:conversation_completed, %{status: "ended", reason: "participant_completed"}}
    refute_receive {:conversation_completed, _payload}
  end
end
