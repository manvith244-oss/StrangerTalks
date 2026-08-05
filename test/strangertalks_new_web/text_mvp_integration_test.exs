defmodule StrangertalksNewWeb.TextMvpIntegrationTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{Conversation, Matching, Message, Relationship, Report, SafetyReview}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  alias StrangertalksNewWeb.{
    ConversationChannel,
    ParticipantChannel,
    ParticipantToken,
    UserSocket
  }

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "complete verified text MVP server path" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    participant_socket_a = joined_participant_socket(participant_a)
    participant_socket_b = joined_participant_socket(participant_b)

    for socket <- [participant_socket_a, participant_socket_b] do
      ref = push(socket, "queue:join", queue_payload())
      assert_reply ref, :ok, %{status: "queued"}
      assert_push "queue:status", %{status: "queued"}
    end

    assert_push "match_found", %{conversation_id: conversation_id, status: "matched"}
    assert_push "match_found", %{conversation_id: ^conversation_id, status: "matched"}
    assert Repo.aggregate(Matching, :count) == 1
    assert Repo.aggregate(Conversation, :count) == 1

    conversation_socket_a = joined_conversation_socket(participant_a, conversation_id)
    conversation_socket_b = joined_conversation_socket(participant_b, conversation_id)
    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE

    first_message_id = Ecto.UUID.generate()

    ref =
      push(conversation_socket_a, "message:send", %{
        "message_id" => first_message_id,
        "content" => "hello"
      })

    assert_reply ref, :ok, %{status: "sent_to_server"}
    assert_push "message:new", %{message_id: ^first_message_id, content: "hello"}
    ref = push(conversation_socket_b, "message:ack", %{"message_id" => first_message_id})
    assert_reply ref, :ok, %{status: "delivered"}
    assert_push "message:status", %{message_id: ^first_message_id, status: "delivered"}

    Process.flag(:trap_exit, true)
    monitor = Process.monitor(conversation_socket_b.channel_pid)
    ref = leave(conversation_socket_b)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _, _}

    buffered_message_id = Ecto.UUID.generate()

    ref =
      push(conversation_socket_a, "message:send", %{
        "message_id" => buffered_message_id,
        "content" => "replayed"
      })

    assert_reply ref, :ok, %{status: "sent_to_server", sequence: 2}

    reconnected_b = joined_conversation_socket(participant_b, conversation_id)

    assert_push "message:new", %{
      message_id: ^buffered_message_id,
      content: "replayed",
      sequence: 2
    }

    ref = push(reconnected_b, "message:ack", %{"message_id" => buffered_message_id})
    assert_reply ref, :ok, %{status: "delivered"}

    ref = push(conversation_socket_a, "conversation:end", %{})
    assert_reply ref, :ok, %{status: "ended"}
    assert Repo.get!(Conversation, conversation_id).conversation_completed == true

    ref =
      push(conversation_socket_a, "relationship:consent", %{
        "participant_id" => participant_b.participant_id
      })

    assert_reply ref, :ok, %{status: "waiting_for_mutual_consent"}
    assert Repo.aggregate(Relationship, :count) == 0

    ref =
      push(reconnected_b, "relationship:consent", %{
        "participant_id" => participant_a.participant_id
      })

    assert_reply ref, :ok, %{status: "created"}
    assert Repo.aggregate(Relationship, :count) == 1

    ref =
      push(conversation_socket_a, "conversation:report", %{
        "category" => "HARASSMENT",
        "evidence" => "selected evidence"
      })

    assert_reply ref, :ok, %{status: "submitted"}
    assert Repo.aggregate(Report, :count) == 1
    assert Repo.one!(SafetyReview).status == :PENDING

    ref = push(conversation_socket_a, "conversation:block", %{})
    assert_reply ref, :ok, %{status: "blocked"}
    {:ok, _} = MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 0, 0.0)
    {:ok, _} = MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 0, 0.0)
    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert Repo.aggregate(Matching, :count) == 1
    assert Repo.aggregate(Message, :count) == 0
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    token = ParticipantToken.sign(participant.participant_id)
    assert {:ok, _socket} = connect(UserSocket, %{"token" => token})
    participant
  end

  defp joined_participant_socket(participant) do
    {:ok, socket} =
      connect(UserSocket, %{"token" => ParticipantToken.sign(participant.participant_id)})

    {:ok, _, socket} =
      subscribe_and_join(socket, ParticipantChannel, "participant:#{participant.participant_id}")

    socket
  end

  defp joined_conversation_socket(participant, conversation_id) do
    {:ok, socket} =
      connect(UserSocket, %{"token" => ParticipantToken.sign(participant.participant_id)})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation_id}")

    socket
  end

  defp queue_payload, do: %{"door_type" => "EXPLORE"}
end
