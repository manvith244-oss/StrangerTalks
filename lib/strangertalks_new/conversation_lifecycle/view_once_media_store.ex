defmodule StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore do
  @moduledoc """
  Supervised single-node storage for transient View-Once photo binaries.

  Image binaries are held in private process state only.
  Enforces:
  - Bounded volatile storage (per-item <= 1 MiB, per-conversation <= 2 MiB, global <= 16 MiB)
  - Atomically enforced 1 UNVIEWED item per sender in a conversation
  - Single-use presentation capability consumption (at most 1 byte delivery)
  - 10-minute safety-grace period after consumption for server-owned safety report evidence
  - Immediate cleanup on conversation termination or BEAM crash
  """

  use GenServer

  @default_global_limit 33_554_432
  @default_conversation_limit 6_291_456
  @item_limit 5_242_880
  @presentation_reservation_limit 10_485_760

  @staging_ttl_ms 60_000
  @capability_ttl_ms 30_000
  @safety_grace_ttl_ms 600_000

  def max_item_bytes, do: @item_limit
  def presentation_reservation_limit, do: @presentation_reservation_limit

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  def register_owner(conversation_id, pid) when is_binary(conversation_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register_owner, conversation_id, pid})
  end

  def stage_media(conversation_id, sender_id, binary)
      when is_binary(conversation_id) and is_binary(sender_id) and is_binary(binary) do
    with {:ok, metadata} <-
           StrangertalksNew.ConversationLifecycle.ViewOnceMediaValidator.validate(binary) do
      stage_media(conversation_id, sender_id, binary, metadata)
    end
  end

  def stage_media(conversation_id, sender_id, binary, metadata)
      when is_binary(conversation_id) and is_binary(sender_id) and is_binary(binary) and
             is_map(metadata) do
    GenServer.call(__MODULE__, {:stage_media, conversation_id, sender_id, binary, metadata})
  end

  def claim_staged_media(
        staging_token,
        conversation_id,
        sender_id,
        client_message_id,
        recipient_id,
        presentation_limit \\ 1
      )
      when is_binary(staging_token) and is_binary(conversation_id) and is_binary(sender_id) and
             is_binary(client_message_id) and is_binary(recipient_id) and
             presentation_limit in [1, 2] do
    GenServer.call(
      __MODULE__,
      {:claim_staged_media, staging_token, conversation_id, sender_id, client_message_id,
       recipient_id, presentation_limit}
    )
  end

  def reserve_presentation_capacity(conversation_id, client_message_id, recipient_id)
      when is_binary(conversation_id) and is_binary(client_message_id) and
             is_binary(recipient_id) do
    GenServer.call(
      __MODULE__,
      {:reserve_presentation_capacity, conversation_id, client_message_id, recipient_id}
    )
  end

  def release_presentation_reservation(reservation_token) when is_binary(reservation_token) do
    GenServer.call(__MODULE__, {:release_presentation_reservation, reservation_token})
  end

  def issue_presentation_capability(conversation_id, client_message_id, recipient_id, epoch_id)
      when is_binary(conversation_id) and is_binary(client_message_id) and
             is_binary(recipient_id) and is_binary(epoch_id) do
    GenServer.call(
      __MODULE__,
      {:issue_presentation_capability, conversation_id, client_message_id, recipient_id, epoch_id}
    )
  end

  def consume_presentation(conversation_id, client_message_id, presentation_token, recipient_id) do
    consume_presentation_capability(
      conversation_id,
      client_message_id,
      presentation_token,
      recipient_id,
      nil
    )
  end

  def consume_presentation_capability(
        conversation_id,
        client_message_id,
        presentation_token,
        recipient_id,
        epoch_id \\ nil
      )
      when is_binary(conversation_id) and is_binary(client_message_id) and
             is_binary(presentation_token) and is_binary(recipient_id) do
    GenServer.call(
      __MODULE__,
      {:consume_presentation_capability, conversation_id, client_message_id, presentation_token,
       recipient_id, epoch_id}
    )
  end

  def capture_safety_media(conversation_id, client_message_id)
      when is_binary(conversation_id) and is_binary(client_message_id) do
    GenServer.call(__MODULE__, {:capture_safety_media, conversation_id, client_message_id})
  end

  def delete_media(conversation_id, client_message_id)
      when is_binary(conversation_id) and is_binary(client_message_id) do
    GenServer.call(__MODULE__, {:delete_media, conversation_id, client_message_id})
  end

  def delete_conversation(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:delete_conversation, conversation_id})
  end

  def has_media?(conversation_id, client_message_id)
      when is_binary(conversation_id) and is_binary(client_message_id) do
    GenServer.call(__MODULE__, {:has_media?, conversation_id, client_message_id})
  end

  def inspect_state do
    GenServer.call(__MODULE__, :inspect_state)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok,
     %{
       staged: %{},
       media: %{},
       capabilities: %{},
       presentation_reservations: %{},
       presentation_reserved_bytes: 0,
       total_bytes: 0,
       owners: %{},
       monitors: %{}
     }}
  end

  @impl true
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

  def handle_call({:stage_media, conversation_id, sender_id, binary, metadata}, _from, state) do
    size = byte_size(binary)

    global_limit =
      Application.get_env(:strangertalks_new, :view_once_global_byte_limit, @default_global_limit)

    conv_limit =
      Application.get_env(
        :strangertalks_new,
        :view_once_conversation_byte_limit,
        @default_conversation_limit
      )

    conv_bytes = conversation_byte_count(state, conversation_id)

    cond do
      size > @item_limit ->
        {:reply, {:error, :view_once_photo_too_large}, state}

      conv_bytes + size > conv_limit ->
        {:reply, {:error, :view_once_conversation_capacity}, state}

      state.total_bytes + size > global_limit ->
        {:reply, {:error, :view_once_global_capacity}, state}

      true ->
        staging_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        timer_ref = Process.send_after(self(), {:expire_staged, staging_token}, @staging_ttl_ms)

        staged_entry = %{
          staging_token: staging_token,
          conversation_id: conversation_id,
          sender_id: sender_id,
          binary: binary,
          media_type: metadata.media_type,
          byte_size: size,
          width: Map.get(metadata, :width),
          height: Map.get(metadata, :height),
          duration_seconds: Map.get(metadata, :duration_seconds),
          content_hash: metadata.content_hash,
          timer_ref: timer_ref,
          inserted_at: System.monotonic_time()
        }

        state = %{
          state
          | staged: Map.put(state.staged, staging_token, staged_entry),
            total_bytes: state.total_bytes + size
        }

        {:reply, {:ok, staging_token}, state}
    end
  end

  def handle_call(
        {:claim_staged_media, staging_token, conversation_id, sender_id, client_message_id,
         recipient_id, presentation_limit},
        _from,
        state
      ) do
    case Map.pop(state.staged, staging_token) do
      {nil, _staged} ->
        {:reply, {:error, :invalid_staging_token}, state}

      {%{conversation_id: ^conversation_id, sender_id: ^sender_id} = staged, remaining_staged} ->
        cancel_timer(staged.timer_ref)

        # Enforce max 1 UNVIEWED / active item per sender in this conversation
        sender_unviewed_count =
          state.media
          |> Map.values()
          |> Enum.count(fn item ->
            item.conversation_id == conversation_id and item.sender_id == sender_id and
              item.status in [:unviewed, :partially_viewed]
          end)

        if sender_unviewed_count >= 1 do
          # Revert staged state & release bytes
          {:reply, {:error, :view_once_sender_unviewed_limit},
           %{state | staged: remaining_staged, total_bytes: state.total_bytes - staged.byte_size}}
        else
          media_key = {conversation_id, client_message_id}

          media_entry = %{
            conversation_id: conversation_id,
            client_message_id: client_message_id,
            sender_id: sender_id,
            recipient_id: recipient_id,
            binary: staged.binary,
            media_type: staged.media_type,
            byte_size: staged.byte_size,
            width: staged.width,
            height: staged.height,
            duration_seconds: staged.duration_seconds,
            content_hash: staged.content_hash,
            presentation_limit: presentation_limit,
            views_remaining: presentation_limit,
            views_consumed: 0,
            status: :unviewed,
            grace_timer_ref: nil,
            inserted_at: DateTime.utc_now()
          }

          state = %{
            state
            | staged: remaining_staged,
              media: Map.put(state.media, media_key, media_entry)
          }

          result = %{
            media_type: staged.media_type,
            byte_size: staged.byte_size,
            width: staged.width,
            height: staged.height,
            duration_seconds: staged.duration_seconds,
            content_hash: staged.content_hash,
            presentation_limit: presentation_limit,
            views_remaining: presentation_limit,
            views_consumed: 0
          }

          {:reply, {:ok, result}, state}
        end

      {staged, remaining_staged} ->
        cancel_timer(staged.timer_ref)

        {:reply, {:error, :invalid_staging_token},
         %{state | staged: remaining_staged, total_bytes: state.total_bytes - staged.byte_size}}
    end
  end

  def handle_call(
        {:reserve_presentation_capacity, conversation_id, client_message_id, recipient_id},
        _from,
        state
      ) do
    media_key = {conversation_id, client_message_id}

    case state.media[media_key] do
      %{recipient_id: ^recipient_id, status: status} = media
      when status in [:unviewed, :partially_viewed] ->
        needed_bytes = media.byte_size

        presentation_limit =
          Application.get_env(
            :strangertalks_new,
            :view_once_presentation_reservation_limit,
            @presentation_reservation_limit
          )

        if state.presentation_reserved_bytes + needed_bytes > presentation_limit do
          {:reply, {:error, :presentation_capacity_unavailable}, state}
        else
          reservation_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

          timer_ref =
            Process.send_after(
              self(),
              {:expire_reservation, reservation_token},
              @capability_ttl_ms
            )

          reservation = %{
            token: reservation_token,
            conversation_id: conversation_id,
            client_message_id: client_message_id,
            byte_size: needed_bytes,
            timer_ref: timer_ref
          }

          new_reserved = state.presentation_reserved_bytes + needed_bytes

          {:reply, {:ok, reservation_token},
           %{
             state
             | presentation_reserved_bytes: new_reserved,
               presentation_reservations:
                 Map.put(state.presentation_reservations, reservation_token, reservation)
           }}
        end

      %{recipient_id: ^recipient_id, status: :safety_grace} ->
        {:reply, {:error, :already_consumed}, state}

      nil ->
        {:reply, {:error, :media_unavailable}, state}

      _foreign_recipient ->
        {:reply, {:error, :not_conversation_member}, state}
    end
  end

  def handle_call({:release_presentation_reservation, reservation_token}, _from, state) do
    case Map.pop(state.presentation_reservations, reservation_token) do
      {nil, _res} ->
        {:reply, :ok, state}

      {res, remaining} ->
        cancel_timer(res.timer_ref)

        {:reply, :ok,
         %{
           state
           | presentation_reservations: remaining,
             presentation_reserved_bytes:
               max(0, state.presentation_reserved_bytes - res.byte_size)
         }}
    end
  end

  def handle_call(
        {:issue_presentation_capability, conversation_id, client_message_id, recipient_id,
         epoch_id},
        _from,
        state
      ) do
    media_key = {conversation_id, client_message_id}

    case state.media[media_key] do
      %{recipient_id: ^recipient_id, status: status} = media
      when status in [:unviewed, :partially_viewed] ->
        views_remaining = Map.get(media, :views_remaining, 1) - 1
        views_consumed = Map.get(media, :views_consumed, 0) + 1

        presentation_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

        cap_timer =
          Process.send_after(self(), {:expire_capability, presentation_token}, @capability_ttl_ms)

        # Clear one matching reservation for this media to avoid double-counting
        {kept_res, res_bytes} =
          case Enum.find(state.presentation_reservations, fn {_k, res} ->
                 res.conversation_id == conversation_id and
                   res.client_message_id == client_message_id
               end) do
            {res_token, res} ->
              cancel_timer(res.timer_ref)
              {Map.delete(state.presentation_reservations, res_token), res.byte_size}

            nil ->
              {state.presentation_reservations, 0}
          end

        capability = %{
          presentation_token: presentation_token,
          conversation_id: conversation_id,
          client_message_id: client_message_id,
          recipient_id: recipient_id,
          epoch_id: epoch_id,
          byte_size: media.byte_size,
          timer_ref: cap_timer,
          inserted_at: System.monotonic_time()
        }

        # Handle safety grace timer: start on first consumption if not already active
        grace_timer =
          if media.grace_timer_ref do
            media.grace_timer_ref
          else
            Process.send_after(
              self(),
              {:expire_safety_grace, conversation_id, client_message_id},
              @safety_grace_ttl_ms
            )
          end

        new_status = if views_remaining <= 0, do: :safety_grace, else: :partially_viewed

        updated_media = %{
          media
          | status: new_status,
            views_remaining: max(0, views_remaining),
            views_consumed: views_consumed,
            grace_timer_ref: grace_timer
        }

        # Keep reserved bytes accurate (if reservation existed, replace reservation bytes with cap bytes)
        new_reserved =
          max(0, state.presentation_reserved_bytes - res_bytes) + media.byte_size

        state = %{
          state
          | capabilities: Map.put(state.capabilities, presentation_token, capability),
            presentation_reservations: kept_res,
            presentation_reserved_bytes: new_reserved,
            media: Map.put(state.media, media_key, updated_media)
        }

        {:reply, {:ok, presentation_token}, state}

      %{recipient_id: ^recipient_id, status: :safety_grace} ->
        {:reply, {:error, :already_consumed}, state}

      nil ->
        {:reply, {:error, :media_unavailable}, state}

      _foreign_recipient ->
        {:reply, {:error, :not_conversation_member}, state}
    end
  end

  def handle_call(
        {:consume_presentation_capability, conversation_id, client_message_id, presentation_token,
         recipient_id, epoch_id},
        _from,
        state
      ) do
    case Map.pop(state.capabilities, presentation_token) do
      {nil, _caps} ->
        # Capability already consumed (replay) or expired -> zero bytes
        {:reply, {:error, :capability_invalid_or_expired}, state}

      {%{
         conversation_id: ^conversation_id,
         client_message_id: ^client_message_id,
         recipient_id: ^recipient_id
       } = cap, remaining_caps} ->
        cancel_timer(cap.timer_ref)

        new_reserved =
          max(0, state.presentation_reserved_bytes - Map.get(cap, :byte_size, 0))

        state = %{
          state
          | capabilities: remaining_caps,
            presentation_reserved_bytes: new_reserved
        }

        # Check epoch if provided
        if epoch_id != nil and cap.epoch_id != nil and epoch_id != cap.epoch_id do
          {:reply, {:error, :invalid_request}, state}
        else
          media_key = {conversation_id, client_message_id}

          case state.media[media_key] do
            %{binary: binary, media_type: media_type} ->
              {:reply, {:ok, binary, media_type}, state}

            nil ->
              {:reply, {:error, :media_unavailable}, state}
          end
        end

      {cap, remaining_caps} ->
        cancel_timer(cap.timer_ref)

        new_reserved =
          max(0, state.presentation_reserved_bytes - Map.get(cap, :byte_size, 0))

        {:reply, {:error, :invalid_request},
         %{
           state
           | capabilities: remaining_caps,
             presentation_reserved_bytes: new_reserved
         }}
    end
  end

  def handle_call({:capture_safety_media, conversation_id, client_message_id}, _from, state) do
    media_key = {conversation_id, client_message_id}

    case state.media[media_key] do
      %{binary: binary, media_type: media_type, byte_size: byte_size} ->
        {:reply, {:ok, %{binary: binary, media_type: media_type, byte_size: byte_size}}, state}

      nil ->
        {:reply, {:error, :media_unavailable}, state}
    end
  end

  def handle_call({:delete_media, conversation_id, client_message_id}, _from, state) do
    media_key = {conversation_id, client_message_id}
    {removed, media} = Map.pop(state.media, media_key)

    bytes =
      if removed do
        cancel_timer(removed.grace_timer_ref)
        removed.byte_size
      else
        0
      end

    # Also clean any dangling capabilities for this message
    {removed_caps, capabilities} =
      Enum.split_with(state.capabilities, fn {_tok, cap} ->
        cap.conversation_id == conversation_id and cap.client_message_id == client_message_id
      end)

    Enum.each(removed_caps, fn {_tok, cap} -> cancel_timer(cap.timer_ref) end)

    cap_bytes =
      removed_caps |> Enum.map(fn {_tok, c} -> Map.get(c, :byte_size, 0) end) |> Enum.sum()

    {removed_res, reservations} =
      Enum.split_with(state.presentation_reservations, fn {_tok, res} ->
        res.conversation_id == conversation_id and res.client_message_id == client_message_id
      end)

    Enum.each(removed_res, fn {_tok, res} -> cancel_timer(res.timer_ref) end)
    res_bytes = removed_res |> Enum.map(fn {_tok, r} -> r.byte_size end) |> Enum.sum()

    {:reply, :ok,
     %{
       state
       | media: media,
         capabilities: Map.new(capabilities),
         presentation_reservations: Map.new(reservations),
         presentation_reserved_bytes:
           max(0, state.presentation_reserved_bytes - cap_bytes - res_bytes),
         total_bytes: max(0, state.total_bytes - bytes)
     }}
  end

  def handle_call({:delete_conversation, conversation_id}, _from, state) do
    {:reply, :ok, remove_conversation(state, conversation_id)}
  end

  def handle_call({:has_media?, conversation_id, client_message_id}, _from, state) do
    exists? = Map.has_key?(state.media, {conversation_id, client_message_id})
    {:reply, exists?, state}
  end

  def handle_call(:inspect_state, _from, state) do
    summary = %{
      staged_count: map_size(state.staged),
      media_count: map_size(state.media),
      capabilities_count: map_size(state.capabilities),
      presentation_reservations_count: map_size(state.presentation_reservations),
      presentation_reserved_bytes: state.presentation_reserved_bytes,
      total_bytes: state.total_bytes
    }

    {:reply, summary, state}
  end

  # ============================================================================
  # GenServer handle_info
  # ============================================================================

  @impl true
  def handle_info({:expire_staged, staging_token}, state) do
    case Map.pop(state.staged, staging_token) do
      {nil, _staged} ->
        {:noreply, state}

      {staged, remaining_staged} ->
        {:noreply,
         %{
           state
           | staged: remaining_staged,
             total_bytes: max(0, state.total_bytes - staged.byte_size)
         }}
    end
  end

  def handle_info({:expire_reservation, reservation_token}, state) do
    case Map.pop(state.presentation_reservations, reservation_token) do
      {nil, _} ->
        {:noreply, state}

      {res, remaining} ->
        {:noreply,
         %{
           state
           | presentation_reservations: remaining,
             presentation_reserved_bytes:
               max(0, state.presentation_reserved_bytes - res.byte_size)
         }}
    end
  end

  def handle_info({:expire_capability, presentation_token}, state) do
    case Map.pop(state.capabilities, presentation_token) do
      {nil, _} ->
        {:noreply, state}

      {cap, remaining} ->
        {:noreply,
         %{
           state
           | capabilities: remaining,
             presentation_reserved_bytes:
               max(0, state.presentation_reserved_bytes - Map.get(cap, :byte_size, 0))
         }}
    end
  end

  def handle_info({:expire_safety_grace, conversation_id, client_message_id}, state) do
    media_key = {conversation_id, client_message_id}

    case Map.pop(state.media, media_key) do
      {nil, _media} ->
        {:noreply, state}

      {media, remaining_media} ->
        {:noreply,
         %{
           state
           | media: remaining_media,
             total_bytes: max(0, state.total_bytes - media.byte_size)
         }}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {conversation_id, monitors} ->
        state = %{state | monitors: monitors, owners: Map.delete(state.owners, conversation_id)}
        {:noreply, remove_conversation(state, conversation_id)}
    end
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp conversation_byte_count(state, conversation_id) do
    staged_bytes =
      state.staged
      |> Map.values()
      |> Enum.filter(&(&1.conversation_id == conversation_id))
      |> Enum.map(& &1.byte_size)
      |> Enum.sum()

    media_bytes =
      state.media
      |> Map.values()
      |> Enum.filter(&(&1.conversation_id == conversation_id))
      |> Enum.map(& &1.byte_size)
      |> Enum.sum()

    staged_bytes + media_bytes
  end

  defp remove_conversation(state, conversation_id) do
    {removed_staged, kept_staged} =
      Enum.split_with(state.staged, fn {_k, v} -> v.conversation_id == conversation_id end)

    {removed_media, kept_media} =
      Enum.split_with(state.media, fn {{id, _}, _v} -> id == conversation_id end)

    Enum.each(removed_staged, fn {_k, v} -> cancel_timer(v.timer_ref) end)
    Enum.each(removed_media, fn {_k, v} -> cancel_timer(v.grace_timer_ref) end)

    staged_bytes = removed_staged |> Enum.map(fn {_k, v} -> v.byte_size end) |> Enum.sum()
    media_bytes = removed_media |> Enum.map(fn {_k, v} -> v.byte_size end) |> Enum.sum()

    {removed_caps, kept_caps} =
      Enum.split_with(state.capabilities, fn {_tok, cap} ->
        cap.conversation_id == conversation_id
      end)

    Enum.each(removed_caps, fn {_tok, cap} -> cancel_timer(cap.timer_ref) end)

    cap_bytes =
      removed_caps |> Enum.map(fn {_tok, c} -> Map.get(c, :byte_size, 0) end) |> Enum.sum()

    {removed_res, kept_res} =
      Enum.split_with(state.presentation_reservations, fn {_tok, res} ->
        res.conversation_id == conversation_id
      end)

    Enum.each(removed_res, fn {_tok, res} -> cancel_timer(res.timer_ref) end)
    res_bytes = removed_res |> Enum.map(fn {_tok, r} -> r.byte_size end) |> Enum.sum()

    %{
      state
      | staged: Map.new(kept_staged),
        media: Map.new(kept_media),
        capabilities: Map.new(kept_caps),
        presentation_reservations: Map.new(kept_res),
        presentation_reserved_bytes:
          max(0, state.presentation_reserved_bytes - cap_bytes - res_bytes),
        total_bytes: max(0, state.total_bytes - staged_bytes - media_bytes)
    }
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp drop_monitor(monitors, nil), do: monitors
  defp drop_monitor(monitors, %{ref: ref}), do: Map.delete(monitors, ref)
end
