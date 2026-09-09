defmodule StrangertalksNew.Hangouts.RoomServer do
  use GenServer, restart: :transient

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{RoomSupervisor, SharedContent}

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
      {:ok, snapshot} -> {:ok, %{room_id: room_id, snapshot: snapshot}}
      {:error, reason} -> {:stop, reason}
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
    case SharedContent.advance(state.room_id) do
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

        {:reply, {:ok, content_state}, %{state | snapshot: snapshot}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  defp refresh_state(room_id) do
    with {:ok, _room} <- Hangouts.activate_if_ready(room_id),
         {:ok, _content_state} <- SharedContent.ensure_initial(room_id),
         {:ok, snapshot} <- Hangouts.internal_room_snapshot(room_id) do
      {:ok, enrich_snapshot(snapshot)}
    end
  end

  defp enrich_snapshot(snapshot) do
    case SharedContent.current(snapshot.room_id) do
      {:ok, nil} -> Map.put(snapshot, :current_content, nil)
      {:ok, content_state} -> Map.put(snapshot, :current_content, content_state.content)
      {:error, _reason} -> Map.put(snapshot, :current_content, nil)
    end
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
