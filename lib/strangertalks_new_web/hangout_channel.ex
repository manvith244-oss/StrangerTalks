defmodule StrangertalksNewWeb.HangoutChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.RoomServer

  @pubsub StrangertalksNew.PubSub

  @impl true
  def join("hangout:" <> room_id, params, socket) when params == %{} do
    participant_id = socket.assigns.participant_id

    with {:ok, _uuid} <- Ecto.UUID.cast(room_id),
         {:ok, snapshot} <- RoomServer.reconnect(room_id, participant_id),
         :ok <- Phoenix.PubSub.subscribe(@pubsub, topic(room_id)) do
      {:ok, snapshot,
       socket
       |> assign(:hangout_room_id, room_id)
       |> assign(:hangout_explicit_leave, false)}
    else
      :error ->
        join_error(:not_hangout_member)

      {:error, :terminal_room} ->
        join_error(:hangout_ended)

      {:error, reason}
      when reason in [
             :membership_not_found,
             :membership_not_active,
             :membership_removed,
             :membership_terminal
           ] ->
        join_error(:not_hangout_member)

      {:error, :room_not_found} ->
        join_error(:not_hangout_member)

      {:error, _reason} ->
        join_error(:not_hangout_member)
    end
  end

  def join("hangout:" <> _room_id, _params, _socket), do: join_error(:invalid_request)

  @impl true
  def handle_in("message:send", params, socket) when is_map(params) do
    with true <- allowed_keys?(params, ["client_message_id", "body"]),
         client_message_id when is_binary(client_message_id) and client_message_id != "" <-
           Map.get(params, "client_message_id"),
         body when is_binary(body) <- Map.get(params, "body"),
         {:ok, message} <-
           RoomServer.send_message(
             room_id(socket),
             socket.assigns.participant_id,
             %{client_message_id: client_message_id, body: body}
           ) do
      {:reply, {:ok, message}, socket}
    else
      false -> message_error(socket, :invalid_message_intent)
      nil -> message_error(socket, :invalid_message_intent)
      {:error, :idempotency_conflict} -> message_error(socket, :idempotency_conflict)
      {:error, :terminal_room} -> message_error(socket, :hangout_ended)
      {:error, :room_not_active} -> message_error(socket, :hangout_ended)
      {:error, :membership_not_found} -> message_error(socket, :not_hangout_member)
      {:error, :membership_not_active} -> message_error(socket, :not_hangout_member)
      {:error, :invalid_message, _changeset} -> message_error(socket, :invalid_message_intent)
      {:error, _reason} -> message_error(socket, :invalid_message_intent)
      _ -> message_error(socket, :invalid_message_intent)
    end
  end

  def handle_in("message:send", _params, socket),
    do: message_error(socket, :invalid_message_intent)

  def handle_in("reaction:add", params, socket) when is_map(params) do
    with true <- allowed_keys?(params, ["expected_content_sequence", "reaction"]),
         expected_content_sequence
         when is_integer(expected_content_sequence) and expected_content_sequence >= 0 <-
           Map.get(params, "expected_content_sequence"),
         reaction when is_binary(reaction) <- Map.get(params, "reaction"),
         {:ok, result} <-
           RoomServer.add_reaction(
             room_id(socket),
             socket.assigns.participant_id,
             expected_content_sequence,
             reaction
           ) do
      {:reply, {:ok, result}, socket}
    else
      false -> interaction_error(socket, :invalid_reaction_intent)
      nil -> interaction_error(socket, :invalid_reaction_intent)
      {:error, :invalid_reaction} -> interaction_error(socket, :invalid_reaction)
      {:error, :stale_content} -> interaction_error(socket, :stale_content)
      {:error, :content_disabled} -> interaction_error(socket, :content_disabled)
      {:error, :terminal_room} -> interaction_error(socket, :hangout_ended)
      {:error, :room_not_active} -> interaction_error(socket, :hangout_ended)
      {:error, :membership_not_found} -> interaction_error(socket, :not_hangout_member)
      {:error, :membership_not_active} -> interaction_error(socket, :not_hangout_member)
      {:error, _reason} -> interaction_error(socket, :invalid_reaction_intent)
      _ -> interaction_error(socket, :invalid_reaction_intent)
    end
  end

  def handle_in("reaction:add", _params, socket),
    do: interaction_error(socket, :invalid_reaction_intent)

  def handle_in("content:skip_vote", params, socket) when is_map(params) do
    with true <- allowed_keys?(params, ["expected_content_sequence"]),
         expected_content_sequence
         when is_integer(expected_content_sequence) and expected_content_sequence >= 0 <-
           Map.get(params, "expected_content_sequence"),
         {:ok, result} <-
           RoomServer.vote_skip(
             room_id(socket),
             socket.assigns.participant_id,
             expected_content_sequence
           ) do
      {:reply, {:ok, result}, socket}
    else
      false -> interaction_error(socket, :invalid_skip_intent)
      nil -> interaction_error(socket, :invalid_skip_intent)
      {:error, :stale_content} -> interaction_error(socket, :stale_content)
      {:error, :content_disabled} -> interaction_error(socket, :content_disabled)
      {:error, :terminal_room} -> interaction_error(socket, :hangout_ended)
      {:error, :room_not_active} -> interaction_error(socket, :hangout_ended)
      {:error, :membership_not_found} -> interaction_error(socket, :not_hangout_member)
      {:error, :membership_not_active} -> interaction_error(socket, :not_hangout_member)
      {:error, _reason} -> interaction_error(socket, :invalid_skip_intent)
      _ -> interaction_error(socket, :invalid_skip_intent)
    end
  end

  def handle_in("content:skip_vote", _params, socket),
    do: interaction_error(socket, :invalid_skip_intent)

  def handle_in("room:leave", params, socket) when params == %{} do
    case Hangouts.leave_room(room_id(socket), socket.assigns.participant_id) do
      {:ok, _membership} ->
        {:reply, {:ok, %{status: "left"}}, assign(socket, :hangout_explicit_leave, true)}

      {:error, :membership_not_found} ->
        {:reply, {:error, %{reason: "not_hangout_member"}}, socket}

      {:error, :membership_removed} ->
        {:reply, {:error, %{reason: "not_hangout_member"}}, socket}

      {:error, :terminal_room} ->
        {:reply, {:error, %{reason: "hangout_ended"}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "not_hangout_member"}}, socket}
    end
  end

  def handle_in("room:leave", _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info({:hangout_event, event, payload}, socket) when is_binary(event) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if Map.get(socket.assigns, :hangout_explicit_leave, false) do
      :ok
    else
      case Map.get(socket.assigns, :hangout_room_id) do
        room_id when is_binary(room_id) ->
          _ = RoomServer.disconnect(room_id, socket.assigns.participant_id)
          :ok

        _ ->
          :ok
      end
    end
  end

  defp allowed_keys?(params, allowed) do
    params
    |> Map.keys()
    |> Enum.all?(&(&1 in allowed)) and map_size(params) == length(allowed)
  end

  defp join_error(reason), do: {:error, %{reason: Atom.to_string(reason)}}

  defp message_error(socket, reason),
    do: {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}

  defp interaction_error(socket, reason),
    do: {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}

  defp room_id(socket), do: socket.assigns.hangout_room_id
  defp topic(room_id), do: "hangout:#{room_id}"
end
