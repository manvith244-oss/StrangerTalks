defmodule StrangertalksNewWeb.ParticipantMultiTabAuthorityTest do
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

  test "sibling participant channels open at match time converge on one canonical authority" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket_a1 = joined_socket(participant_a)
    socket_a2 = joined_socket(participant_a)
    socket_b = joined_socket(participant_b)
    params = queue_params("JUST_TALK")

    ref = push(socket_a1, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: attempt_a}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^attempt_a}

    ref = push(socket_a2, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: ^attempt_a}
    assert map_size(queue_state()) == 1

    ref = push(socket_b, "queue:join", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: attempt_b}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^attempt_b}

    assert_push "match_found", %{status: "matched", conversation_id: conversation_id}
    assert_push "match_found", %{status: "matched", conversation_id: ^conversation_id}
    assert_push "match_found", %{status: "matched", conversation_id: ^conversation_id}
    refute_push "match_found", _payload, 50

    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert Repo.get!(Conversation, conversation_id).conversation_status == :PENDING
    assert queue_state() == %{}

    for socket <- [socket_a1, socket_a2, socket_b] do
      ref = push(socket, "session:reconcile", %{})

      assert_reply ref, :ok, %{
        snapshot: %{
          canonical_state: :CONVERSATION,
          conversation: %{conversation_id: ^conversation_id}
        }
      }
    end
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

  defp queue_params(door_type) do
    %{"door_type" => door_type, "conversation_language" => "en"}
  end

  defp queue_state, do: Agent.get(QueueState, & &1)
end
