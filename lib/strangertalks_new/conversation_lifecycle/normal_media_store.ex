defmodule StrangertalksNew.ConversationLifecycle.NormalMediaStore do
  @moduledoc """
  Volatile, conversation-scoped storage for ordinary photo and video messages.

  Normal media is reopenable while the live Conversation remains available, but it is never
  promoted to permanent history. Binaries remain private to this supervised process and are
  removed when the owning Conversation process dies or durable Conversation authority becomes
  terminal.

  Ordering is anchored to the live ConversationServer's canonical message sequence. For a new
  normal-media acceptance, this store serializes media accepts and briefly suspends the owning
  ConversationServer while it reads the exact `next_sequence` boundary and installs the media
  entry. Generic Conversation acceptance therefore cannot advance inside that critical section.
  """

  use GenServer

  alias StrangertalksNew.Conversations
  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  @default_global_limit 67_108_864
  @default_conversation_limit 20_971_520
  @max_item_bytes 5_242_880
  @sweep_interval_ms 15_000
  @system_timeout_ms 5_000
  @approved_media_types ["image/jpeg", "image/png", "image/webp", "video/mp4"]

  def max_item_bytes, do: @max_item_bytes

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def put_media(conversation_id, sender_id, client_message_id, binary, metadata)
      when is_binary(conversation_id) and is_binary(sender_id) and is_binary(client_message_id) and
             is_binary(binary) and is_map(metadata) do
    GenServer.call(
      __MODULE__,
      {:put_media, conversation_id, sender_id, client_message_id, binary, metadata}
    )
  end

  def put_media(conversation_id, sender_id, client_message_id, binary, _metadata)
      when is_binary(conversation_id) and is_binary(sender_id) and is_binary(client_message_id) and
             is_binary(binary) do
    {:error, :invalid_normal_media_metadata}
  end

  def list_media(conversation_id, participant_id)
      when is_binary(conversation_id) and is_binary(participant_id) do
    GenServer.call(__MODULE__, {:list_media, conversation_id, participant_id})
  end

  def fetch_media(conversation_id, client_message_id)
      when is_binary(conversation_id) and is_binary(client_message_id) do
    GenServer.call(__MODULE__, {:fetch_media, conversation_id, client_message_id})
  end

  def delete_media(conversation_id, client_message_id)
      when is_binary(conversation_id) and is_binary(client_message_id) do
    GenServer.call(__MODULE__, {:delete_media, conversation_id, client_message_id})
  end

  def delete_conversation(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:delete_conversation, conversation_id})
  end

  def inspect_state, do: GenServer.call(__MODULE__, :inspect_state)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep_inactive, @sweep_interval_ms)

    {:ok,
     %{
       media: %{},
       total_bytes: 0,
       conversation_bytes: %{},
       next_anchor_ordinal: %{},
       owners: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call(
        {:put_media, conversation_id, sender_id, client_message_id, binary, metadata},
        _from,
        state
      ) do
    key = {conversation_id, client_message_id}
    size = byte_size(binary)

    case validate_metadata(metadata) do
      {:ok, content_hash} ->
        handle_validated_put(
          state,
          key,
          conversation_id,
          sender_id,
          client_message_id,
          binary,
          metadata,
          content_hash,
          size
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_media, conversation_id, participant_id}, _from, state) do
    items =
      state.media
      |> Map.values()
      |> Enum.filter(&(&1.conversation_id == conversation_id))
      |> Enum.sort_by(&{&1.anchor_sequence, &1.anchor_ordinal})
      |> Enum.map(&public_entry(&1, participant_id))

    {:reply, {:ok, items}, state}
  end

  def handle_call({:fetch_media, conversation_id, client_message_id}, _from, state) do
    case Map.get(state.media, {conversation_id, client_message_id}) do
      nil -> {:reply, {:error, :media_unavailable}, state}
      entry -> {:reply, {:ok, entry.binary, entry.media_type}, state}
    end
  end

  def handle_call({:delete_media, conversation_id, client_message_id}, _from, state) do
    {:reply, :ok, drop_entry(state, {conversation_id, client_message_id})}
  end

  def handle_call({:delete_conversation, conversation_id}, _from, state) do
    {:reply, :ok, drop_conversation(state, conversation_id)}
  end

  def handle_call(:inspect_state, _from, state) do
    redacted_media =
      Map.new(state.media, fn {key, entry} ->
        {key, Map.drop(entry, [:binary])}
      end)

    {:reply, %{state | media: redacted_media}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {conversation_id, monitors} ->
        state = %{state | monitors: monitors, owners: Map.delete(state.owners, conversation_id)}
        {:noreply, drop_conversation(state, conversation_id)}
    end
  end

  def handle_info(:sweep_inactive, state) do
    inactive_ids =
      state.conversation_bytes
      |> Map.keys()
      |> Enum.filter(&inactive_for_sweep?/1)

    state = Enum.reduce(inactive_ids, state, &drop_conversation(&2, &1))
    Process.send_after(self(), :sweep_inactive, @sweep_interval_ms)
    {:noreply, state}
  end

  defp handle_validated_put(
         state,
         key,
         conversation_id,
         sender_id,
         client_message_id,
         binary,
         metadata,
         content_hash,
         size
       ) do
    case Map.get(state.media, key) do
      %{sender_id: ^sender_id, content_hash: ^content_hash} = existing ->
        case authorize_existing(conversation_id, sender_id) do
          :ok ->
            {:reply, {:ok, public_entry(existing, sender_id), :duplicate}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      nil ->
        case capacity_check(state, conversation_id, size) do
          :ok ->
            case accept_at_conversation_boundary(
                   state,
                   conversation_id,
                   sender_id,
                   client_message_id,
                   binary,
                   metadata
                 ) do
              {:ok, media, next_state} ->
                {:reply, {:ok, public_entry(media, sender_id), :created}, next_state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _conflicting_existing ->
        {:reply, {:error, :normal_media_identity_conflict}, state}
    end
  end

  defp validate_metadata(metadata) do
    with {:ok, content_hash}
         when is_binary(content_hash) and byte_size(content_hash) == 32 <-
           Map.fetch(metadata, :content_hash),
         {:ok, media_type}
         when is_binary(media_type) and media_type in @approved_media_types <-
           Map.fetch(metadata, :media_type) do
      {:ok, content_hash}
    else
      _ -> {:error, :invalid_normal_media_metadata}
    end
  end

  defp inactive_for_sweep?(conversation_id) do
    conversations_module =
      Application.get_env(
        :strangertalks_new,
        :normal_media_conversations_module,
        Conversations
      )

    try do
      case conversations_module.get_conversation(conversation_id) do
        %{conversation_status: status} when status in [:PENDING, :ACTIVE, :PAUSED] -> false
        _ -> true
      end
    rescue
      _error -> false
    catch
      :exit, _reason -> false
    end
  end

  defp capacity_check(state, conversation_id, size) do
    global_limit =
      Application.get_env(
        :strangertalks_new,
        :normal_media_global_byte_limit,
        @default_global_limit
      )

    conversation_limit =
      Application.get_env(
        :strangertalks_new,
        :normal_media_conversation_byte_limit,
        @default_conversation_limit
      )

    conversation_bytes = Map.get(state.conversation_bytes, conversation_id, 0)

    cond do
      size == 0 or size > @max_item_bytes ->
        {:error, :normal_media_too_large}

      conversation_bytes + size > conversation_limit ->
        {:error, :normal_media_conversation_capacity}

      state.total_bytes + size > global_limit ->
        {:error, :normal_media_global_capacity}

      true ->
        :ok
    end
  end

  defp authorize_existing(conversation_id, sender_id) do
    with {:ok, owner_pid} <- ConversationServer.lookup(conversation_id),
         :ok <- safe_suspend(owner_pid) do
      try do
        conversation_state = :sys.get_state(owner_pid, @system_timeout_ms)

        case canonical_anchor(conversation_state, sender_id) do
          {:ok, _anchor_sequence} -> :ok
          {:error, reason} -> {:error, reason}
        end
      catch
        :exit, _reason -> {:error, :conversation_unavailable}
      after
        safe_resume(owner_pid)
      end
    else
      {:error, :not_started} -> {:error, :conversation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept_at_conversation_boundary(
         state,
         conversation_id,
         sender_id,
         client_message_id,
         binary,
         metadata
       ) do
    with {:ok, owner_pid} <- ConversationServer.lookup(conversation_id),
         :ok <- safe_suspend(owner_pid) do
      try do
        conversation_state = :sys.get_state(owner_pid, @system_timeout_ms)

        with {:ok, anchor_sequence} <- canonical_anchor(conversation_state, sender_id) do
          ordinal_key = {conversation_id, anchor_sequence}
          anchor_ordinal = Map.get(state.next_anchor_ordinal, ordinal_key, 1)
          inserted_at = DateTime.utc_now()

          entry = %{
            conversation_id: conversation_id,
            client_message_id: client_message_id,
            sender_id: sender_id,
            binary: binary,
            media_type: Map.get(metadata, :media_type),
            byte_size: byte_size(binary),
            width: Map.get(metadata, :width),
            height: Map.get(metadata, :height),
            duration_seconds: Map.get(metadata, :duration_seconds),
            content_hash: Map.get(metadata, :content_hash),
            anchor_sequence: anchor_sequence,
            anchor_ordinal: anchor_ordinal,
            inserted_at: inserted_at
          }

          next_state =
            state
            |> ensure_owner(conversation_id, owner_pid)
            |> put_entry({conversation_id, client_message_id}, entry)

          {:ok, entry, next_state}
        end
      catch
        :exit, _reason -> {:error, :conversation_unavailable}
      after
        safe_resume(owner_pid)
      end
    else
      {:error, :not_started} -> {:error, :conversation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_anchor(conversation_state, sender_id) do
    conversation = Map.get(conversation_state, :conversation)
    lifecycle_status = Map.get(conversation_state, :lifecycle_status)
    terminal_intent = Map.get(conversation_state, :terminal_intent)
    next_sequence = Map.get(conversation_state, :next_sequence)

    cond do
      is_nil(conversation) ->
        {:error, :conversation_unavailable}

      sender_id not in [conversation.participant_a_id, conversation.participant_b_id] ->
        {:error, :not_conversation_member}

      lifecycle_status != :ACTIVE or not is_nil(terminal_intent) ->
        {:error, :conversation_terminating}

      conversation.conversation_status not in [:PENDING, :ACTIVE] ->
        {:error, :conversation_inactive}

      not is_integer(next_sequence) or next_sequence < 1 ->
        {:error, :normal_media_order_unavailable}

      true ->
        {:ok, next_sequence - 1}
    end
  end

  defp safe_suspend(pid) do
    try do
      :sys.suspend(pid)
    catch
      :exit, _reason -> {:error, :conversation_unavailable}
    end
  end

  defp safe_resume(pid) do
    if Process.alive?(pid) do
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  defp ensure_owner(state, conversation_id, owner_pid) do
    case Map.get(state.owners, conversation_id) do
      %{pid: ^owner_pid} ->
        state

      previous ->
        state =
          if previous do
            Process.demonitor(previous.ref, [:flush])
            %{state | monitors: Map.delete(state.monitors, previous.ref)}
          else
            state
          end

        ref = Process.monitor(owner_pid)

        %{
          state
          | owners: Map.put(state.owners, conversation_id, %{pid: owner_pid, ref: ref}),
            monitors: Map.put(state.monitors, ref, conversation_id)
        }
    end
  end

  defp put_entry(state, key, entry) do
    conversation_id = entry.conversation_id
    current_bytes = Map.get(state.conversation_bytes, conversation_id, 0)
    ordinal_key = {conversation_id, entry.anchor_sequence}

    %{
      state
      | media: Map.put(state.media, key, entry),
        total_bytes: state.total_bytes + entry.byte_size,
        conversation_bytes:
          Map.put(state.conversation_bytes, conversation_id, current_bytes + entry.byte_size),
        next_anchor_ordinal:
          Map.put(state.next_anchor_ordinal, ordinal_key, entry.anchor_ordinal + 1)
    }
  end

  defp drop_entry(state, key) do
    case Map.pop(state.media, key) do
      {nil, _media} ->
        state

      {entry, media} ->
        conversation_id = entry.conversation_id

        remaining =
          max(0, Map.get(state.conversation_bytes, conversation_id, 0) - entry.byte_size)

        conversation_bytes =
          if remaining == 0 do
            Map.delete(state.conversation_bytes, conversation_id)
          else
            Map.put(state.conversation_bytes, conversation_id, remaining)
          end

        %{
          state
          | media: media,
            total_bytes: max(0, state.total_bytes - entry.byte_size),
            conversation_bytes: conversation_bytes
        }
    end
  end

  defp drop_conversation(state, conversation_id) do
    media =
      state.media
      |> Enum.reject(fn {{stored_conversation_id, _message_id}, _entry} ->
        stored_conversation_id == conversation_id
      end)
      |> Map.new()

    next_anchor_ordinal =
      state.next_anchor_ordinal
      |> Enum.reject(fn {{stored_conversation_id, _anchor}, _ordinal} ->
        stored_conversation_id == conversation_id
      end)
      |> Map.new()

    removed_bytes = Map.get(state.conversation_bytes, conversation_id, 0)

    {owners, monitors} =
      case Map.pop(state.owners, conversation_id) do
        {nil, owners} ->
          {owners, state.monitors}

        {%{ref: ref}, owners} ->
          Process.demonitor(ref, [:flush])
          {owners, Map.delete(state.monitors, ref)}
      end

    %{
      state
      | media: media,
        total_bytes: max(0, state.total_bytes - removed_bytes),
        conversation_bytes: Map.delete(state.conversation_bytes, conversation_id),
        next_anchor_ordinal: next_anchor_ordinal,
        owners: owners,
        monitors: monitors
    }
  end

  defp public_entry(entry, participant_id) do
    %{
      client_message_id: entry.client_message_id,
      media_type: entry.media_type,
      byte_size: entry.byte_size,
      width: entry.width,
      height: entry.height,
      duration_seconds: entry.duration_seconds,
      anchor_sequence: entry.anchor_sequence,
      anchor_ordinal: entry.anchor_ordinal,
      sent_at: DateTime.to_iso8601(entry.inserted_at),
      mine: entry.sender_id == participant_id,
      kind: if(String.starts_with?(entry.media_type, "image/"), do: "photo", else: "video")
    }
  end
end
