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
       bridges: %{},
       participant_bridge: %{},
       rooms: %{},
       participant_room: %{},
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

    with true <- valid_participant?(participant_id),
         {:ok, contribution} <- normalize_contribution(contribution),
         false <- active_participant?(state, participant_id),
         true <- active_participant_count(state) < state.max_active_participants do
      now = now_ms()

      state = %{
        state
        | recent:
            Enum.take(
              [
                %{text: contribution, expires_at: now + state.submission_ttl_ms}
                | state.recent
              ],
              @max_recent
            )
      }

      case next_waiting(state) do
        nil ->
          token = make_ref()
          Process.send_after(self(), {:expire_waiting, participant_id, token}, state.submission_ttl_ms)

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
      {:error, :invalid_contribution} -> {:reply, {:error, :invalid_contribution}, state}
      false -> {:reply, {:error, :capacity}, state}
      true -> {:reply, {:error, :already_active}, state}
      _ -> {:reply, {:error, :invalid_contribution}, state}
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
        partner_id = partner_id(bridge.participants, participant_id)

        {:reply,
         {:ok,
          %{
            bridge_id: bridge.id,
            own_anchor: bridge.contributions[participant_id],
            partner_anchor: bridge.contributions[partner_id],
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
      %{participants: participants} when is_list(participants) ->
        if participant_id in participants do
          partner = partner_id(participants, participant_id)

          {:reply,
           {:ok,
            %{status: :bridge_dissolved, bridge_id: bridge_id, partner_id: partner}},
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

        {:reply,
         {:ok,
          %{status: :bridge_dissolved, bridge_id: bridge_id, partner_id: partner}},
         dissolve_bridge(state, bridge_id)}

      Map.has_key?(state.waiting, participant_id) ->
        {:reply, {:ok, %{status: :waiting_removed}}, remove_waiting_only(state, participant_id)}

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

          {:reply, {:ok, %{partner_id: partner, turn_number: turn_number}}, state}
        else
          {:reply, {:error, :no_room}, state}
        end

      _ ->
        {:reply, {:error, :no_room}, state}
    end
  end

  def handle_call({:leave_room, participant_id, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      %{participants: participants} when is_list(participants) ->
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
      bridge_count: map_size(state.bridges),
      room_count: map_size(state.rooms),
      recent_count: length(state.recent),
      active_participant_count: active_participant_count(state),
      turn_count: Enum.reduce(state.rooms, 0, fn {_id, room}, acc -> acc + room.turn_count end)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:expire_waiting, participant_id, token}, state) do
    case Map.get(state.waiting, participant_id) do
      %{token: ^token} ->
        notify(state.notifier, {:hearth_waiting_expired, participant_id})
        {:noreply, remove_waiting_only(state, participant_id)}

      _ ->
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

  defp normalize_contribution(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @max_contribution,
      do: {:ok, trimmed},
      else: {:error, :invalid_contribution}
  end

  defp normalize_contribution(_), do: {:error, :invalid_contribution}
  defp valid_participant?(value), do: is_binary(value) and value != ""

  defp next_waiting(state) do
    Enum.find(state.order, &Map.has_key?(state.waiting, &1))
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
      Map.has_key?(state.participant_bridge, participant_id) or
      Map.has_key?(state.participant_room, participant_id)
  end

  defp active_participant_count(state) do
    map_size(state.waiting) + map_size(state.participant_bridge) + map_size(state.participant_room)
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

    expired_waiting =
      state.waiting
      |> Enum.filter(fn {_id, %{at: at}} -> at + state.submission_ttl_ms <= now end)
      |> Enum.map(&elem(&1, 0))

    state =
      Enum.reduce(expired_waiting, state, fn participant_id, acc ->
        notify(acc.notifier, {:hearth_waiting_expired, participant_id})
        remove_waiting_only(acc, participant_id)
      end)

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

  defp remove_waiting_only(state, participant_id) do
    %{
      state
      | waiting: Map.delete(state.waiting, participant_id),
        order: Enum.reject(state.order, &(&1 == participant_id))
    }
  end

  defp notify(nil, _event), do: :ok
  defp notify(pid, event) when is_pid(pid), do: send(pid, event)

  defp notify(module, event) when is_atom(module) do
    if function_exported?(module, :notify, 1), do: module.notify(event), else: :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
