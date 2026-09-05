defmodule StrangertalksNew.TerminalObservabilityTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{Conversation, MatchingRules, Repo}
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, RecoverySweeper}
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  @events [
    [:strangertalks_new, :terminal, :request_accepted],
    [:strangertalks_new, :terminal, :durable_commit],
    [:strangertalks_new, :terminal, :client_notification],
    [:strangertalks_new, :terminal, :runtime_cleanup],
    [:strangertalks_new, :terminal, :persistence_failed],
    [:strangertalks_new, :terminal, :authority_disagreement],
    [:strangertalks_new, :terminal, :stale_action_rejected],
    [:strangertalks_new, :conversation, :join, :failed]
  ]

  setup do
    handler_id = "team2-terminal-observability-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event, measurements, metadata, receiver ->
          send(receiver, {:terminal_observability, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "normal End emits bounded request, durable commit, client notification, and runtime cleanup checkpoints" do
    %{conversation: conversation, a: a} = active_fixture()
    {:ok, _pid} = ConversationServer.ensure_started(conversation.conversation_id)

    :ok =
      ConversationServer.register_channel(conversation.conversation_id, a.participant_id, self())

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(
               conversation.conversation_id,
               a.participant_id
             )

    assert_event(
      [:strangertalks_new, :terminal, :request_accepted],
      %{terminal_status: :ENDED, lifecycle_event: :participant_completed}
    )

    assert_event(
      [:strangertalks_new, :terminal, :durable_commit],
      %{terminal_status: :ENDED, lifecycle_event: :participant_completed}
    )

    assert_event(
      [:strangertalks_new, :terminal, :client_notification],
      %{terminal_reason: :participant_completed, notification_path: :conversation_bus}
    )

    assert_receive {:terminal_observability, [:strangertalks_new, :terminal, :runtime_cleanup],
                    %{count: 1}, runtime_metadata},
                   1_000

    assert runtime_metadata.terminal_reason == :participant_completed
    assert runtime_metadata.cleanup_path in [:process_down, :already_stopped]
    assert_private_metadata_absent(runtime_metadata)
  end

  test "terminal persistence failure emits bounded failure telemetry and no false durable commit" do
    %{conversation: conversation, a: a} = active_fixture()
    {:ok, pid} = ConversationServer.ensure_started(conversation.conversation_id)

    :ok =
      ConversationServer.register_channel(conversation.conversation_id, a.participant_id, self())

    durable_active = Repo.get!(Conversation, conversation.conversation_id)

    :sys.replace_state(pid, fn state ->
      %{state | conversation: %{state.conversation | participant_b_id: nil}}
    end)

    assert {:ok, %{status: "ending"}} =
             ConversationServer.complete_conversation(
               conversation.conversation_id,
               a.participant_id
             )

    assert_receive {:terminal_observability, [:strangertalks_new, :terminal, :persistence_failed],
                    %{count: 1}, metadata},
                   1_000

    assert metadata.terminal_status == :ENDED
    assert metadata.lifecycle_event == :participant_completed
    assert is_binary(metadata.reason_code) or metadata.reason_code == :redacted
    assert_private_metadata_absent(metadata)

    refute_receive {:terminal_observability, [:strangertalks_new, :terminal, :durable_commit],
                    _measurements, _metadata},
                   100

    :sys.replace_state(pid, fn state -> %{state | conversation: durable_active} end)
  end

  test "RecoverySweeper reports durable-vs-runtime disagreement with bounded state only" do
    %{conversation: conversation} = active_fixture()

    assert {:error, :not_started} = ConversationServer.lookup(conversation.conversation_id)
    assert :ok = RecoverySweeper.sweep_orphans()

    assert_event(
      [:strangertalks_new, :terminal, :authority_disagreement],
      %{durable_status: :ACTIVE, runtime_status: :not_started, detection_path: :runtime_orphan}
    )

    terminal = Repo.get!(Conversation, conversation.conversation_id)
    assert terminal.conversation_status == :ABANDONED
    assert terminal.ending_type == :TIMEOUT
  end

  test "Block durable commit, client notification, runtime cleanup, and stale post-End Block are observable without identifiers" do
    %{conversation: conversation, a: a, b: b} = active_fixture()
    {:ok, _pid} = ConversationServer.ensure_started(conversation.conversation_id)

    :ok =
      ConversationServer.register_channel(conversation.conversation_id, a.participant_id, self())

    :ok =
      ConversationServer.register_channel(conversation.conversation_id, b.participant_id, self())

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(
               conversation.conversation_id,
               a.participant_id
             )

    assert_event(
      [:strangertalks_new, :terminal, :durable_commit],
      %{terminal_status: :ENDED, lifecycle_event: :safety_terminated}
    )

    assert_event(
      [:strangertalks_new, :terminal, :client_notification],
      %{terminal_reason: :blocked, notification_path: :block_broadcast}
    )

    assert_event(
      [:strangertalks_new, :terminal, :runtime_cleanup],
      %{terminal_reason: :blocked, cleanup_path: :block_suspended_runtime}
    )

    second = active_fixture()
    {:ok, _pid} = ConversationServer.ensure_started(second.conversation.conversation_id)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(
               second.conversation.conversation_id,
               second.a.participant_id
             )

    drain_observability()

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(
               second.conversation.conversation_id,
               second.b.participant_id
             )

    assert_event(
      [:strangertalks_new, :terminal, :stale_action_rejected],
      %{terminal_action: :block, canonical_ending: :natural_end}
    )

    refute_receive {:terminal_observability,
                    [:strangertalks_new, :terminal, :client_notification], _measurements,
                    %{terminal_reason: :blocked}},
                   100
  end

  test "terminal channel rejoin rejection emits bounded maintained join-failure signal" do
    %{conversation: conversation, a: a} = active_fixture()

    conversation
    |> Conversation.changeset(%{
      conversation_status: :ENDED,
      conversation_completed: true,
      ending_type: :NATURAL_END,
      ended_at: DateTime.utc_now()
    })
    |> Repo.update!()

    token = ParticipantToken.sign(a.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    assert {:error, _reason} =
             subscribe_and_join(
               socket,
               ConversationChannel,
               "conversation:#{conversation.conversation_id}",
               %{}
             )

    assert_receive {:terminal_observability, [:strangertalks_new, :conversation, :join, :failed],
                    %{count: 1}, metadata},
                   1_000

    assert is_binary(metadata.reason_code) or metadata.reason_code == :redacted
    assert_private_metadata_absent(metadata)
  end

  defp assert_event(event, expected_metadata) do
    assert_receive {:terminal_observability, ^event, %{count: 1}, metadata}, 1_000

    Enum.each(expected_metadata, fn {key, expected} ->
      assert Map.fetch!(metadata, key) == expected
    end)

    assert_private_metadata_absent(metadata)
  end

  defp assert_private_metadata_absent(metadata) do
    forbidden = [
      :participant_id,
      :conversation_id,
      :message_id,
      :client_message_id,
      :voice_note_id,
      :content,
      :text,
      :audio,
      :token,
      :credentials,
      :call_attempt_id
    ]

    Enum.each(forbidden, fn key -> refute Map.has_key?(metadata, key) end)

    Enum.each(Map.keys(metadata), fn key ->
      normalized = key |> to_string() |> String.downcase()
      refute String.ends_with?(normalized, "_id")
      refute String.contains?(normalized, "token")
      refute String.contains?(normalized, "secret")
      refute String.contains?(normalized, "credential")
    end)
  end

  defp drain_observability do
    receive do
      {:terminal_observability, _event, _measurements, _metadata} -> drain_observability()
    after
      0 -> :ok
    end
  end

  defp active_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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
        match_id: matching.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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

    on_exit(fn ->
      case ConversationServer.lookup(conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    %{conversation: conversation, a: a, b: b}
  end
end
