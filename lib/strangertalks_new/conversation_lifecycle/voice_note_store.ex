defmodule StrangertalksNew.ConversationLifecycle.VoiceNoteStore do
  @moduledoc """
  Supervised single-node storage for transient voice-note delivery bytes.

  Audio is held in private process state only. It is never persisted and is lost on a BEAM crash.
  """

  use GenServer

  @default_global_limit 16_777_216
  @conversation_limit 3_145_728
  @note_limit 1_048_576

  def max_note_bytes, do: @note_limit

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def begin_upload(participant_id),
    do: GenServer.call(__MODULE__, {:begin_upload, participant_id})

  def finish_upload(participant_id),
    do: GenServer.call(__MODULE__, {:finish_upload, participant_id})

  def register_owner(conversation_id, pid),
    do: GenServer.call(__MODULE__, {:register_owner, conversation_id, pid})

  def put(note), do: GenServer.call(__MODULE__, {:put, note})

  def fetch(conversation_id, voice_note_id, recipient_id),
    do: GenServer.call(__MODULE__, {:fetch, conversation_id, voice_note_id, recipient_id})

  def delete(conversation_id, voice_note_id),
    do: GenServer.call(__MODULE__, {:delete, conversation_id, voice_note_id})

  def delete_conversation(conversation_id),
    do: GenServer.call(__MODULE__, {:delete_conversation, conversation_id})

  def inspect_metadata, do: GenServer.call(__MODULE__, :inspect_metadata)

  @impl true
  def init(_opts) do
    {:ok, %{notes: %{}, total_bytes: 0, uploading: MapSet.new(), owners: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:begin_upload, participant_id}, _from, state) do
    if MapSet.member?(state.uploading, participant_id) do
      {:reply, {:error, :upload_in_progress}, state}
    else
      {:reply, :ok, %{state | uploading: MapSet.put(state.uploading, participant_id)}}
    end
  end

  def handle_call({:finish_upload, participant_id}, _from, state) do
    {:reply, :ok, %{state | uploading: MapSet.delete(state.uploading, participant_id)}}
  end

  def handle_call({:register_owner, conversation_id, pid}, _from, state) do
    case state.owners[conversation_id] do
      %{pid: ^pid} ->
        {:reply, :ok, state}

      previous ->
        if previous, do: Process.demonitor(previous.ref, [:flush])
        ref = Process.monitor(pid)
        owners = Map.put(state.owners, conversation_id, %{pid: pid, ref: ref})
        monitors = state.monitors |> drop_monitor(previous) |> Map.put(ref, conversation_id)
        {:reply, :ok, %{state | owners: owners, monitors: monitors}}
    end
  end

  def handle_call({:put, note}, _from, state) do
    key = {note.conversation_id, note.voice_note_id}

    case state.notes[key] do
      existing when not is_nil(existing) ->
        if same_note?(existing, note),
          do: {:reply, {:ok, public_metadata(existing), :existing}, state},
          else: {:reply, {:error, :voice_note_id_conflict}, state}

      nil ->
        conversation_notes =
          Enum.filter(Map.values(state.notes), &(&1.conversation_id == note.conversation_id))

        conversation_bytes = Enum.sum(Enum.map(conversation_notes, & &1.byte_size))

        global_limit =
          Application.get_env(
            :strangertalks_new,
            :voice_note_global_byte_limit,
            @default_global_limit
          )

        cond do
          note.byte_size > @note_limit ->
            {:reply, {:error, :voice_note_too_large}, state}

          length(conversation_notes) >= 3 ->
            {:reply, {:error, :voice_note_pending_limit}, state}

          conversation_bytes + note.byte_size > @conversation_limit ->
            {:reply, {:error, :voice_note_conversation_capacity}, state}

          state.total_bytes + note.byte_size > global_limit ->
            {:reply, {:error, :voice_note_global_capacity}, state}

          true ->
            state = %{
              state
              | notes: Map.put(state.notes, key, note),
                total_bytes: state.total_bytes + note.byte_size
            }

            {:reply, {:ok, public_metadata(note), :inserted}, state}
        end
    end
  end

  def handle_call({:fetch, conversation_id, voice_note_id, recipient_id}, _from, state) do
    case state.notes[{conversation_id, voice_note_id}] do
      %{recipient_id: ^recipient_id} = note -> {:reply, {:ok, note}, state}
      nil -> {:reply, {:error, :voice_note_unavailable}, state}
      _note -> {:reply, {:error, :not_voice_note_recipient}, state}
    end
  end

  def handle_call({:delete, conversation_id, voice_note_id}, _from, state) do
    {note, notes} = Map.pop(state.notes, {conversation_id, voice_note_id})
    bytes = if note, do: note.byte_size, else: 0
    {:reply, :ok, %{state | notes: notes, total_bytes: max(0, state.total_bytes - bytes)}}
  end

  def handle_call({:delete_conversation, conversation_id}, _from, state) do
    {:reply, :ok, remove_conversation(state, conversation_id)}
  end

  def handle_call(:inspect_metadata, _from, state) do
    metadata = Enum.map(Map.values(state.notes), &public_metadata/1)

    {:reply, %{notes: metadata, total_bytes: state.total_bytes, uploading: state.uploading},
     state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {conversation_id, monitors} ->
        state = %{state | monitors: monitors, owners: Map.delete(state.owners, conversation_id)}
        {:noreply, remove_conversation(state, conversation_id)}
    end
  end

  defp remove_conversation(state, conversation_id) do
    {removed, kept} =
      Enum.split_with(state.notes, fn {{id, _}, _note} -> id == conversation_id end)

    bytes = removed |> Enum.map(fn {_key, note} -> note.byte_size end) |> Enum.sum()
    %{state | notes: Map.new(kept), total_bytes: max(0, state.total_bytes - bytes)}
  end

  defp same_note?(existing, note) do
    Enum.all?(
      [
        :conversation_id,
        :voice_note_id,
        :sender_id,
        :recipient_id,
        :media_type,
        :duration_ms,
        :byte_size,
        :content_hash
      ],
      fn field ->
        Map.fetch!(existing, field) == Map.fetch!(note, field)
      end
    )
  end

  defp public_metadata(note),
    do:
      Map.take(note, [
        :voice_note_id,
        :conversation_id,
        :sender_id,
        :recipient_id,
        :media_type,
        :duration_ms,
        :byte_size,
        :content_hash,
        :inserted_at,
        :expires_at
      ])

  defp drop_monitor(monitors, nil), do: monitors
  defp drop_monitor(monitors, %{ref: ref}), do: Map.delete(monitors, ref)
end
