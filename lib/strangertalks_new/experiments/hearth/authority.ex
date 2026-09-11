defmodule StrangertalksNew.Experiments.Hearth.Authority do
  use GenServer

  @default_bridge_ttl_ms 20_000
  @default_submission_ttl_ms 120_000
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
       submission_ttl_ms: Keyword.get(opts, :submission_ttl_ms, @default_submission_ttl_ms)
     }}
  end

  @impl true
  def handle_call({:submit, participant_id, contribution}, _from, state) do
    state = prune(state)

    with true <- valid_participant?(participant_id),
         {:ok, contribution} <- normalize_contribution(contribution) do
      state = remove_participant(state, participant_id)
      now = now_ms()
      state = %{state | recent: Enum.take([contribution | state.recent], @max_recent)}

      case next_waiting(state, participant_id) do
        nil ->
          waiting = Map.put(state.waiting, participant_id, %{contribution: contribution, at: now})
          order = state.order |> Enum.reject(&(&1 == participant_id)) |> Kernel.++([participant_id])
          {:reply, {:ok, %{status: :waiting}}, %{state | waiting: waiting, order: order}}

        partner_id ->
          partner = Map.fetch!(state.waiting, partner_id)
          bridge_id = Ecto.UUID.generate()

          bridge = %{
            id: bridge_id,
            participants: [partner_id, participant_id],
            contributions: %{partner_id => partner.contribution, participant_id => contribution},
            stepped_in: MapSet.new(),
            expires_at: now + state.bridge_ttl_ms
          }

          state = %{
            state
            | waiting: Map.delete(state.waiting, partner_id),
              order: Enum.reject(state.order, &(&1 == partner_id)),
              bridges: Map.put(state.bridges, bridge_id, bridge),
              participant_bridge:
                state.participant_bridge
                |> Map.put(partner_id, bridge_id)
                |> Map.put(participant_id, bridge_id)
          }

          {:reply,
           {:ok,
            %{
              status: :bridge_offered,
              bridge_id: bridge_id,
              partner_id: partner_id
            }}, state}
      end
    else
      _ -> {:reply, {:error, :invalid_contribution}, state}
    end
  end

  def handle_call({:recent, limit}, _from, state) do
    state = prune(state)
    safe_limit = if is_integer(limit), do: min(max(limit, 0), @max_recent), else: @max_recent
    {:reply, Enum.take(state.recent, safe_limit), state}
  end

  def handle_call({:offer, participant_id}, _from, state) do
    state = prune(state)

    case bridge_for(state, participant_id) do
      nil ->
        {:reply, {:error, :no_offer}, state}

      bridge ->
        [a, b] = bridge.participants
        partner_id = if a == participant_id, do: b, else: a

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
    now = now_ms()

    case Map.get(state.bridges, bridge_id) do
      %{expires_at: expires_at} when expires_at <= now ->
        state = dissolve_bridge(state, bridge_id)
        {:reply, {:error, :expired}, state}

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
              started_at: now
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
          {:reply, {:error, :no_offer}, prune(state)}
        end

      _ ->
        {:reply, {:error, :no_offer}, prune(state)}
    end
  end

  def handle_call({:pass, participant_id, bridge_id}, _from, state) do
    case Map.get(state.bridges, bridge_id) do
      %{participants: participants} ->
        if participant_id in participants do
          {:reply, :ok, dissolve_bridge(state, bridge_id)}
        else
          {:reply, :ok, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:disconnect, participant_id}, _from, state) do
    {:reply, :ok, remove_participant(state, participant_id)}
  end

  def handle_call({:room, participant_id}, _from, state) do
    case Map.get(state.participant_room, participant_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_id ->
        room = Map.fetch!(state.rooms, room_id)
        [a, b] = room.participants
        partner_id = if a == participant_id, do: b, else: a

        {:reply,
         {:ok,
          %{
            room_id: room_id,
            own_anchor: room.contributions[participant_id],
            partner_anchor: room.contributions[partner_id]
          }}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = prune(state)

    snapshot = %{
      waiting_count: map_size(state.waiting),
      bridge_count: map_size(state.bridges),
      room_count: map_size(state.rooms),
      recent_count: length(state.recent)
    }

    {:reply, snapshot, state}
  end

  defp normalize_contribution(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @max_contribution,
      do: {:ok, trimmed},
      else: {:error, :invalid_contribution}
  end

  defp normalize_contribution(_), do: {:error, :invalid_contribution}
  defp valid_participant?(value), do: is_binary(value) and value != ""

  defp next_waiting(state, participant_id) do
    Enum.find(state.order, fn id -> id != participant_id and Map.has_key?(state.waiting, id) end)
  end

  defp bridge_for(state, participant_id) do
    with bridge_id when is_binary(bridge_id) <- Map.get(state.participant_bridge, participant_id),
         bridge when is_map(bridge) <- Map.get(state.bridges, bridge_id) do
      bridge
    else
      _ -> nil
    end
  end

  defp remove_participant(state, participant_id) do
    state = %{
      state
      | waiting: Map.delete(state.waiting, participant_id),
        order: Enum.reject(state.order, &(&1 == participant_id))
    }

    state =
      case Map.get(state.participant_bridge, participant_id) do
        nil -> state
        bridge_id -> dissolve_bridge(state, bridge_id)
      end

    case Map.get(state.participant_room, participant_id) do
      nil -> state
      room_id -> dissolve_room(state, room_id)
    end
  end

  defp dissolve_bridge(state, bridge_id) do
    case Map.pop(state.bridges, bridge_id) do
      {nil, bridges} ->
        %{state | bridges: bridges}

      {%{participants: participants}, bridges} ->
        participant_bridge = Enum.reduce(participants, state.participant_bridge, &Map.delete(&2, &1))
        %{state | bridges: bridges, participant_bridge: participant_bridge}
    end
  end

  defp dissolve_room(state, room_id) do
    case Map.pop(state.rooms, room_id) do
      {nil, rooms} ->
        %{state | rooms: rooms}

      {%{participants: participants}, rooms} ->
        participant_room = Enum.reduce(participants, state.participant_room, &Map.delete(&2, &1))
        %{state | rooms: rooms, participant_room: participant_room}
    end
  end

  defp prune(state) do
    now = now_ms()

    expired_waiting =
      state.waiting
      |> Enum.filter(fn {_id, %{at: at}} -> at + state.submission_ttl_ms <= now end)
      |> Enum.map(&elem(&1, 0))

    state = Enum.reduce(expired_waiting, state, &remove_waiting_only(&2, &1))

    expired_bridges =
      state.bridges
      |> Enum.filter(fn {_id, bridge} -> bridge.expires_at <= now end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(expired_bridges, state, &dissolve_bridge(&2, &1))
  end

  defp remove_waiting_only(state, participant_id) do
    %{
      state
      | waiting: Map.delete(state.waiting, participant_id),
        order: Enum.reject(state.order, &(&1 == participant_id))
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
