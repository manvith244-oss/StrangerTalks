defmodule StrangertalksNewWeb.ParticipantChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.ConversationLanguages
  alias StrangertalksNew.QueueEngine.ParticipantConnectionTracker
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.RelationshipReconnections
  alias StrangertalksNew.SessionReconciliation

  @matchmaking_topic "strangertalks:matchmaking"
  @doors %{
    "JUST_TALK" => :JUST_TALK,
    "KEEP_IT_LIGHT" => :KEEP_IT_LIGHT,
    "EXPLORE" => :EXPLORE,
    "SOMETHING_REAL" => :SOMETHING_REAL
  }

  @impl true
  def join("participant:" <> participant_id, params, socket) when params == %{} do
    if participant_id == socket.assigns.participant_id do
      :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @matchmaking_topic)
      :ok = ParticipantConnectionTracker.register(participant_id, self())

      case SessionReconciliation.reconcile(participant_id) do
        {:ok, snapshot} ->
          {:ok, %{status: "connected", snapshot: snapshot}, socket}

        {:error, reason} ->
          {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}
      end
    else
      {:error, StrangertalksNew.DomainError.to_channel_payload(:participant_mismatch)}
    end
  end

  def join("participant:" <> _participant_id, _params, _socket),
    do: {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)}

  @impl true
  def handle_in(
        event,
        %{"door_type" => door_type, "conversation_language" => conversation_language} = params,
        socket
      )
      when event in ["join_queue", "queue:join"] and is_binary(door_type) do
    participant_id = socket.assigns.participant_id

    with true <- map_size(params) == 2,
         {:ok, door} <- door_from_string(door_type),
         {:ok, language} <- ConversationLanguages.normalize(conversation_language),
         :not_queued <- queue_entry_status(participant_id, door, language),
         :ok <- rate_limit(socket, :queue_join, 10, 60_000),
         {:ok, result} <- MatchmakingEngine.join_queue(participant_id, door, language, nil, nil) do
      send(self(), :evaluate_pending_matches)
      payload = %{status: "queued", queue_attempt_id: result.queue_attempt_id}
      push(socket, "queue:status", payload)
      {:reply, {:ok, payload}, socket}
    else
      {:same_entry, queue_attempt_id} ->
        {:reply, {:ok, %{status: "queued", queue_attempt_id: queue_attempt_id}}, socket}

      :different_entry ->
        StrangertalksNew.Telemetry.failure(
          [:queue, :join, :failed],
          :already_queued_different_door
        )

        {:reply,
         {:error,
          StrangertalksNew.DomainError.to_channel_payload(:already_queued_different_door)},
         socket}

      result when result in [false, {:error, :invalid_door_type}] ->
        StrangertalksNew.Telemetry.failure([:queue, :join, :failed], :invalid_door_type)

        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_door_type)},
         socket}

      {:error, reason} when reason in [:language_required, :invalid_conversation_language] ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, :participant_busy} ->
        StrangertalksNew.Telemetry.failure(
          [:queue, :join, :failed],
          :participant_busy
        )

        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:participant_busy)},
         socket}

      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        StrangertalksNew.Telemetry.failure([:queue, :join, :failed], reason)
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} ->
        require Logger

        Logger.error("Queue join unexpected failure",
          operation: :queue_join,
          reason_code: StrangertalksNew.DomainError.from_error(reason).code
        )

        StrangertalksNew.Telemetry.failure([:queue, :join, :failed], :queue_join_failed)

        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:queue_join_failed)},
         socket}
    end
  end

  def handle_in(event, %{"door_type" => _door_type}, socket)
      when event in ["join_queue", "queue:join"] do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:language_required)},
     socket}
  end

  def handle_in("join_queue", _params, socket) do
    StrangertalksNew.Telemetry.failure([:queue, :join, :failed], :invalid_request)
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)}, socket}
  end

  def handle_in("queue:join", _params, socket) do
    StrangertalksNew.Telemetry.failure([:queue, :join, :failed], :invalid_request)
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)}, socket}
  end

  def handle_in(
        "queue:leave",
        %{"queue_attempt_id" => queue_attempt_id} = params,
        socket
      )
      when is_binary(queue_attempt_id) and map_size(params) == 1 do
    case MatchmakingEngine.cancel_queue(socket.assigns.participant_id, queue_attempt_id) do
      :ok ->
        {:reply, {:ok, %{status: "left"}}, socket}

      {:error, :participant_busy} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:participant_busy)},
         socket}

      {:error, :stale_attempt} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:stale_attempt)},
         socket}
    end
  end

  def handle_in("queue:leave", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)},
       socket}

  def handle_in(
        "bond:reconnect_start",
        %{"relationship_id" => relationship_id, "door_type" => door_type} = params,
        socket
      )
      when is_binary(relationship_id) and is_binary(door_type) do
    with true <- map_size(params) == 2,
         {:ok, _uuid} <- Ecto.UUID.cast(relationship_id),
         {:ok, door} <- door_from_string(door_type),
         :ok <- rate_limit(socket, :reconnect_mutation, 10, 60_000),
         {:ok, result} <-
           RelationshipReconnections.start_or_replace(
             relationship_id,
             socket.assigns.participant_id,
             door
           ) do
      {:reply, {:ok, result}, socket}
    else
      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        StrangertalksNew.Telemetry.failure(
          [:reconnection, :failed],
          reason,
          %{operation: :start}
        )

        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      _ ->
        {:reply,
         {:error, StrangertalksNew.DomainError.to_channel_payload(:reconnection_unavailable)},
         socket}
    end
  end

  def handle_in("bond:reconnect_start", _params, socket),
    do:
      {:reply,
       {:error, StrangertalksNew.DomainError.to_channel_payload(:reconnection_unavailable)},
       socket}

  def handle_in("bond:reconnect_cancel", %{"relationship_id" => relationship_id} = params, socket)
      when is_binary(relationship_id) do
    with true <- map_size(params) == 1,
         {:ok, _uuid} <- Ecto.UUID.cast(relationship_id),
         :ok <- rate_limit(socket, :reconnect_mutation, 10, 60_000),
         {:ok, result} <-
           RelationshipReconnections.cancel(relationship_id, socket.assigns.participant_id) do
      {:reply, {:ok, result}, socket}
    else
      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        StrangertalksNew.Telemetry.failure(
          [:reconnection, :failed],
          reason,
          %{operation: :cancel}
        )

        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      _ ->
        {:reply,
         {:error, StrangertalksNew.DomainError.to_channel_payload(:reconnection_unavailable)},
         socket}
    end
  end

  def handle_in("bond:reconnect_cancel", _params, socket),
    do:
      {:reply,
       {:error, StrangertalksNew.DomainError.to_channel_payload(:reconnection_unavailable)},
       socket}

  def handle_in("bond:reconnect_status", %{"relationship_id" => relationship_id} = params, socket)
      when is_binary(relationship_id) do
    with true <- map_size(params) == 1,
         {:ok, _uuid} <- Ecto.UUID.cast(relationship_id),
         :ok <- rate_limit(socket, :reconnect_status, 30, 60_000),
         {:ok, result} <-
           RelationshipReconnections.status(relationship_id, socket.assigns.participant_id) do
      {:reply, {:ok, result}, socket}
    else
      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        StrangertalksNew.Telemetry.failure(
          [:reconnection, :failed],
          reason,
          %{operation: :status}
        )

        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      _ ->
        {:reply,
         {:error, StrangertalksNew.DomainError.to_channel_payload(:reconnection_unavailable)},
         socket}
    end
  end

  def handle_in("bond:reconnect_status", _params, socket),
    do:
      {:reply,
       {:error, StrangertalksNew.DomainError.to_channel_payload(:reconnection_unavailable)},
       socket}

  def handle_in("session:reconcile", params, socket) when params == %{} do
    with :ok <- rate_limit(socket, :session_reconcile, 6, 30_000),
         {:ok, snapshot} <- SessionReconciliation.reconcile(socket.assigns.participant_id) do
      {:reply, {:ok, %{snapshot: snapshot}}, socket}
    else
      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("session:reconcile", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)},
       socket}

  def handle_in("create", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)}, socket}
  end

  def handle_in(_event, _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)},
       socket}

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
    participant_id = socket.assigns.participant_id

    if participant_id in [participant_a_id, participant_b_id] and
         canonical_conversation?(participant_id, conversation_id) do
      push(socket, "match_found", %{conversation_id: conversation_id, status: "matched"})
      push(socket, "queue:status", %{status: "matched"})
    end

    {:noreply, socket}
  end

  def handle_info({:queue_event, :queue_timeout, participant_id, queue_attempt_id}, socket) do
    if socket.assigns.participant_id == participant_id do
      push(socket, "queue:status", %{status: "timed_out", queue_attempt_id: queue_attempt_id})
    end

    {:noreply, socket}
  end

  def handle_info({:queue_event, :queue_left, participant_id, queue_attempt_id}, socket) do
    if socket.assigns.participant_id == participant_id do
      push(socket, "queue:status", %{status: "left", queue_attempt_id: queue_attempt_id})
    end

    {:noreply, socket}
  end

  def handle_info({:transition_recovery_failed, participant_id, conversation_id}, socket) do
    if socket.assigns.participant_id == participant_id do
      push(socket, "transition:recovery_failed", %{conversation_id: conversation_id})
    end

    {:noreply, socket}
  end

  def handle_info(
        {:transition_survivor_requeued, participant_id, conversation_id, queue_attempt_id},
        socket
      ) do
    if socket.assigns.participant_id == participant_id do
      push(socket, "queue:status", %{
        status: "queued",
        conversation_id: conversation_id,
        queue_attempt_id: queue_attempt_id
      })
    end

    {:noreply, socket}
  end

  def handle_info(
        {:relationship_created, relationship_id, participant_a_id, participant_b_id},
        socket
      ) do
    if socket.assigns.participant_id in [participant_a_id, participant_b_id] do
      push(socket, "relationship:created", %{status: "created", relationship_id: relationship_id})
    end

    {:noreply, socket}
  end

  def handle_info(
        {:bond_reconnect_matched, conversation_id, participant_a_id, participant_b_id},
        socket
      ) do
    participant_id = socket.assigns.participant_id

    if participant_id in [participant_a_id, participant_b_id] and
         canonical_conversation?(participant_id, conversation_id) do
      push(socket, "match_found", %{
        conversation_id: conversation_id,
        status: "matched",
        origin: "bond_reconnect"
      })
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    ParticipantConnectionTracker.unregister(socket.assigns.participant_id, self())
    :ok
  end

  defp canonical_conversation?(participant_id, conversation_id) do
    case SessionReconciliation.reconcile(participant_id) do
      {:ok,
       %{
         canonical_state: :CONVERSATION,
         conversation: %{conversation_id: ^conversation_id}
       }} ->
        true

      _ ->
        false
    end
  end

  defp door_from_string(door_type) do
    case Map.fetch(@doors, door_type) do
      {:ok, door} -> {:ok, door}
      :error -> {:error, :invalid_door_type}
    end
  end

  defp queue_entry_status(participant_id, door, language) do
    Agent.get(QueueState, fn state ->
      case Map.get(state, participant_id) do
        nil ->
          :not_queued

        %{
          door_selection: ^door,
          conversation_language: ^language,
          queue_attempt_id: queue_attempt_id
        } ->
          {:same_entry, queue_attempt_id}

        _entry ->
          :different_entry
      end
    end)
  end

  defp rate_limit(socket, bucket, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(
           bucket,
           socket.assigns.participant_id,
           limit,
           window_ms
         ) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end
end