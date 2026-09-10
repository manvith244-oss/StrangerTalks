defmodule StrangertalksNewWeb.HangoutLobbyChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias StrangertalksNew.Hangouts.Matcher

  @pubsub StrangertalksNew.PubSub

  @impl true
  def join("hangout_lobby:" <> participant_id, params, socket) when params == %{} do
    if participant_id == socket.assigns.participant_id do
      :ok = Phoenix.PubSub.subscribe(@pubsub, topic(participant_id))

      {:ok, %{status: "connected"},
       socket
       |> assign(:lobby_participant_id, participant_id)}
    else
      {:error, %{reason: "participant_mismatch"}}
    end
  end

  def join("hangout_lobby:" <> _participant_id, _params, _socket),
    do: {:error, %{reason: "invalid_request"}}

  @impl true
  def handle_in("queue:join", params, socket) when is_map(params) do
    with true <- allowed_keys?(params, ["language_tag"]),
         language_tag when is_binary(language_tag) and language_tag != "" <-
           Map.get(params, "language_tag"),
         participant_id <- socket.assigns.participant_id,
         {:ok, attempt} <- Matcher.enqueue(participant_id, language_tag) do
      payload = %{
        status: "queued",
        queue_attempt_id: attempt.queue_attempt_id
      }

      push(socket, "queue:status", payload)
      maybe_trigger_formation(language_tag)

      {:reply, {:ok, payload}, socket}
    else
      false ->
        {:reply, {:error, %{reason: "invalid_intent"}}, socket}

      nil ->
        {:reply, {:error, %{reason: "invalid_intent"}}, socket}

      "" ->
        {:reply, {:error, %{reason: "invalid_language_tag"}}, socket}

      {:error, :already_in_hangout} ->
        {:reply, {:error, %{reason: "already_in_hangout"}}, socket}

      {:error, :already_queued} ->
        {:reply, {:error, %{reason: "already_queued"}}, socket}

      {:error, :invalid_language_tag} ->
        {:reply, {:error, %{reason: "invalid_language_tag"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}

      _ ->
        {:reply, {:error, %{reason: "invalid_intent"}}, socket}
    end
  end

  def handle_in("queue:cancel", params, socket) when is_map(params) do
    if map_size(params) == 0 do
      :ok = Matcher.leave_queue(socket.assigns.participant_id)
      payload = %{status: "idle"}
      push(socket, "queue:status", payload)
      {:reply, {:ok, payload}, socket}
    else
      {:reply, {:error, %{reason: "invalid_intent"}}, socket}
    end
  end

  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "invalid_intent"}}, socket}
  end

  @impl true
  def handle_info({:hangout_formed, %{room_id: room_id}}, socket) do
    push(socket, "room:formed", %{room_id: room_id, status: "formed"})
    push(socket, "queue:status", %{status: "formed", room_id: room_id})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def topic(participant_id) when is_binary(participant_id),
    do: "hangout_lobby:#{participant_id}"

  defp allowed_keys?(params, expected_keys) do
    Map.keys(params) |> Enum.sort() == Enum.sort(expected_keys)
  end

  defp maybe_trigger_formation(language_tag) do
    case Matcher.try_form(language_tag) do
      {:ok, %{room_id: room_id, participant_ids: participant_ids}} ->
        Enum.each(participant_ids, fn pid ->
          Phoenix.PubSub.broadcast(@pubsub, topic(pid), {:hangout_formed, %{room_id: room_id}})
        end)

      _ ->
        :ok
    end
  end
end
