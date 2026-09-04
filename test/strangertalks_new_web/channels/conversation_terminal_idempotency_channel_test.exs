defmodule StrangertalksNewWeb.ConversationTerminalIdempotencyChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{Conversation, MatchingRules, Participants, Repo}
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.MatchingRules.BoundaryBlock
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  setup do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
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

  test "Block after durable normal End preserves canonical terminal truth and does not leak a contradictory peer event",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)

    end_ref = push(socket_a, "conversation:end", %{})
    assert_reply end_ref, :ok, %{status: "ended"}

    for _ <- 1..2 do
      assert_push "conversation:ended", %{status: "ended", reason: "participant_completed"}
    end

    assert_eventually(fn ->
      ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}
    end)

    before_block = Repo.get!(Conversation, context.conversation.conversation_id)
    assert before_block.conversation_status == :ENDED
    assert before_block.ending_type == :NATURAL_END
    assert before_block.ending_initiator == context.participant_a.participant_id
    assert before_block.safety_flagged == false

    stale_block = push(socket_b, "conversation:block", %{})
    assert_reply stale_block, :ok, %{status: "blocked"}

    # The post-End safety action may create a future matching veto for the blocker,
    # but it must only reassert the already-durable terminal result to stale clients.
    assert_push "conversation:ended", %{
      status: "ended",
      reason: "participant_completed"
    }

    after_block = Repo.get!(Conversation, context.conversation.conversation_id)
    assert after_block.conversation_status == :ENDED
    assert after_block.ending_type == :NATURAL_END
    assert after_block.ending_initiator == context.participant_a.participant_id
    assert after_block.safety_flagged == false
    assert after_block.conversation_completed == true

    assert MatchingRules.check_safety_veto?(
             context.participant_a.participant_id,
             context.participant_b.participant_id
           )

    assert Repo.aggregate(BoundaryBlock, :count, :blocker_user_id) == 1

    repeated_stale_block = push(socket_b, "conversation:block", %{})
    assert_reply repeated_stale_block, :ok, %{status: "blocked"}

    assert_push "conversation:ended", %{
      status: "ended",
      reason: "participant_completed"
    }

    after_repeated_block = Repo.get!(Conversation, context.conversation.conversation_id)

    assert after_repeated_block.conversation_status == after_block.conversation_status
    assert after_repeated_block.ending_type == after_block.ending_type
    assert after_repeated_block.ending_initiator == after_block.ending_initiator
    assert after_repeated_block.safety_flagged == after_block.safety_flagged
    assert after_repeated_block.conversation_completed == after_block.conversation_completed
    assert Repo.aggregate(BoundaryBlock, :count, :blocker_user_id) == 1

    assert {:error, :terminal_conversation} =
             ConversationServer.ensure_started(context.conversation.conversation_id)
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp connect_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp connect_and_join(participant, conversation) do
    socket = connect_socket(participant)

    {:ok, _reply, socket} =
      subscribe_and_join(
        socket,
        ConversationChannel,
        "conversation:#{conversation.conversation_id}",
        %{}
      )

    socket
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
