defmodule StrangertalksNew.TerminalPairingReservationTransitionTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.Transitions
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  setup do
    StrangertalksNew.PairingTestIsolation.install!()
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "direct terminal transition atomically releases active pairing reservations" do
    %{conversation: conversation, match_id: match_id} = pairing_fixture()

    assert conversation.conversation_status == :PENDING
    assert active_reservations(match_id) == 2

    assert {:ok, terminal} = Transitions.transition(conversation, :recovery_timeout)
    assert terminal.conversation_status == :ABANDONED
    assert active_reservations(match_id) == 0
  end

  test "failed reservation release rolls back the terminal status transition" do
    %{conversation: conversation, match_id: match_id} = pairing_fixture()

    future_acquired_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_naive()

    Repo.query!(
      "UPDATE participant_pairing_reservations SET acquired_at = $2 WHERE match_id = $1 AND released_at IS NULL",
      [Ecto.UUID.dump!(match_id), future_acquired_at]
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Transitions.transition(conversation, :recovery_timeout)

    persisted = Repo.get!(Conversation, conversation.conversation_id)
    assert persisted.conversation_status == :PENDING
    assert persisted.ended_at == nil
    assert active_reservations(match_id) == 2
  end

  defp pairing_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    %{conversation: Repo.get_by!(Conversation, match_id: match_id), match_id: match_id}
  end

  defp active_reservations(match_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM participant_pairing_reservations WHERE match_id = $1 AND released_at IS NULL",
        [Ecto.UUID.dump!(match_id)]
      )

    count
  end
end
