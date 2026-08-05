defmodule StrangertalksNewWeb.ParticipantChannel do
  use Phoenix.Channel

  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  @matchmaking_topic "strangertalks:matchmaking"
  @doors %{
    "JUST_TALK" => :JUST_TALK,
    "KEEP_IT_LIGHT" => :KEEP_IT_LIGHT,
    "EXPLORE" => :EXPLORE,
    "SOMETHING_REAL" => :SOMETHING_REAL
  }

  @impl true
  def join("participant:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @matchmaking_topic)
      {:ok, socket}
    else
      {:error, %{reason: "participant_mismatch"}}
    end
  end

  @impl true
  def handle_in(
        "join_queue",
        %{
          "door_type" => door_type,
          "language" => language,
          "media_capability" => media_capability,
          "typing_cadence" => typing_cadence
        },
        socket
      )
      when is_binary(door_type) and is_binary(language) and is_integer(media_capability) and
             is_float(typing_cadence) do
    participant_id = socket.assigns.participant_id

    with {:ok, door} <- door_from_string(door_type),
         :not_queued <-
           queue_entry_status(participant_id, door, language, media_capability, typing_cadence),
         {:ok, _result} <-
           MatchmakingEngine.join_queue(
             participant_id,
             door,
             language,
             media_capability,
             typing_cadence
           ) do
      send(self(), :evaluate_pending_matches)
      {:reply, {:ok, %{status: "queued"}}, socket}
    else
      :same_entry ->
        {:reply, {:ok, %{status: "queued"}}, socket}

      :different_entry ->
        {:reply, {:error, %{reason: "already_queued_different_door"}}, socket}

      {:error, :invalid_door_type} ->
        {:reply, {:error, %{reason: "invalid_door_type"}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "queue_join_failed"}}, socket}
    end
  end

  def handle_in("join_queue", _params, socket) do
    {:reply, {:error, %{reason: "invalid_queue_parameters"}}, socket}
  end

  def handle_in("create", _params, socket) do
    {:reply, {:error, %{reason: "unsupported_event"}}, socket}
  end

  @impl true
  def handle_info(:evaluate_pending_matches, socket) do
    MatchmakingEngine.evaluate_pending_matches()
    {:noreply, socket}
  end

  def handle_info(
        {:match_event, :match_created, _match_id, conversation_id, participant_a_id,
         participant_b_id, _score},
        socket
      ) do
    if socket.assigns.participant_id in [participant_a_id, participant_b_id] do
      push(socket, "match_found", %{conversation_id: conversation_id, status: "matched"})
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Best-effort V1 cleanup only; reconnection and grace-period semantics are out of scope.
    MatchmakingEngine.leave_queue(socket.assigns.participant_id)
    :ok
  end

  defp door_from_string(door_type) do
    case Map.fetch(@doors, door_type) do
      {:ok, door} -> {:ok, door}
      :error -> {:error, :invalid_door_type}
    end
  end

  defp queue_entry_status(participant_id, door, language, media_capability, typing_cadence) do
    Agent.get(QueueState, fn state ->
      case Map.get(state, participant_id) do
        nil ->
          :not_queued

        %{
          door_selection: ^door,
          language_tag: ^language,
          media_bitmask: ^media_capability,
          keystroke_cadence: ^typing_cadence
        } ->
          :same_entry

        _entry ->
          :different_entry
      end
    end)
  end
end
