defmodule StrangertalksNewWeb.ParticipantChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Message
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

  test "conversation channel authorizes members, rejects non-members and unknown conversations" do
    {conversation, participant_a, _participant_b} = matched_conversation_fixture()

    assert {:ok, %{status: "joined", conversation_id: conversation_id}, _socket} =
             participant_a
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ConversationChannel,
               "conversation:#{conversation.conversation_id}"
             )

    assert conversation_id == conversation.conversation_id

    outsider = participant_fixture()

    assert {:error, %{reason: "not_conversation_member"}} =
             outsider
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ConversationChannel,
               "conversation:#{conversation.conversation_id}"
             )

    assert {:error, %{reason: "conversation_not_found"}} =
             participant_a
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ConversationChannel,
               "conversation:#{Ecto.UUID.generate()}"
             )
  end

  test "conversation joins reuse one server, track tabs, and activate when both participants join" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    socket_a_1 = joined_conversation_socket(participant_a, conversation)
    socket_a_2 = joined_conversation_socket(participant_a, conversation)
    _socket_b = joined_conversation_socket(participant_b, conversation)

    assert {:ok, pid} = ConversationServer.lookup(conversation.conversation_id)
    assert {:ok, ^pid} = ConversationServer.ensure_started(conversation.conversation_id)
    assert {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)
    assert MapSet.size(state.participant_channels[participant_a.participant_id]) == 2
    assert Repo.get!(Conversation, conversation.conversation_id).conversation_status == :ACTIVE

    Process.flag(:trap_exit, true)
    monitor = Process.monitor(socket_a_1.channel_pid)
    ref = leave(socket_a_1)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    _ = :sys.get_state(pid)
    assert {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)
    assert MapSet.size(state.participant_channels[participant_a.participant_id]) == 1
    refute Map.has_key?(state.recovery_timers, participant_a.participant_id)
    assert socket_a_2.channel_pid != socket_a_1.channel_pid
  end

  test "authorized channel message delivery and acknowledgement use safe payloads and no database row" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    sender_socket = joined_conversation_socket(participant_a, conversation)
    recipient_socket = joined_conversation_socket(participant_b, conversation)
    message_id = Ecto.UUID.generate()

    ref =
      push(sender_socket, "message:send", %{
        "message_id" => message_id,
        "content" => "hello",
        "sender_id" => participant_b.participant_id,
        "recipient_id" => participant_a.participant_id
      })

    assert_reply ref, :ok, %{message_id: ^message_id, sequence: 1, status: "sent_to_server"}
    assert_push "message:status", %{message_id: ^message_id, status: "sent_to_server"}

    assert_push "message:new", payload
    assert payload.message_id == message_id
    assert payload.sequence == 1
    assert payload.content == "hello"
    assert Map.keys(payload) |> Enum.sort() == [:content, :message_id, :sent_at, :sequence]
    refute participant_a.participant_id in Map.values(payload)
    refute participant_b.participant_id in Map.values(payload)

    sender_ack_ref = push(sender_socket, "message:ack", %{"message_id" => message_id})
    assert_reply sender_ack_ref, :error, %{reason: "sender_cannot_acknowledge"}

    ack_ref = push(recipient_socket, "message:ack", %{"message_id" => message_id})
    assert_reply ack_ref, :ok, %{message_id: ^message_id, status: "delivered"}
    assert_push "message:status", %{message_id: ^message_id, status: "delivered"}

    duplicate_ack_ref = push(recipient_socket, "message:ack", %{"message_id" => message_id})
    assert_reply duplicate_ack_ref, :ok, %{message_id: ^message_id, status: "delivered"}
    assert Repo.aggregate(Message, :count, :message_id) == 0

    assert {:ok, server_state} = ConversationServer.inspect_state(conversation.conversation_id)
    assert server_state.pending == %{}
    assert server_state.pending_count == 0
    assert server_state.pending_bytes == 0
    assert Map.has_key?(server_state.completed, message_id)
    refute Map.has_key?(server_state.completed[message_id], :content)
  end

  test "conversation channel rejects missing and malformed client message IDs" do
    {conversation, participant_a, _participant_b} = matched_conversation_fixture()
    socket = joined_conversation_socket(participant_a, conversation)

    ref = push(socket, "message:send", %{"content" => "missing"})
    assert_reply ref, :error, %{reason: "invalid_message_payload"}

    ref = push(socket, "message:send", %{"message_id" => "bad", "content" => "malformed"})
    assert_reply ref, :error, %{reason: "invalid_message_id"}
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

  defp joined_conversation_socket(participant, conversation) do
    {:ok, _, socket} =
      participant
      |> connected_socket()
      |> subscribe_and_join(
        StrangertalksNewWeb.ConversationChannel,
        "conversation:#{conversation.conversation_id}"
      )

    socket
  end

  defp matched_conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, _result} =
      MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, _result} =
      MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.one!(Conversation)
    {conversation, participant_a, participant_b}
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
