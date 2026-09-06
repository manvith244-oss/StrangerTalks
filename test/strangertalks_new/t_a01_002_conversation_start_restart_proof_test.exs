defmodule StrangertalksNew.TA01002ConversationStartRestartProofTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.IcebreakerCatalog

  test "retired Conversation Start remains retired after real ConversationServer replacement" do
    fixture = conversation_fixture("en")
    conversation_id = fixture.conversation.conversation_id

    {:ok, old_pid} = ConversationServer.ensure_started(conversation_id)

    on_exit(fn ->
      case ConversationServer.lookup(conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    assert {:ok, initial} = ConversationServer.inspect_state(conversation_id)
    assert {:active, identity} = initial.icebreaker
    assert String.starts_with?(identity, "en/")
    assert IcebreakerCatalog.approved?(identity)

    IO.puts("T_A01_002_INITIAL_PID=#{inspect(old_pid)}")
    IO.puts("T_A01_002_INITIAL_EPOCH=#{initial.epoch_id}")
    IO.puts("T_A01_002_INITIAL_STARTER=#{inspect(initial.icebreaker)}")

    :ok = ConversationServer.register_channel(conversation_id, fixture.a, self())
    :ok = ConversationServer.register_channel(conversation_id, fixture.b, self())

    assert {:ok, %{sequence: 1, status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               fixture.a,
               Ecto.UUID.generate(),
               "A genuine first human message"
             )

    retirement_events = collect_icebreaker_events([])

    assert retirement_events == [
             %{status: "retired"},
             %{status: "retired"}
           ]

    assert {:ok, retired} = ConversationServer.inspect_state(conversation_id)
    assert retired.icebreaker == :retired
    assert retired.next_sequence == 2

    IO.puts("T_A01_002_PRE_RESTART_STATE=#{inspect(retired.icebreaker)}")
    IO.puts("T_A01_002_RETIREMENT_FANOUT=#{inspect(retirement_events)}")

    assert {:ok, same_runtime_sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               fixture.b,
               self(),
               retired.epoch_id,
               1
             )

    assert same_runtime_sync.icebreaker == %{status: "retired"}
    assert {:ok, ^old_pid} = ConversationServer.lookup(conversation_id)

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    assert {:ok, replacement_pid} = ConversationServer.ensure_started(conversation_id)
    refute replacement_pid == old_pid
    assert {:ok, ^replacement_pid} = ConversationServer.lookup(conversation_id)

    assert {:ok, replacement} = ConversationServer.inspect_state(conversation_id)
    refute replacement.epoch_id == retired.epoch_id

    assert {:ok, replacement_sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               fixture.b,
               self(),
               retired.epoch_id,
               1
             )

    post_restart_fanout = collect_icebreaker_events([])

    IO.puts("T_A01_002_REPLACEMENT_PID=#{inspect(replacement_pid)}")
    IO.puts("T_A01_002_REPLACEMENT_EPOCH=#{replacement.epoch_id}")
    IO.puts("T_A01_002_POST_RESTART_STATE=#{inspect(replacement.icebreaker)}")
    IO.puts("T_A01_002_POST_RESTART_SYNC_STARTER=#{inspect(replacement_sync.icebreaker)}")
    IO.puts("T_A01_002_POST_RESTART_FANOUT=#{inspect(post_restart_fanout)}")

    publication_result =
      if replacement_sync.icebreaker == %{status: "retired"} do
        "NO_DUPLICATE_STARTER_PUBLICATION"
      else
        "DUPLICATE_STARTER_PUBLICATION_VIA_SYNC"
      end

    IO.puts("T_A01_002_PUBLICATION_RESULT=#{publication_result}")

    assert replacement.icebreaker == :retired
    assert replacement_sync.icebreaker == %{status: "retired"}
    assert post_restart_fanout == []
  end

  defp collect_icebreaker_events(acc) do
    receive do
      {:conversation_icebreaker, payload} ->
        collect_icebreaker_events([payload | acc])
    after
      30 -> Enum.reverse(acc)
    end
  end

  defp conversation_fixture(language) do
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
        conversation_language: language,
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

    %{conversation: conversation, a: a.participant_id, b: b.participant_id}
  end
end
