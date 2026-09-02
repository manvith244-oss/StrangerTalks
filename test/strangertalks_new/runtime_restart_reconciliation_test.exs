defmodule StrangertalksNew.RuntimeRestartReconciliationTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.{ParticipantConnectionTracker, QueueState}
  alias StrangertalksNew.SessionReconciliation
  alias StrangertalksNewWeb.ParticipantToken
  alias StrangertalksNewWeb.UserSocket

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "QueueState restart intentionally loses queue authority and reconciliation reports AVAILABLE" do
    participant = participant_fixture()

    assert {:ok, %{queue_attempt_id: attempt_id}} =
             MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)

    assert {:ok, %{canonical_state: :QUEUED, queue: %{queue_attempt_id: ^attempt_id}}} =
             SessionReconciliation.reconcile(participant.participant_id)

    replacement = restart_named_child(QueueState)
    assert Process.whereis(QueueState) == replacement
    assert queue_state() == %{}

    assert {:ok, %{canonical_state: :AVAILABLE, queue: nil, conversation: nil}} =
             SessionReconciliation.reconcile(participant.participant_id)
  end

  test "stale pre-restart queue attempt cannot mutate a newly established attempt" do
    participant = participant_fixture()

    assert {:ok, %{queue_attempt_id: old_attempt}} =
             MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)

    restart_named_child(QueueState)

    assert {:ok, %{queue_attempt_id: new_attempt}} =
             MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)

    refute new_attempt == old_attempt
    assert {:error, :stale_attempt} =
             MatchmakingEngine.cancel_queue(participant.participant_id, old_attempt)

    assert %{queue_attempt_id: ^new_attempt} = queue_entry(participant.participant_id)
    assert :ok = MatchmakingEngine.cancel_queue(participant.participant_id, new_attempt)
    assert queue_entry(participant.participant_id) == nil
  end

  test "tracker restart invalidates old queue authority and sibling sockets rebuild one registration set through reconciliation" do
    participant = participant_fixture()
    socket_a1 = joined_socket(participant)
    socket_a2 = joined_socket(participant)
    params = queue_params("EXPLORE")

    ref = push(socket_a1, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: attempt_id}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^attempt_id}

    ref = push(socket_a2, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: ^attempt_id}
    assert map_size(queue_state()) == 1
    assert tracker_channel_count(participant.participant_id) == 2

    restart_named_child(ParticipantConnectionTracker)

    assert queue_state() == %{}
    assert tracker_channel_count(participant.participant_id) == 0

    for socket <- [socket_a1, socket_a2] do
      ref = push(socket, "session:reconcile", %{})

      assert_reply ref, :ok, %{
        snapshot: %{canonical_state: :AVAILABLE, queue: nil, conversation: nil}
      }
    end

    assert tracker_channel_count(participant.participant_id) == 2

    ref = push(socket_a1, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: new_attempt}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^new_attempt}
    refute new_attempt == attempt_id

    ref = push(socket_a2, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: ^new_attempt}
    assert map_size(queue_state()) == 1

    :ok = ParticipantConnectionTracker.unregister(participant.participant_id, socket_a1.channel_pid)
    assert %{queue_attempt_id: ^new_attempt} = queue_entry(participant.participant_id)

    :ok = ParticipantConnectionTracker.unregister(participant.participant_id, socket_a2.channel_pid)
    assert queue_entry(participant.participant_id) == nil
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
      participant
      |> connected_socket()
      |> subscribe_and_join(
        StrangertalksNewWeb.ParticipantChannel,
        "participant:#{participant.participant_id}"
      )

    socket
  end

  defp restart_named_child(name) do
    old_pid = Process.whereis(name)
    monitor = Process.monitor(old_pid)
    assert :ok = Supervisor.terminate_child(StrangertalksNew.Supervisor, name)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :shutdown}
    assert {:ok, replacement} = Supervisor.restart_child(StrangertalksNew.Supervisor, name)
    refute replacement == old_pid
    assert Process.whereis(name) == replacement
    replacement
  end

  defp tracker_channel_count(participant_id) do
    ParticipantConnectionTracker
    |> :sys.get_state()
    |> Map.fetch!(:participants)
    |> Map.get(participant_id, MapSet.new())
    |> MapSet.size()
  end

  defp queue_params(door_type),
    do: %{"door_type" => door_type, "conversation_language" => "en"}

  defp queue_entry(participant_id), do: Map.get(queue_state(), participant_id)
  defp queue_state, do: Agent.get(QueueState, & &1)
end
