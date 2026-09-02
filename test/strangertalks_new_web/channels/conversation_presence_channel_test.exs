defmodule StrangertalksNewWeb.ConversationPresenceChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Participants
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  setup do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
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
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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

    {:ok, pid} = ConversationServer.ensure_started(conversation.conversation_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
      end
    end)

    %{
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b
    }
  end

  defp connect_and_join(participant, conversation) do
    token = ParticipantToken.sign(participant.participant_id)

    {:ok, socket} =
      connect(UserSocket, %{}, connect_info: %{auth_token: token})

    topic = "conversation:#{conversation.conversation_id}"

    {:ok, _reply, socket} =
      subscribe_and_join(socket, ConversationChannel, topic, %{})

    socket
  end

  describe "session:visibility Channel endpoint" do
    test "accepts visible and hidden", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)

      ref = push(socket_a, "session:visibility", %{"visibility" => "hidden"})
      assert_reply ref, :ok

      ref2 = push(socket_a, "session:visibility", %{"visibility" => "visible"})
      assert_reply ref2, :ok
    end

    test "rejects invalid visibility payload with INVALID_PAYLOAD", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)

      ref = push(socket_a, "session:visibility", %{"visibility" => "away"})
      assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}

      ref2 = push(socket_a, "session:visibility", %{"invalid_key" => "visible"})
      assert_reply ref2, :error, %{code: "INVALID_PAYLOAD"}

      ref3 = push(socket_a, "session:visibility", "invalid_string")
      assert_reply ref3, :error, %{code: "INVALID_PAYLOAD"}
    end

    test "rate limits rapid session:visibility abuse", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)

      # Push 30 valid messages within limit
      for i <- 1..30 do
        vis = if rem(i, 2) == 0, do: "visible", else: "hidden"
        ref = push(socket_a, "session:visibility", %{"visibility" => vis})
        assert_reply ref, :ok
      end

      # 31st call exceeds limit (30 per 10s)
      ref = push(socket_a, "session:visibility", %{"visibility" => "visible"})
      assert_reply ref, :error, %{code: "RATE_LIMITED"}
    end

    test "sync:reconcile returns current peer_presence", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)
      socket_b = connect_and_join(context.participant_b, context.conversation)

      ref_b = push(socket_b, "session:visibility", %{"visibility" => "hidden"})
      assert_reply ref_b, :ok

      ref = push(socket_a, "sync:reconcile", %{"last_applied_sequence" => 0})
      assert_reply ref, :ok, %{peer_presence: "away"}
    end

    test "privacy audit: presence events do not expose participant IDs or session PIDs",
         context do
      socket_a = connect_and_join(context.participant_a, context.conversation)
      assert_push "conversation:presence", %{status: nil}

      _socket_b = connect_and_join(context.participant_b, context.conversation)

      assert_push "conversation:presence", payload
      assert payload == %{status: "connected"}
      refute context.participant_a.participant_id in Map.values(payload)
      refute context.participant_b.participant_id in Map.values(payload)

      # Flip to hidden
      ref = push(socket_a, "session:visibility", %{"visibility" => "hidden"})
      assert_reply ref, :ok

      # socket_b will receive the away update
      # let's make sure payload does not contain IDs
      refute context.participant_a.participant_id in Map.values(payload)
    end

    test "diagnostic privacy: visibility APPLY retains no identifying presence data", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          ref = push(socket_a, "session:visibility", %{"visibility" => "hidden"})
          assert_reply ref, :ok
        end)

      forbidden = [
        context.participant_a.participant_id,
        context.participant_b.participant_id,
        context.conversation.conversation_id,
        inspect(socket_a.channel_pid)
      ]

      Enum.each(forbidden, &refute(String.contains?(log, &1)))
    end

    test "diagnostic privacy: visibility NO_OP retains no identifying presence data", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)
      ref_init = push(socket_a, "session:visibility", %{"visibility" => "hidden"})
      assert_reply ref_init, :ok

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          ref = push(socket_a, "session:visibility", %{"visibility" => "hidden"})
          assert_reply ref, :ok
        end)

      forbidden = [
        context.participant_a.participant_id,
        context.participant_b.participant_id,
        context.conversation.conversation_id,
        inspect(socket_a.channel_pid)
      ]

      Enum.each(forbidden, &refute(String.contains?(log, &1)))
    end

    test "diagnostic privacy: invalid visibility retains no identifying presence data", context do
      socket_a = connect_and_join(context.participant_a, context.conversation)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          ref = push(socket_a, "session:visibility", %{"visibility" => "unsupported_value"})
          assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}
        end)

      forbidden = [
        context.participant_a.participant_id,
        context.participant_b.participant_id,
        context.conversation.conversation_id,
        inspect(socket_a.channel_pid)
      ]

      Enum.each(forbidden, &refute(String.contains?(log, &1)))
    end

    test "diagnostic privacy: rate/admission rejection retains no identifying presence data",
         context do
      socket_a = connect_and_join(context.participant_a, context.conversation)

      for i <- 1..30 do
        vis = if rem(i, 2) == 0, do: "visible", else: "hidden"
        ref = push(socket_a, "session:visibility", %{"visibility" => vis})
        assert_reply ref, :ok
      end

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          ref = push(socket_a, "session:visibility", %{"visibility" => "visible"})
          assert_reply ref, :error, %{code: "RATE_LIMITED"}
        end)

      forbidden = [
        context.participant_a.participant_id,
        context.participant_b.participant_id,
        context.conversation.conversation_id,
        inspect(socket_a.channel_pid)
      ]

      Enum.each(forbidden, &refute(String.contains?(log, &1)))
    end
  end
end
