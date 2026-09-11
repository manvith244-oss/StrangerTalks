defmodule StrangertalksNewWeb.HearthChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias StrangertalksNew.Experiments.Hearth.Authority

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

      {:error, :expired} ->
        emit(:bridge_expired, %{variant: :treatment})
        {:reply, {:error, %{reason: "bridge_expired"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "no_offer"}}, socket}
    end
  end

  def handle_in("bridge:pass", %{"bridge_id" => bridge_id} = params, socket)
      when map_size(params) == 1 and is_binary(bridge_id) do
    :ok = Authority.pass(Authority, socket.assigns.participant_id, bridge_id)
    emit(:bridge_passed, %{variant: :treatment})
    {:reply, {:ok, %{status: "hearth_viewed"}}, socket}
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info({:bridge_offered, payload}, socket) do
    push(socket, "bridge:offered", payload)
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

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if participant_id = socket.assigns[:participant_id] do
      _ = safe_disconnect(participant_id)
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

  defp safe_disconnect(participant_id) do
    if Process.whereis(Authority), do: Authority.disconnect(Authority, participant_id), else: :ok
  catch
    :exit, _ -> :ok
  end

  defp emit(event, metadata) do
    :telemetry.execute(
      [:strangertalks_new, :experiment, :hearth, event],
      %{count: 1, monotonic_time: System.monotonic_time()},
      metadata
    )
  end
end
