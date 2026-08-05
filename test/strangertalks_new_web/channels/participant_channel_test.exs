defmodule StrangertalksNewWeb.ParticipantChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken
  alias StrangertalksNewWeb.UserSocket

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "socket requires a current token for an existing participant" do
    participant = participant_fixture()
    token = ParticipantToken.sign(participant.participant_id)

    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.participant_id == participant.participant_id
    assert UserSocket.id(socket) == "participant_socket:#{participant.participant_id}"

    assert :error = connect(UserSocket, %{})
    assert :error = connect(UserSocket, %{"token" => "malformed"})

    expired_token =
      Phoenix.Token.sign(
        @endpoint,
        ParticipantToken.salt(),
        participant.participant_id,
        signed_at: System.system_time(:second) - ParticipantToken.max_age() - 1
      )

    assert :error = connect(UserSocket, %{"token" => expired_token})

    missing_id_token = ParticipantToken.sign(Ecto.UUID.generate())
    assert :error = connect(UserSocket, %{"token" => missing_id_token})
  end

  test "verified socket joins only its own participant topic" do
    participant = participant_fixture()
    socket = connected_socket(participant)

    assert {:ok, _, _socket} =
             subscribe_and_join(
               socket,
               StrangertalksNewWeb.ParticipantChannel,
               "participant:#{participant.participant_id}"
             )

    other_id = Ecto.UUID.generate()

    assert {:error, %{reason: "participant_mismatch"}} =
             subscribe_and_join(
               connected_socket(participant),
               StrangertalksNewWeb.ParticipantChannel,
               "participant:#{other_id}"
             )
  end

  test "old create channel event is not supported" do
    participant = participant_fixture()
    socket = joined_socket(participant)

    ref = push(socket, "create", %{})

    assert_reply ref, :error, %{reason: "unsupported_event"}
    assert Repo.aggregate(StrangertalksNew.Participant, :count, :participant_id) == 1
  end

  test "queue join is idempotent and conflicting parameters do not mutate the entry" do
    participant = participant_fixture()
    socket = joined_socket(participant)
    params = queue_params("EXPLORE")

    ref = push(socket, "join_queue", params)
    assert_reply ref, :ok, %{status: "queued"}
    first_entry = queue_entry(participant.participant_id)

    ref = push(socket, "join_queue", params)
    assert_reply ref, :ok, %{status: "queued"}
    assert queue_entry(participant.participant_id) == first_entry

    ref = push(socket, "join_queue", queue_params("JUST_TALK"))
    assert_reply ref, :error, %{reason: "already_queued_different_door"}
    assert queue_entry(participant.participant_id) == first_entry
    assert map_size(queue_state()) == 1
  end

  test "compatible participants persist one match and conversation and both receive safe notifications" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket_a = joined_socket(participant_a)
    socket_b = joined_socket(participant_b)

    ref = push(socket_a, "join_queue", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{status: "queued"}
    ref = push(socket_b, "join_queue", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{status: "queued"}

    assert_push "match_found", payload_a
    assert_push "match_found", payload_b
    assert payload_a == payload_b
    assert %{conversation_id: conversation_id, status: "matched"} = payload_a
    assert Map.keys(payload_a) |> Enum.sort() == [:conversation_id, :status]
    refute participant_a.participant_id in Map.values(payload_a)
    refute participant_b.participant_id in Map.values(payload_a)
    refute Map.has_key?(payload_a, :compatibility_score)

    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert Repo.get!(Conversation, conversation_id)
  end

  test "different doors remain queued and receive no match notification" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket_a = joined_socket(participant_a)
    socket_b = joined_socket(participant_b)

    ref = push(socket_a, "join_queue", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{status: "queued"}
    ref = push(socket_b, "join_queue", queue_params("JUST_TALK"))
    assert_reply ref, :ok, %{status: "queued"}

    _ = :sys.get_state(socket_a.channel_pid)
    _ = :sys.get_state(socket_b.channel_pid)
    refute_push "match_found", _payload, 100
    assert map_size(queue_state()) == 2
    assert Repo.aggregate(Matching, :count, :match_id) == 0
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 0
  end

  test "channel termination performs best-effort queue removal" do
    Process.flag(:trap_exit, true)
    participant = participant_fixture()
    socket = joined_socket(participant)

    assert {:ok, _} =
             MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", 7, 120.0)

    assert queue_entry(participant.participant_id)
    monitor = Process.monitor(socket.channel_pid)

    ref = leave(socket)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    refute queue_entry(participant.participant_id)
  end
  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
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
  defp queue_params(door_type) do
    %{
      "door_type" => door_type,
      "language" => "en",
      "media_capability" => 7,
      "typing_cadence" => 120.0
    }
  end

  defp queue_entry(participant_id), do: Map.get(queue_state(), participant_id)
  defp queue_state, do: Agent.get(QueueState, & &1)
end
