defmodule StrangertalksNewWeb.ParticipantMatchTransitionAuthorityTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Conversation
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

  test "stale anonymous match event cannot override a fresh queue attempt" do
    {old_match_id, old_conversation_id, participant, peer} = ended_match_fixture()

    assert {:ok, %{queue_attempt_id: fresh_attempt_id}} =
             MatchmakingEngine.join_queue(
               participant.participant_id,
               :EXPLORE,
               "en",
               nil,
               nil
             )

    socket = joined_socket(participant)

    send(
      socket.channel_pid,
      {:match_event, :match_created, old_match_id, old_conversation_id,
       participant.participant_id, peer.participant_id, 100}
    )

    _ = :sys.get_state(socket.channel_pid)
    refute_push "match_found", %{}, 100
    refute_push "queue:status", %{status: "matched"}, 100

    assert Agent.get(QueueState, fn state ->
             state
             |> Map.fetch!(participant.participant_id)
             |> Map.fetch!(:queue_attempt_id)
           end) == fresh_attempt_id
  end

  test "stale Bond reconnect event cannot override a fresh queue attempt" do
    {_old_match_id, old_conversation_id, participant, peer} = ended_match_fixture()

    assert {:ok, %{queue_attempt_id: fresh_attempt_id}} =
             MatchmakingEngine.join_queue(
               participant.participant_id,
               :EXPLORE,
               "en",
               nil,
               nil
             )

    socket = joined_socket(participant)

    send(
      socket.channel_pid,
      {:bond_reconnect_matched, old_conversation_id, participant.participant_id,
       peer.participant_id}
    )

    _ = :sys.get_state(socket.channel_pid)
    refute_push "match_found", %{}, 100

    assert Agent.get(QueueState, fn state ->
             state
             |> Map.fetch!(participant.participant_id)
             |> Map.fetch!(:queue_attempt_id)
           end) == fresh_attempt_id
  end

  defp ended_match_fixture do
    participant = participant_fixture()
    peer = participant_fixture()

    assert {:ok, _} =
             MatchmakingEngine.join_queue(
               participant.participant_id,
               :EXPLORE,
               "en",
               nil,
               nil
             )

    assert {:ok, _} =
             MatchmakingEngine.join_queue(
               peer.participant_id,
               :EXPLORE,
               "en",
               nil,
               nil
             )

    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.get_by!(Conversation, match_id: match_id)

    conversation
    |> Conversation.changeset(%{
      conversation_status: :ENDED,
      conversation_completed: true,
      ending_type: :NATURAL_END,
      ended_at: DateTime.utc_now()
    })
    |> Repo.update!()

    {match_id, conversation.conversation_id, participant, peer}
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp joined_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)

    {:ok, socket} =
      connect(UserSocket, %{}, connect_info: %{auth_token: token})

    {:ok, _reply, socket} =
      subscribe_and_join(
        socket,
        StrangertalksNewWeb.ParticipantChannel,
        "participant:#{participant.participant_id}"
      )

    socket
  end
end
