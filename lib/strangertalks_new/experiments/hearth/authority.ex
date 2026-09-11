defmodule StrangertalksNew.Experiments.Hearth.Authority do
  use GenServer

  @default_bridge_ttl_ms 20_000
  @default_submission_ttl_ms 120_000
  @default_max_active_participants 2_000
  @max_recent 3
  @max_contribution 100

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def submit(server \\ __MODULE__, participant_id, contribution),
    do: GenServer.call(server, {:submit, participant_id, contribution})

  def connect_control(server \\ __MODULE__, participant_id),
    do: GenServer.call(server, {:connect_control, participant_id})

  def recent(server \\ __MODULE__, limit \\ @max_recent),
    do: GenServer.call(server, {:recent, limit})

  def offer(server \\ __MODULE__, participant_id),
    do: GenServer.call(server, {:offer, participant_id})

  def step_in(server \\ __MODULE__, participant_id, bridge_id),
    do: GenServer.call(server, {:step_in, participant_id, bridge_id})

  def pass(server \\ __MODULE__, participant_id, bridge_id),
    do: GenServer.call(server, {:pass, participant_id, bridge_id})

  def disconnect(server \\ __MODULE__, participant_id),
    do: GenServer.call(server, {:disconnect, participant_id})

  def room(server \\ __MODULE__, participant_id),
    do: GenServer.call(server, {:room, participant_id})

  def route_message(server \\ __MODULE__, participant_id, room_id),
    do: GenServer.call(server, {:route_message, participant_id, room_id})

  def leave_room(server \\ __MODULE__, participant_id, room_id),
    do: GenServer.call(server, {:leave_room, participant_id, room_id})

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    {:ok,
     %{
       waiting: %{},
       order: [],
       control_waiting: %{},
       control_order: [],
       bridges: %{},
       participant_bridge: %{},
       rooms: %{},
       participant_room: %{},
       consumed_participants: MapSet.new(),
       recent: [],
       bridge_ttl_ms: Keyword.get(opts, :bridge_ttl_ms, @default_bridge_ttl_ms),
       submission_ttl_ms: Keyword.get(opts, :submission_ttl_ms, @default_submission_ttl_ms),
       max_active_participants:
         Keyword.get(opts, :max_active_participants, @default_max_active_participants),
       notifier: Keyword.get(opts, :notifier)
     }}
  end

  @impl true
  def handle_call({:submit, participant_id, contribution}, _from, state) do
    state = prune(state)

    with {:ok, contribution} <- normalize_contribution(contribution),
         :ok <- validate_entry(state, participant_id) do
      now = now_ms()
      state = mark_consumed(state, participant_id)

      state = %{
        state
        | recent:
            Enum.take(
              [%{text: contribution, expires_at: now + state.submission_ttl_ms} | state.recent],
              @max_recent
            )
      }

      case next_waiting(state.order, state.waiting) do
        nil ->
          token = make_ref()
          schedule_waiting_expiry(:treatment, participant_id, token, state.submission_ttl_ms)

          waiting =
            Map.put(state.waiting, participant_id, %{
              contribution: contribution,
              at: now,
              token: token
            })

          {:reply, {:ok, %{status: :waiting}},
           %{state | waiting: waiting, order: state.order ++ [participant_id]}}

        partner_id ->
          partner = Map.fetch!(state.waiting, partner_id)
          bridge_id = Ecto.UUID.generate()
          expires_at = now + state.bridge_ttl_ms
          Process.send_after(self(), {:expire_bridge, bridge_id}, state.bridge_ttl_ms)

          bridge = %{
            id: bridge_id,
            participants: [partner_id, participant_id],
            contributions: %{partner_id => partner.contribution, participant_id => contribution},
            stepped_in: MapSet.new(),
            expires_at: expires_at
          }

          state =
            state
            |> remove_waiting_only(partner_id)
            |> put_in([:bridges, bridge_id], bridge)
            |> put_in([:participant_bridge, partner_id], bridge_id)
            |> put_in([:participant_bridge, participant_id], bridge_id)

          {:reply,
           {:ok,
            %{
              status: :bridge_offered,
              bridge_id: bridge_id,
              partner_id: partner_id,
              expires_at: expires_at
            }}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:connect_control, participant_id}, _from, state) do
    state = prune(state)

    case validate_entry(state, participant_id) do
      :ok ->
        now = now_ms()
        state = mark_consumed(state, participant_id)

        case next_waiting(state.control_order, state.control_waiting) do
          nil ->
            token = make_ref()
            schedule_waiting_expiry(:control, participant_id, token, state.submission_ttl_ms)

            control_waiting =
              Map.put(state.control_waiting, participant_id, %{at: now, token: token})

            {:reply, {:ok, %{status: :waiting}},
             %{
               state
               | control_waiting: control_waiting,
                 control_order: state.control_order ++ [participant_id]
             }}

          partner_id ->
            room_id = Ecto.UUID.generate()
            participants = [partner_id, participant_id]

            room = %{
              id: room_id,
              variant: :control,
              participants: participants,
              contributions: %{partner_id => nil, participant_id => nil},
              started_at: now,
              turn_count: 0
            }

            state =
              state
              |> remove_control_waiting_only(partner_id)
              |> put_in([:rooms, room_id], room)
              |> put_in([:participant_room, partner_id], room_id)
              |> put_in([:participant_room, participant_id], room_id)

            {:reply,
             {:ok, %{status: :room_ready, room_id: room_id, participant_ids: participants}},
             state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recent, limit}, _from, state) do
    state = prune(state)
    safe_limit = if is_integer(limit), do: min(max(limit, 0), @max_recent), else: @max_recent
    recent = state.recent |> Enum.take(safe_limit) |> Enum.map(& &1.text)
    {:reply, recent, state}
  end

  def handle_call({:offer, participant_id}, _from, state) do
    state = prune(state)

    case bridge_for(state, participant_id) do
      nil ->
        {:reply, {:error, :no_offer}, state}

      bridge ->
        partner = partner_id(bridge.participants, participant_id)

        {:reply,
         {:ok,
          %{
            bridge_id: bridge.id,
            own_anchor: bridge.contributions[participant_id],
            partner_anchor: bridge.contributions[partner],
            expires_at: bridge.expires_at
          }}, state}
    end
  end

  def handle_call({:step_in, participant_id, bridge_id}, _from, state) do
    state = prune(state)

    case Map.get(state.bridges, bridge_id) do
      %{participants: participants} = bridge ->
        if participant_id in participants do
          stepped_in = MapSet.put(bridge.stepped_in, participant_id)
          bridge = %{bridge | stepped_in: stepped_in}

          if MapSet.size(stepped_in) == 2 do
            room_id = Ecto.UUID.generate()
            [a, b] = bridge.participants

            room = %{
              id: room_id,
              variant: :treatment,
              participants: bridge.participants,
              contributions: bridge.contributions,
              started_at: now_ms(),
              turn_count: 0
            }

            state =
              state
              |> dissolve_bridge(bridge_id)
              |> put_in([:rooms, room_id], room)
              |> put_in([:participant_room, a], room_id)
              |> put_in([:participant_room, b], room_id)

            {:reply,
             {:ok,
              %{
                status: :room_ready,
                room_id: room_id,
                participant_ids: bridge.participants
              }}, state}
          else
            {:reply, {:ok, %{status: :waiting_for_partner}},
             put_in(state, [:bridges, bridge_id], bridge)}
          end
        else
          {:reply, {:error, :no_offer}, state}
        end

      _ ->
        {:reply, {:error, :no_offer}, state}
    end
  end

  def handle_call({:pass, participant_id, bridge_id}, _from, state) do
    case Map.get(state.bridges, bridge_id) do
      %{participants: participants} ->
        if participant_id in participants do
          partner = partner_id(participants, participant_id)

          {:reply, {:ok, %{status: :bridge_dissolved, bridge_id: bridge_id, partner_id: partner}},
           dissolve_bridge(state, bridge_id)}
        else
          {:reply, {:ok, %{status: :none}}, state}
        end

      _ ->
        {:reply, {:ok, %{status: :none}}, state}
    end
  end

  def handle_call({:disconnect, participant_id}, _from, state) do
    cond do
      room_id = Map.get(state.participant_room, participant_id) ->
        {effect, state} = dissolve_room_with_effect(state, room_id, participant_id)
        {:reply, {:ok, effect}, state}

      bridge_id = Map.get(state.participant_bridge, participant_id) ->
        bridge = Map.fetch!(state.bridges, bridge_id)
        partner = partner_id(bridge.participants, participant_id)

        {:reply, {:ok, %{status: :bridge_dissolved, bridge_id: bridge_id, partner_id: partner}},
         dissolve_bridge(state, bridge_id)}

      Map.has_key?(state.waiting, participant_id) ->
        {:reply, {:ok, %{status: :waiting_removed}}, remove_waiting_only(state, participant_id)}

      Map.has_key?(state.control_waiting, participant_id) ->
        {:reply, {:ok, %{status: :waiting_removed}},
         remove_control_waiting_only(state, participant_id)}

      true ->
        {:reply, {:ok, %{status: :none}}, state}
    end
  end

  def handle_call({:room, participant_id}, _from, state) do
    case Map.get(state.participant_room, participant_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_id ->
        room = Map.fetch!(state.rooms, room_id)
        partner = partner_id(room.participants, participant_id)

        {:reply,
         {:ok,
          %{
            room_id: room_id,
            variant: room.variant,
            own_anchor: room.contributions[participant_id],
            partner_anchor: room.contributions[partner],
            turn_count: room.turn_count
          }}, state}
    end
  end

  def handle_call({:route_message, participant_id, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      %{participants: participants} = room ->
        if participant_id in participants and
             Map.get(state.participant_room, participant_id) == room_id do
          partner = partner_id(participants, participant_id)
          turn_number = room.turn_count + 1
          state = put_in(state, [:rooms, room_id, :turn_count], turn_number)

          {:reply, {:ok, %{partner_id: partner, turn_number: turn_number, variant: room.variant}},
           state}
        else
          {:reply, {:error, :no_room}, state}
        end

      _ ->
        {:reply, {:error, :no_room}, state}
    end
  end

  def handle_call({:leave_room, participant_id, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      %{participants: participants} ->
        if participant_id in participants and
             Map.get(state.participant_room, participant_id) == room_id do
          {effect, state} = dissolve_room_with_effect(state, room_id, participant_id)
          {:reply, {:ok, effect}, state}
        else
          {:reply, {:error, :no_room}, state}
        end

      _ ->
        {:reply, {:error, :no_room}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = prune(state)

    snapshot = %{
      waiting_count: map_size(state.waiting),
      control_waiting_count: map_size(state.control_waiting),
      bridge_count: map_size(state.bridges),
      room_count: map_size(state.rooms),
      recent_count: length(state.recent),
      consumed_participant_count: MapSet.size(state.consumed_participants),
      active_participant_count: active_participant_count(state),
      turn_count: Enum.reduce(state.rooms, 0, fn {_id, room}, acc -> acc + room.turn_count end)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:expire_waiting, variant, participant_id, token}, state) do
    {entry, state} =
      case variant do
        :treatment -> {Map.get(state.waiting, participant_id), state}
        :control -> {Map.get(state.control_waiting, participant_id), state}
      end

    if entry && entry.token == token do
      notify(state.notifier, {:hearth_waiting_expired, participant_id})

      state =
        case variant do
          :treatment -> remove_waiting_only(state, participant_id)
          :control -> remove_control_waiting_only(state, participant_id)
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:expire_bridge, bridge_id}, state) do
    case Map.get(state.bridges, bridge_id) do
      %{participants: participants} ->
        notify(state.notifier, {:hearth_bridge_expired, bridge_id, participants})
        {:noreply, dissolve_bridge(state, bridge_id)}

      _ ->
        {:noreply, state}
    end
  end

  defp validate_entry(state, participant_id) do
    cond do
      not valid_participant?(participant_id) -> {:error, :invalid_participant}
      active_participant?(state, participant_id) -> {:error, :already_active}
      MapSet.member?(state.consumed_participants, participant_id) -> {:error, :already_participated}
      active_participant_count(state) >= state.max_active_participants -> {:error, :capacity}
      true -> :ok
    end
  end

  defp mark_consumed(state, participant_id) do
    %{state | consumed_participants: MapSet.put(state.consumed_participants, participant_id)}
  end

  defp normalize_contribution(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @max_contribution,
      do: {:ok, trimmed},
      else: {:error, :invalid_contribution}
  end

  defp normalize_contribution(_), do: {:error, :invalid_contribution}
  defp valid_participant?(value), do: is_binary(value) and value != ""

  defp schedule_waiting_expiry(variant, participant_id, token, ttl_ms) do
    Process.send_after(self(), {:expire_waiting, variant, participant_id, token}, ttl_ms)
  end

  defp next_waiting(order, waiting) do
    Enum.find(order, &Map.has_key?(waiting, &1))
  end

  defp bridge_for(state, participant_id) do
    with bridge_id when is_binary(bridge_id) <- Map.get(state.participant_bridge, participant_id),
         bridge when is_map(bridge) <- Map.get(state.bridges, bridge_id) do
      bridge
    else
      _ -> nil
    end
  end

  defp active_participant?(state, participant_id) do
    Map.has_key?(state.waiting, participant_id) or
      Map.has_key?(state.control_waiting, participant_id) or
      Map.has_key?(state.participant_bridge, participant_id) or
      Map.has_key?(state.participant_room, participant_id)
  end

  defp active_participant_count(state) do
    map_size(state.waiting) + map_size(state.control_waiting) + map_size(state.participant_bridge) +
      map_size(state.participant_room)
  end

  defp partner_id([a, b], participant_id) when participant_id == a, do: b
  defp partner_id([a, b], participant_id) when participant_id == b, do: a

  defp dissolve_bridge(state, bridge_id) do
    case Map.pop(state.bridges, bridge_id) do
      {nil, bridges} ->
        %{state | bridges: bridges}

      {%{participants: participants}, bridges} ->
        participant_bridge =
          Enum.reduce(participants, state.participant_bridge, &Map.delete(&2, &1))

        %{state | bridges: bridges, participant_bridge: participant_bridge}
    end
  end

  defp dissolve_room_with_effect(state, room_id, participant_id) do
    room = Map.fetch!(state.rooms, room_id)
    partner = partner_id(room.participants, participant_id)
    duration_ms = max(now_ms() - room.started_at, 0)

    effect = %{
      status: :room_dissolved,
      room_id: room_id,
      partner_id: partner,
      variant: room.variant,
      turn_count: room.turn_count,
      duration_ms: duration_ms
    }

    {effect, dissolve_room(state, room_id)}
  end

  defp dissolve_room(state, room_id) do
    case Map.pop(state.rooms, room_id) do
      {nil, rooms} ->
        %{state | rooms: rooms}

      {%{participants: participants}, rooms} ->
        participant_room =
          Enum.reduce(participants, state.participant_room, &Map.delete(&2, &1))

        %{state | rooms: rooms, participant_room: participant_room}
    end
  end

  defp prune(state) do
    now = now_ms()
    state = prune_waiting(state, :treatment, now)
    state = prune_waiting(state, :control, now)

    expired_bridges =
      state.bridges
      |> Enum.filter(fn {_id, bridge} -> bridge.expires_at <= now end)
      |> Enum.map(&elem(&1, 0))

    state =
      Enum.reduce(expired_bridges, state, fn bridge_id, acc ->
        bridge = Map.fetch!(acc.bridges, bridge_id)
        notify(acc.notifier, {:hearth_bridge_expired, bridge_id, bridge.participants})
        dissolve_bridge(acc, bridge_id)
      end)

    %{state | recent: Enum.filter(state.recent, &(&1.expires_at > now))}
  end

  defp prune_waiting(state, :treatment, now) do
    expired = expired_waiting_ids(state.waiting, state.submission_ttl_ms, now)

    Enum.reduce(expired, state, fn participant_id, acc ->
      notify(acc.notifier, {:hearth_waiting_expired, participant_id})
      remove_waiting_only(acc, participant_id)
    end)
  end

  defp prune_waiting(state, :control, now) do
    expired = expired_waiting_ids(state.control_waiting, state.submission_ttl_ms, now)

    Enum.reduce(expired, state, fn participant_id, acc ->
      notify(acc.notifier, {:hearth_waiting_expired, participant_id})
      remove_control_waiting_only(acc, participant_id)
    end)
  end

  defp expired_waiting_ids(waiting, ttl_ms, now) do
    waiting
    |> Enum.filter(fn {_id, %{at: at}} -> at + ttl_ms <= now end)
    |> Enum.map(&elem(&1, 0))
  end

  defp remove_waiting_only(state, participant_id) do
    %{
      state
      | waiting: Map.delete(state.waiting, participant_id),
        order: Enum.reject(state.order, &(&1 == participant_id))
    }
  end

  defp remove_control_waiting_only(state, participant_id) do
    %{
      state
      | control_waiting: Map.delete(state.control_waiting, participant_id),
        control_order: Enum.reject(state.control_order, &(&1 == participant_id))
    }
  end

  defp notify(nil, _event), do: :ok
  defp notify(pid, event) when is_pid(pid), do: send(pid, event)

  defp notify(module, event) when is_atom(module) do
    if function_exported?(module, :notify, 1), do: module.notify(event), else: :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
