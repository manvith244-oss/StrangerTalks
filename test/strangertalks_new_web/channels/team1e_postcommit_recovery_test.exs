defmodule StrangertalksNewWeb.Team1EPostcommitRecoveryTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint
  @topic "strangertalks:matchmaking"

  alias StrangertalksNew.{Conversation, Matching, Message, Participants, Repo}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNewWeb.{ParticipantChannel, ParticipantToken, UserSocket}

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "durable commit wins when one connected participant channel loses notification" do
    Process.flag(:trap_exit, true)
    a = participant_fixture()
    b = participant_fixture()
    channel_a = joined_socket(a)
    _channel_b = joined_socket(b)

    {:ok, %{queue_attempt_id: attempt_a}} =
      MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, nil, nil, nil)

    {:ok, _} =
      MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, nil, nil, nil)

    # Deterministic notification barrier: A's connected Channel cannot process PubSub.
    # B remains connected and receives the same committed match normally.
    assert :ok = :sys.suspend(channel_a.channel_pid)
    monitor_a = Process.monitor(channel_a.channel_pid)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert reservation_count() == 2
    conversation = Repo.one!(Conversation)
    assert conversation.match_id == match_id
    assert_push "match_found", %{conversation_id: conversation_id, status: "matched"}
    assert conversation_id == conversation.conversation_id

    # Kill the suspended Channel AFTER canonical commit but BEFORE queued PubSub delivery.
    Process.exit(channel_a.channel_pid, :kill)
    assert_receive {:DOWN, ^monitor_a, :process, _pid, :killed}

    assert {:ok, %{snapshot: recovered}, _new_channel_a} =
             subscribe_and_join(
               connected_socket(a),
               ParticipantChannel,
               "participant:#{a.participant_id}"
             )

    assert recovered.canonical_state == :CONVERSATION
    assert recovered.conversation.conversation_id == conversation_id
    assert {:error, :participant_busy} =
             MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, nil, nil, nil)

    assert {:error, :participant_busy} =
             MatchmakingEngine.cancel_queue(a.participant_id, attempt_a)

    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert reservation_count() == 2
    assert Repo.aggregate(Message, :count, :message_id) == 0
  end

  test "both missed notifications recover through Channel join; stale terminal signal is vetoed" do
    a = participant_fixture()
    b = participant_fixture()

    {:ok, _} =
      MatchmakingEngine.join_queue(a.participant_id, :JUST_TALK, nil, nil, nil)

    {:ok, _} =
      MatchmakingEngine.join_queue(b.participant_id, :JUST_TALK, nil, nil, nil)

    # No Channel is connected at commit: both initial match notifications are lost.
    assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.one!(Conversation)
    assert reservation_count() == 2

    for participant <- [a, b] do
      assert {:ok, %{snapshot: snapshot}, _channel} =
               subscribe_and_join(
                 connected_socket(participant),
                 ParticipantChannel,
                 "participant:#{participant.participant_id}"
               )

      assert snapshot.canonical_state == :CONVERSATION
      assert snapshot.conversation.conversation_id == conversation.conversation_id
    end

    # A delayed stale match signal must not reopen an already-terminal conversation.
    {:ok, terminal} =
      conversation
      |> Conversation.changeset(%{conversation_status: :ENDED})
      |> Repo.update()

    assert terminal.conversation_status == :ENDED

    Phoenix.PubSub.broadcast(
      StrangertalksNew.PubSub,
      @topic,
      {:match_event, :match_created, conversation.match_id, conversation.conversation_id,
       a.participant_id, b.participant_id, 100}
    )

    refute_push "match_found", _, 100
    assert Repo.get!(Conversation, conversation.conversation_id).conversation_status == :ENDED
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert Repo.aggregate(Message, :count, :message_id) == 0
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp joined_socket(participant) do
    {:ok, _, socket} =
      subscribe_and_join(
        connected_socket(participant),
        ParticipantChannel,
        "participant:#{participant.participant_id}"
      )

    socket
  end

  defp reservation_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*)::int FROM participant_pairing_reservations")

    count
  end
end
