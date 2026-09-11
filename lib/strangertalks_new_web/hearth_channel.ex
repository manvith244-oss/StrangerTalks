defmodule StrangertalksNewWeb.HearthChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Experiments.Hearth.Authority
  alias StrangertalksNew.RateLimiter

  @pubsub StrangertalksNew.PubSub

  @impl true
  def join("hearth:" <> participant_id, params, socket) when params == %{} do
    cond do
      not enabled?() ->
        {:error, %{reason: "experiment_disabled"}}

      participant_id != socket.assigns.participant_id ->
        {:error, %{reason: "participant_mismatch"}}

      true ->
        :ok = Phoenix.PubSub.subscribe(@pubsub, topic(participant_id))
        emit(:hearth_viewed, %{variant: :treatment})
        {:ok, %{status: "hearth_viewed"}, assign(socket, :hearth_participant_id, participant_id)}
    end
  end

  def join("hearth:" <> _participant_id, _params, _socket),
    do: {:error, %{reason: "invalid_request"}}

  @impl true
  def handle_in("hearth:submit", %{"contribution" => contribution} = params, socket)
      when map_size(params) == 1 do
    with :ok <- require_enabled(),
         {:ok, result} <- Authority.submit(Authority, socket.assigns.participant_id, contribution) do
      emit(:hearth_submitted, %{variant: :treatment})

      case result do
        %{status: :waiting} ->
          {:reply, {:ok, %{status: "waiting"}}, socket}

        %{status: :bridge_offered, bridge_id: bridge_id, partner_id: partner_id} ->
          emit(:bridge_offered, %{variant: :treatment})
          notify_offer(socket.assigns.participant_id)
          notify_offer(partner_id)

          {:reply, {:ok, %{status: "bridge_offered", bridge_id: bridge_id}}, socket}
      end
    else
      {:error, :experiment_disabled} ->
        {:reply, {:error, %{reason: "experiment_disabled"}}, socket}

      {:error, :invalid_contribution} ->
        {:reply, {:error, %{reason: "invalid_contribution"}}, socket}

      {:error, :capacity} ->
        {:reply, {:error, %{reason: "capacity"}}, socket}

      {:error, :already_active} ->
        {:reply, {:error, %{reason: "already_active"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  def handle_in("bridge:step_in", %{"bridge_id" => bridge_id} = params, socket)
      when map_size(params) == 1 and is_binary(bridge_id) do
    with :ok <- require_enabled(),
         {:ok, result} <- Authority.step_in(Authority, socket.assigns.participant_id, bridge_id) do
      emit(:bridge_step_in, %{variant: :treatment})

      case result do
        %{status: :waiting_for_partner} ->
          {:reply, {:ok, %{status: "waiting_for_partner"}}, socket}

        %{status: :room_ready, room_id: room_id, participant_ids: participant_ids} ->
          Enum.each(participant_ids, fn participant_id ->
            Phoenix.PubSub.broadcast(@pubsub, topic(participant_id), {:room_ready, room_id})
          end)

          emit(:experiment_room_started, %{variant: :treatment})
          {:reply, {:ok, %{status: "room_ready", room_id: room_id}}, socket}
      end
    else
      {:error, :experiment_disabled} ->
        {:reply, {:error, %{reason: "experiment_disabled"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "no_offer"}}, socket}
    end
  end

  def handle_in("bridge:pass", %{"bridge_id" => bridge_id} = params, socket)
      when map_size(params) == 1 and is_binary(bridge_id) do
    case Authority.pass(Authority, socket.assigns.participant_id, bridge_id) do
      {:ok, %{status: :bridge_dissolved, partner_id: partner_id}} ->
        notify_bridge_dissolved(partner_id, bridge_id)
        emit(:bridge_passed, %{variant: :treatment})
        {:reply, {:ok, %{status: "hearth_viewed"}}, socket}

      _ ->
        {:reply, {:ok, %{status: "hearth_viewed"}}, socket}
    end
  end

  def handle_in(
        "room:message",
        %{"room_id" => room_id, "content" => content} = params,
        socket
      )
      when map_size(params) == 2 and is_binary(room_id) do
    with :ok <- require_enabled(),
         :ok <- validate_message_content(content),
         :ok <- rate_limit(socket, :message_send, 20, 10_000),
         {:ok, %{partner_id: partner_id, turn_number: turn_number}} <-
           Authority.route_message(Authority, socket.assigns.participant_id, room_id) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(partner_id),
        {:room_message, %{room_id: room_id, content: content, turn_number: turn_number}}
      )

      emit(:experiment_turn, %{variant: :treatment, turn_number: turn_number})
      {:reply, {:ok, %{status: "delivered", turn_number: turn_number}}, socket}
    else
      {:error, :experiment_disabled} ->
        {:reply, {:error, %{reason: "experiment_disabled"}}, socket}

      {:error, :message_too_large} ->
        {:reply, {:error, %{reason: "message_too_large"}}, socket}

      {:error, :invalid_payload} ->
        {:reply, {:error, %{reason: "invalid_payload"}}, socket}

      {:error, {:rate_limited, retry_after_ms}} ->
        {:reply, {:error, %{reason: "rate_limited", retry_after_ms: retry_after_ms}}, socket}

      {:error, :no_room} ->
        {:reply, {:error, %{reason: "no_room"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  def handle_in("room:leave", %{"room_id" => room_id} = params, socket)
      when map_size(params) == 1 and is_binary(room_id) do
    case Authority.leave_room(Authority, socket.assigns.participant_id, room_id) do
      {:ok, effect} ->
        notify_room_ended(effect.partner_id, effect.room_id)
        emit_room_ended(effect, :explicit_leave)
        {:reply, {:ok, %{status: "ended"}}, socket}

      {:error, :no_room} ->
        {:reply, {:error, %{reason: "no_room"}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info({:bridge_offered, payload}, socket) do
    push(socket, "bridge:offered", payload)
    {:noreply, socket}
  end

  def handle_info({:hearth_bridge_expired, bridge_id}, socket) do
    emit(:bridge_expired, %{variant: :treatment})
    push(socket, "bridge:dissolved", %{bridge_id: bridge_id, status: "hearth_viewed"})
    {:noreply, socket}
  end

  def handle_info(:hearth_waiting_expired, socket) do
    push(socket, "hearth:reset", %{status: "hearth_viewed"})
    {:noreply, socket}
  end

  def handle_info({:bridge_dissolved, bridge_id}, socket) do
    push(socket, "bridge:dissolved", %{bridge_id: bridge_id, status: "hearth_viewed"})
    {:noreply, socket}
  end

  def handle_info({:room_ready, room_id}, socket) do
    case Authority.room(Authority, socket.assigns.participant_id) do
      {:ok, room} ->
        push(socket, "room:ready", %{
          room_id: room_id,
          own_anchor: room.own_anchor,
          partner_anchor: room.partner_anchor
        })

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_info({:room_message, payload}, socket) do
    push(socket, "room:message", payload)
    {:noreply, socket}
  end

  def handle_info({:room_partner_disconnected, room_id}, socket) do
    push(socket, "room:partner_disconnected", %{room_id: room_id})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if participant_id = socket.assigns[:participant_id] do
      participant_id
      |> safe_disconnect()
      |> notify_disconnect_effect()
    end

    :ok
  end

  def topic(participant_id) when is_binary(participant_id), do: "hearth:#{participant_id}"

  def enabled? do
    Application.get_env(:strangertalks_new, :experiment_hearth_enabled, false) == true or
      System.get_env("EXPERIMENT_HEARTH_ENABLED", "false") in ["true", "1"]
  end

  defp require_enabled do
    if enabled?(), do: :ok, else: {:error, :experiment_disabled}
  end

  defp notify_offer(participant_id) do
    case Authority.offer(Authority, participant_id) do
      {:ok, offer} ->
        payload = %{
          bridge_id: offer.bridge_id,
          own_anchor: offer.own_anchor,
          partner_anchor: offer.partner_anchor,
          expires_at: offer.expires_at
        }

        Phoenix.PubSub.broadcast(@pubsub, topic(participant_id), {:bridge_offered, payload})

      _ ->
        :ok
    end
  end

  defp notify_bridge_dissolved(participant_id, bridge_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(participant_id), {:bridge_dissolved, bridge_id})
  end

  defp notify_room_ended(participant_id, room_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(participant_id), {:room_partner_disconnected, room_id})
  end

  defp safe_disconnect(participant_id) do
    if Process.whereis(Authority), do: Authority.disconnect(Authority, participant_id), else: {:ok, %{status: :none}}
  catch
    :exit, _ -> {:ok, %{status: :none}}
  end

  defp notify_disconnect_effect({:ok, %{status: :bridge_dissolved} = effect}) do
    notify_bridge_dissolved(effect.partner_id, Map.get(effect, :bridge_id))
  end

  defp notify_disconnect_effect({:ok, %{status: :room_dissolved} = effect}) do
    notify_room_ended(effect.partner_id, effect.room_id)
    emit_room_ended(effect, :disconnect)
  end

  defp notify_disconnect_effect(_effect), do: :ok

  defp validate_message_content(content) when is_binary(content) do
    cond do
      not String.valid?(content) -> {:error, :invalid_payload}
      String.trim(content) == "" -> {:error, :invalid_payload}
      byte_size(content) > ConversationServer.max_message_bytes() -> {:error, :message_too_large}
      true -> :ok
    end
  end

  defp validate_message_content(_content), do: {:error, :invalid_payload}

  defp rate_limit(socket, bucket, limit, window_ms) do
    case RateLimiter.allow(bucket, socket.assigns.participant_id, limit, window_ms) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp emit_room_ended(effect, reason) do
    :telemetry.execute(
      [:strangertalks_new, :experiment, :hearth, :experiment_room_ended],
      %{
        count: 1,
        duration_ms: effect.duration_ms,
        turn_count: effect.turn_count,
        monotonic_time: System.monotonic_time()
      },
      %{variant: :treatment, reason: reason}
    )
  end

  defp emit(event, metadata) do
    :telemetry.execute(
      [:strangertalks_new, :experiment, :hearth, event],
      %{count: 1, monotonic_time: System.monotonic_time()},
      metadata
    )
  end
end
