defmodule StrangertalksNew.Hangouts.RoomServer do
  use GenServer, restart: :transient

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, RoomSupervisor, SharedContent}
  alias StrangertalksNew.Repo

  @registry StrangertalksNew.Hangouts.Registry
  @pubsub StrangertalksNew.PubSub
  @allowed_reactions ~w(laugh fire love wow agree)

  def child_spec(room_id) do
    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [room_id]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(room_id) when is_binary(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def ensure_started(room_id) when is_binary(room_id) do
    with {:ok, snapshot} <- Hangouts.internal_room_snapshot(room_id),
         :ok <- ensure_startable(snapshot.status) do
      case lookup(room_id) do
        {:ok, pid} -> refresh_existing(room_id, pid)
        {:error, :not_started} -> start_room(room_id)
      end
    end
  end

  def ensure_started(_room_id), do: {:error, :invalid_room_request}

  def lookup(room_id) when is_binary(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{pid, _value}] when is_pid(pid) -> {:ok, pid}
      [] -> {:error, :not_started}
    end
  end

  def lookup(_room_id), do: {:error, :invalid_room_request}

  def snapshot(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, {:snapshot, participant_id})
    end
  end

  def snapshot(_room_id, _participant_id), do: {:error, :invalid_snapshot_request}

  def current_content(room_id) when is_binary(room_id) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, :current_content)
    end
  end

  def current_content(_room_id), do: {:error, :invalid_room_request}

  def advance_content(room_id) when is_binary(room_id) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, :advance_content)
    end
  end

  def advance_content(_room_id), do: {:error, :invalid_room_request}

  def add_reaction(room_id, participant_id, expected_content_sequence, reaction)
      when is_binary(room_id) and is_binary(participant_id) and
             is_integer(expected_content_sequence) and expected_content_sequence >= 0 and
             is_binary(reaction) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(
        pid,
        {:add_reaction, participant_id, expected_content_sequence, reaction}
      )
    end
  end

  def add_reaction(_room_id, _participant_id, _expected_content_sequence, _reaction),
    do: {:error, :invalid_reaction_request}

  def vote_skip(room_id, participant_id, expected_content_sequence)
      when is_binary(room_id) and is_binary(participant_id) and
             is_integer(expected_content_sequence) and expected_content_sequence >= 0 do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, {:vote_skip, participant_id, expected_content_sequence})
    end
  end

  def vote_skip(_room_id, _participant_id, _expected_content_sequence),
    do: {:error, :invalid_skip_request}

  def disconnect(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, {:disconnect, participant_id})
    end
  end

  def disconnect(_room_id, _participant_id), do: {:error, :invalid_membership_request}

  def reconnect(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, {:reconnect, participant_id})
    end
  end

  def reconnect(_room_id, _participant_id), do: {:error, :invalid_membership_request}

  def send_message(room_id, participant_id, attrs)
      when is_binary(room_id) and is_binary(participant_id) and is_map(attrs) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, {:send_message, participant_id, attrs})
    end
  end

  def send_message(_room_id, _participant_id, _attrs), do: {:error, :invalid_message_request}

  def end_room(room_id) when is_binary(room_id) do
    with {:ok, pid} <- ensure_started(room_id) do
      GenServer.call(pid, :end_room)
    end
  end

  def end_room(_room_id), do: {:error, :invalid_room_request}

  @impl true
  def init(room_id) do
    case refresh_state(room_id) do
      {:ok, snapshot} ->
        {:ok,
         %{
           room_id: room_id,
           snapshot: snapshot,
           interaction_sequence: snapshot.content_sequence,
           reactions: %{},
           skip_voters: MapSet.new()
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case refresh_state(state.room_id) do
      {:ok, snapshot} -> {:reply, :ok, refreshed_state(state, snapshot)}
      {:error, :terminal_room} -> {:stop, :normal, {:error, :terminal_room}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:snapshot, participant_id}, _from, state) do
    case Hangouts.room_snapshot(state.room_id, participant_id) do
      {:ok, snapshot} ->
        snapshot = enrich_snapshot(snapshot)
        {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:current_content, _from, state) do
    {:reply, SharedContent.current(state.room_id), state}
  end

  def handle_call(:advance_content, _from, state) do
    case perform_content_advance(state, :any) do
      {:ok, content_state, next_state} ->
        {:reply, {:ok, content_state}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call(
        {:add_reaction, participant_id, expected_content_sequence, reaction},
        _from,
        state
      ) do
    cond do
      reaction not in @allowed_reactions ->
        {:reply, {:error, :invalid_reaction}, state}

      true ->
        case interaction_context(state.room_id, participant_id, expected_content_sequence) do
          {:ok, membership, _snapshot} ->
            state = align_interactions(state, expected_content_sequence)
            previous = Map.get(state.reactions, participant_id)

            if previous == reaction do
              payload = reaction_payload(state, membership, reaction)
              {:reply, {:ok, payload}, state}
            else
              reactions = Map.put(state.reactions, participant_id, reaction)
              next_state = %{state | reactions: reactions}
              payload = reaction_payload(next_state, membership, reaction)

              Phoenix.PubSub.broadcast(
                @pubsub,
                topic(state.room_id),
                {:hangout_event, "reaction:updated", payload}
              )

              {:reply, {:ok, payload}, next_state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:vote_skip, participant_id, expected_content_sequence}, _from, state) do
    with {:ok, _membership, snapshot} <-
           interaction_context(state.room_id, participant_id, expected_content_sequence),
         {:ok, ratio} <- skip_quorum_ratio() do
      state = align_interactions(state, expected_content_sequence)
      active_ids = active_participant_ids(snapshot)
      voters = MapSet.intersection(state.skip_voters, active_ids)
      already_voted? = MapSet.member?(voters, participant_id)
      voters = MapSet.put(voters, participant_id)
      next_state = %{state | skip_voters: voters}
      required_votes = required_skip_votes(MapSet.size(active_ids), ratio)
      vote_count = MapSet.size(voters)

      cond do
        already_voted? ->
          payload = skip_pending_payload(expected_content_sequence, vote_count, required_votes)
          {:reply, {:ok, payload}, next_state}

        vote_count < required_votes ->
          payload = skip_pending_payload(expected_content_sequence, vote_count, required_votes)

          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(state.room_id),
            {:hangout_event, "skip:updated", payload}
          )

          {:reply, {:ok, payload}, next_state}

        true ->
          case perform_content_advance(next_state, expected_content_sequence) do
            {:ok, content_state, advanced_state} ->
              payload = %{
                advanced: true,
                previous_content_sequence: expected_content_sequence,
                content: content_state
              }

              {:reply, {:ok, payload}, advanced_state}

            {:error, reason, failed_state} ->
              {:reply, {:error, reason}, failed_state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disconnect, participant_id}, _from, state) do
    with {:ok, _membership} <- Hangouts.disconnect_member(state.room_id, participant_id),
         {:ok, snapshot} <- Hangouts.room_snapshot(state.room_id, participant_id) do
      snapshot = enrich_snapshot(snapshot)
      {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconnect, participant_id}, _from, state) do
    with {:ok, _membership} <- Hangouts.reconnect_member(state.room_id, participant_id),
         {:ok, snapshot} <- Hangouts.room_snapshot(state.room_id, participant_id) do
      snapshot = enrich_snapshot(snapshot)
      {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, participant_id, attrs}, _from, state) do
    case Hangouts.append_message(state.room_id, participant_id, attrs) do
      {:ok, message} ->
        with {:ok, snapshot} <- Hangouts.room_snapshot(state.room_id, participant_id),
             snapshot <- enrich_snapshot(snapshot),
             %{identity: identity} <- Enum.find(snapshot.members, & &1.self) do
          public_message = %{
            message_id: message.message_id,
            sequence: message.sequence,
            body: message.body,
            created_at: message.created_at,
            sender: identity
          }

          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(state.room_id),
            {:hangout_event, "message:new", public_message}
          )

          {:reply, {:ok, public_message}, %{state | snapshot: snapshot}}
        else
          nil -> {:reply, {:error, :membership_not_active}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, :invalid_message, changeset} ->
        {:reply, {:error, :invalid_message, changeset}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:end_room, _from, state) do
    case Hangouts.end_room(state.room_id) do
      {:ok, room} ->
        terminal_snapshot = %{
          room_id: room.room_id,
          status: room.status,
          message_sequence: room.message_sequence,
          content_sequence: room.content_sequence
        }

        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(state.room_id),
          {:hangout_event, "room:ended", terminal_snapshot}
        )

        {:stop, :normal, {:ok, terminal_snapshot}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp interaction_context(room_id, participant_id, expected_content_sequence) do
    with {:ok, snapshot} <- Hangouts.internal_room_snapshot(room_id),
         :ok <- interaction_room_available(snapshot),
         :ok <- expected_sequence_matches(snapshot.content_sequence, expected_content_sequence),
         {:ok, membership} <- active_membership(room_id, participant_id) do
      {:ok, membership, snapshot}
    end
  end

  defp interaction_room_available(%{status: status}) when status in [:ENDING, :ENDED],
    do: {:error, :terminal_room}

  defp interaction_room_available(%{experiment_arm: :GROUP_NO_CONTENT}),
    do: {:error, :content_disabled}

  defp interaction_room_available(%{status: :ACTIVE}), do: :ok
  defp interaction_room_available(_snapshot), do: {:error, :room_not_active}

  defp expected_sequence_matches(sequence, sequence), do: :ok
  defp expected_sequence_matches(_canonical, _expected), do: {:error, :stale_content}

  defp active_membership(room_id, participant_id) do
    case Repo.get_by(HangoutMembership, room_id: room_id, participant_id: participant_id) do
      nil -> {:error, :membership_not_found}
      %HangoutMembership{status: :ACTIVE} = membership -> {:ok, membership}
      %HangoutMembership{} -> {:error, :membership_not_active}
    end
  end

  defp active_participant_ids(snapshot) do
    snapshot.members
    |> Enum.filter(&(&1.status == :ACTIVE))
    |> Enum.map(& &1.participant_id)
    |> MapSet.new()
  end

  defp reaction_payload(state, membership, reaction) do
    %{
      content_sequence: state.interaction_sequence,
      reaction: reaction,
      actor: %{
        slot: membership.temporary_identity_slot,
        label: membership.temporary_identity_label,
        emoji: membership.temporary_identity_emoji
      },
      counts: state.reactions |> Map.values() |> Enum.frequencies()
    }
  end

  defp skip_pending_payload(content_sequence, votes, required_votes) do
    %{
      advanced: false,
      content_sequence: content_sequence,
      votes: votes,
      required_votes: required_votes
    }
  end

  defp skip_quorum_ratio do
    ratio = Application.get_env(:strangertalks_new, :hangout_skip_quorum_ratio, 0.5)

    if is_number(ratio) and ratio > 0 and ratio < 1 do
      {:ok, ratio}
    else
      {:error, :invalid_skip_quorum_ratio}
    end
  end

  defp required_skip_votes(active_count, ratio) do
    floor(active_count * ratio) + 1
  end

  defp perform_content_advance(state, expected_sequence) do
    result =
      case expected_sequence do
        :any -> SharedContent.advance(state.room_id)
        sequence -> SharedContent.advance(state.room_id, sequence)
      end

    case result do
      {:ok, content_state} ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(state.room_id),
          {:hangout_event, "content:changed", content_state}
        )

        snapshot = %{
          state.snapshot
          | content_sequence: content_state.sequence,
            current_content: content_state.content
        }

        next_state =
          state
          |> Map.put(:snapshot, snapshot)
          |> reset_interactions(content_state.sequence)

        {:ok, content_state, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp align_interactions(state, content_sequence) do
    if state.interaction_sequence == content_sequence do
      state
    else
      reset_interactions(state, content_sequence)
    end
  end

  defp reset_interactions(state, content_sequence) do
    %{
      state
      | interaction_sequence: content_sequence,
        reactions: %{},
        skip_voters: MapSet.new()
    }
  end

  defp refreshed_state(state, snapshot) do
    state = %{state | snapshot: snapshot}
    align_interactions(state, snapshot.content_sequence)
  end

  defp refresh_state(room_id) do
    with {:ok, _room} <- Hangouts.activate_if_ready(room_id),
         {:ok, _content_state} <- SharedContent.ensure_initial(room_id),
         {:ok, snapshot} <- Hangouts.internal_room_snapshot(room_id),
         {:ok, current_content} <- SharedContent.current(room_id) do
      {:ok, enrich_snapshot(snapshot, current_content)}
    end
  end

  defp enrich_snapshot(snapshot) do
    case SharedContent.current(snapshot.room_id) do
      {:ok, nil} -> Map.put(snapshot, :current_content, nil)
      {:ok, content_state} -> Map.put(snapshot, :current_content, content_state.content)
      {:error, _reason} -> Map.put(snapshot, :current_content, nil)
    end
  end

  defp enrich_snapshot(snapshot, nil), do: Map.put(snapshot, :current_content, nil)

  defp enrich_snapshot(snapshot, content_state) do
    snapshot
    |> Map.put(:content_sequence, content_state.sequence)
    |> Map.put(:current_content, content_state.content)
  end

  defp refresh_existing(room_id, pid) do
    try do
      case GenServer.call(pid, :refresh) do
        :ok -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _reason ->
        case lookup(room_id) do
          {:ok, replacement} -> {:ok, replacement}
          {:error, :not_started} -> start_room(room_id)
        end
    end
  end

  defp start_room(room_id) do
    case RoomSupervisor.start_room(room_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        refresh_existing(room_id, pid)

      {:error, :terminal_room} ->
        {:error, :terminal_room}

      {:error, reason} ->
        case lookup(room_id) do
          {:ok, pid} -> refresh_existing(room_id, pid)
          {:error, :not_started} -> {:error, normalize_start_error(reason)}
        end
    end
  end

  defp ensure_startable(status) when status in [:FORMING, :ACTIVE], do: :ok
  defp ensure_startable(_status), do: {:error, :terminal_room}

  defp normalize_start_error({:shutdown, reason}), do: reason
  defp normalize_start_error(reason), do: reason

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
  defp topic(room_id), do: "hangout:#{room_id}"
end
