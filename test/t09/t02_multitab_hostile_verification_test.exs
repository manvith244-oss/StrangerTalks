defmodule StrangertalksNew.T09T02MultitabHostileVerificationTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNewWeb.{ParticipantToken, UserSocket}

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "V4 conflicting sibling parameters cannot fork or rewrite current queue authority" do
    participant = participant_fixture()
    socket_a1 = joined_socket(participant)
    socket_a2 = joined_socket(participant)

    ref = push(socket_a1, "queue:join", queue_params("EXPLORE", "en"))
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: attempt_id}
    first_entry = queue_entry(participant.participant_id)

    ref = push(socket_a2, "queue:join", queue_params("JUST_TALK", "en"))
    assert_reply ref, :error, %{reason: "already_queued_different_door"}
    assert queue_entry(participant.participant_id) == first_entry

    ref = push(socket_a2, "queue:join", queue_params("EXPLORE", "hi"))
    assert_reply ref, :error, %{reason: "already_queued_different_door"}
    assert queue_entry(participant.participant_id) == first_entry
    assert first_entry.queue_attempt_id == attempt_id
    assert map_size(queue_state()) == 1
  end

  test "V5 stale sibling Attempt-1 identity cannot remove newer Attempt-2" do
    participant = participant_fixture()
    old_socket = joined_socket(participant)
    current_socket = joined_socket(participant)

    ref = push(old_socket, "queue:join", queue_params("EXPLORE", "en"))
    assert_reply ref, :ok, %{queue_attempt_id: attempt_1}

    ref = push(current_socket, "queue:leave", %{"queue_attempt_id" => attempt_1})
    assert_reply ref, :ok, %{status: "left"}

    ref = push(current_socket, "queue:join", queue_params("EXPLORE", "en"))
    assert_reply ref, :ok, %{queue_attempt_id: attempt_2}
    refute attempt_1 == attempt_2

    ref = push(old_socket, "queue:leave", %{"queue_attempt_id" => attempt_1})
    assert_reply ref, :error, %{reason: "stale_attempt"}

    assert queue_entry(participant.participant_id).queue_attempt_id == attempt_2
    assert map_size(queue_state()) == 1
  end

  test "V6 closing one sibling ParticipantChannel preserves queue authority until final sibling closes" do
    participant = participant_fixture()
    socket_a1 = joined_socket(participant)
    socket_a2 = joined_socket(participant)

    ref = push(socket_a1, "queue:join", queue_params("KEEP_IT_LIGHT", "en"))
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: attempt_id}
    assert queue_entry(participant.participant_id).queue_attempt_id == attempt_id

    leave_ref = leave(socket_a1)
    assert_reply leave_ref, :ok
    eventually(fn -> refute Process.alive?(socket_a1.channel_pid) end)

    assert queue_entry(participant.participant_id).queue_attempt_id == attempt_id
    assert map_size(queue_state()) == 1

    ref = push(socket_a2, "queue:join", queue_params("KEEP_IT_LIGHT", "en"))
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: ^attempt_id}
    assert queue_entry(participant.participant_id).queue_attempt_id == attempt_id

    leave_ref = leave(socket_a2)
    assert_reply leave_ref, :ok
    eventually(fn -> refute queue_entry(participant.participant_id) end)
  end

  defp participant_fixture do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{created_at: DateTime.utc_now()})

    participant
  end

  defp joined_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    assert {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    assert {:ok, _payload, socket} =
             subscribe_and_join(
               socket,
               StrangertalksNewWeb.ParticipantChannel,
               "participant:#{participant.participant_id}"
             )

    socket
  end

  defp queue_params(door, language) do
    %{"door_type" => door, "conversation_language" => language}
  end

  defp queue_state, do: Agent.get(QueueState, & &1)
  defp queue_entry(participant_id), do: Map.get(queue_state(), participant_id)

  defp eventually(assertion, attempts \\ 40)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end
end
