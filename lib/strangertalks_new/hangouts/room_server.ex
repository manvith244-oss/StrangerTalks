defmodule StrangertalksNew.Hangouts.RoomServer do
  use GenServer, restart: :transient

  alias StrangertalksNew.Hangouts

  alias StrangertalksNew.Hangouts.{
    DurableInteractions,
    HangoutRoom,
    Observability,
    RoomSupervisor,
    SharedContent
  }

  alias StrangertalksNew.Repo

  @registry StrangertalksNew.Hangouts.Registry
  @pubsub StrangertalksNew.PubSub

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
        {:ok, %{room_id: room_id, snapshot: snapshot}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case refresh_state(state.room_id) do
      {:ok, snapshot} -> {:reply, :ok, %{state | snapshot: snapshot}}
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
    case DurableInteractions.add_reaction(
           state.room_id,
           participant_id,
           expected_content_sequence,
           reaction
         ) do
      {:ok, result} ->
        membership = result.membership

        payload = %{
          content_sequence: result.content_sequence,
          reaction: result.reaction,
          actor: %{
            slot: membership.temporary_identity_slot,
            label: membership.temporary_identity_label,
            emoji: membership.temporary_identity_emoji
          },
          counts: result.counts
        }

        if result.changed? do
          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(state.room_id),
            {:hangout_event, "reaction:updated", payload}
          )

          Observability.emit_room(state.room_id, :reaction_accepted, %{
            count: 1,
            content_sequence: expected_content_sequence,
            reaction_count: result.counts |> Map.values() |> Enum.sum()
          })
        end

        {:reply, {:ok, payload}, refresh_interaction_snapshot(state)}

      {:error, reason, _changeset} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:vote_skip, participant_id, expected_content_sequence}, _from, state) do
    with {:ok, ratio} <- skip_quorum_ratio(),
         {:ok, result} <-
           DurableInteractions.cast_skip_vote(
             state.room_id,
             participant_id,
             expected_content_sequence,
             ratio
           ) do
      if result.new_vote? do
        Observability.emit_room(state.room_id, :skip_vote, %{
          count: 1,
          content_sequence: expected_content_sequence,
          votes: result.votes,
          required_votes: result.required_votes
        })
      end

      if result.advanced do
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(state.room_id),
          {:hangout_event, "content:changed", result.content}
        )

        payload = %{
          advanced: true,
          previous_content_sequence: result.previous_content_sequence,
          content: result.content
        }

        snapshot =
          state.snapshot
          |> Map.put(:content_sequence, result.content.sequence)
          |> Map.put(:current_content, result.content.content)

        next_state = %{state | snapshot: snapshot} |> refresh_interaction_snapshot()
        {:reply, {:ok, payload}, next_state}
      else
        payload =
          skip_pending_payload(
            result.content_sequence,
            result.votes,
            result.required_votes
          )

        if result.new_vote? do
          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(state.room_id),
            {:hangout_event, "skip:updated", payload}
          )
        end

        {:reply, {:ok, payload}, refresh_interaction_snapshot(state)}
      end
    else
      {:error, reason, _changeset} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disconnect, participant_id}, _from, state) do
    with {:ok, _membership} <- Hangouts.disconnect_member(state.room_id, participant_id),
         {:ok, snapshot} <- Hangouts.room_snapshot(state.room_id, participant_id) do
      snapshot = enrich_snapshot(snapshot)
      Observability.emit_room(state.room_id, :disconnect, %{count: 1})
      {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconnect, participant_id}, _from, state) do
    with {:ok, _membership} <- Hangouts.reconnect_member(state.room_id, participant_id),
         {:ok, snapshot} <- Hangouts.room_snapshot(state.room_id, participant_id) do
      snapshot = enrich_snapshot(snapshot)
      Observability.emit_room(state.room_id, :reconnect, %{count: 1})
      {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, participant_id, attrs}, _from, state) do
    case Hangouts.append_message(state.room_id, participant_id, attrs) do
      {:ok, message} ->
        new_message? = message.sequence > state.snapshot.message_sequence

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

          if new_message? do
            emit_message_telemetry(state.room_id, message)
          end

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

        Observability.emit(
          :room_ended,
          Observability.room_end_measurements(room),
          Observability.metadata(room)
        )

        {:stop, :normal, {:ok, terminal_snapshot}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp emit_message_telemetry(room_id, message) do
    case Repo.get(HangoutRoom, room_id) do
      %HangoutRoom{} = room ->
        measurements = %{count: 1, message_sequence: message.sequence}
        metadata = Observability.metadata(room)
        Observability.emit(:message_accepted, measurements, metadata)

        if message.sequence == 1 do
          Observability.emit(
            :first_human_message,
            %{
              count: 1,
              message_sequence: 1,
              first_message_latency_ms:
                Observability.duration_ms(message.created_at, room.activated_at)
            },
            metadata
          )
        end

        if Observability.first_response_after_current_content?(room) do
          Observability.emit(
            :first_response_after_content,
            %{
              count: 1,
              message_sequence: message.sequence,
              content_sequence: room.content_sequence,
              content_response_latency_ms:
                Observability.duration_ms(message.created_at, room.current_content_started_at)
            },
            metadata
          )
        end

      nil ->
        :ok
    end
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

        snapshot =
          state.snapshot
          |> Map.put(:content_sequence, content_state.sequence)
          |> Map.put(:current_content, content_state.content)

        next_state = %{state | snapshot: snapshot} |> refresh_interaction_snapshot()
        {:ok, content_state, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
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
      {:ok, content_state} -> enrich_snapshot(snapshot, content_state)
      {:error, _reason} -> snapshot |> Map.put(:current_content, nil) |> put_interactions()
    end
  end

  defp enrich_snapshot(snapshot, nil) do
    snapshot
    |> Map.put(:current_content, nil)
    |> put_interactions()
  end

  defp enrich_snapshot(snapshot, content_state) do
    snapshot
    |> Map.put(:content_sequence, content_state.sequence)
    |> Map.put(:current_content, content_state.content)
    |> put_interactions()
  end

  defp put_interactions(snapshot) do
    with {:ok, ratio} <- skip_quorum_ratio(),
         {:ok, interactions} <- DurableInteractions.current_summary(snapshot.room_id, ratio) do
      Map.put(snapshot, :interactions, interactions)
    else
      _ -> Map.put(snapshot, :interactions, nil)
    end
  end

  defp refresh_interaction_snapshot(state) do
    %{state | snapshot: put_interactions(state.snapshot)}
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
