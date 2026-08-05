defmodule StrangertalksNew.ConversationLifecycle.ConversationServer do
  @moduledoc """
  Single-node V1 process for authorized, temporary, in-memory message delivery.

  Pending content and idempotency metadata are lost if this process or the BEAM instance dies.
  Raw live-message content is never persisted by this module.
  """

  use GenServer, restart: :transient, spawn_opt: [fullsweep_after: 10]

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Repo

  require Logger

  @recovery_window_ms 60_000
  @message_expiry_ms 120_000
  @retry_interval_ms 5_000
  @completed_metadata_ttl_ms 600_000
  @max_buffer_bytes 262_144
  @max_buffer_messages 50
  @max_message_bytes 16_384
  @typing_expiry_ms 5_000

  def child_spec(%{conversation_id: conversation_id} = args) do
    %{
      id: {__MODULE__, conversation_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :transient
    }
  end

  def start_link(%{conversation_id: conversation_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(conversation_id))
  end

  def ensure_started(conversation_id) when is_binary(conversation_id) do
    case lookup(conversation_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_started} ->
        case DynamicSupervisor.start_child(
               StrangertalksNew.ConversationDynamicSupervisor,
               {__MODULE__, %{conversation_id: conversation_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, :already_present} -> lookup(conversation_id)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def lookup(conversation_id) do
    case Registry.lookup(
           StrangertalksNew.DistributedRegistry,
           "conversation:#{conversation_id}"
         ) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_started}
    end
  end

  def register_channel(conversation_id, participant_id, channel_pid) do
    safe_call(conversation_id, {:register_channel, participant_id, channel_pid})
  end

  def unregister_channel(conversation_id, participant_id, channel_pid) do
    safe_call(conversation_id, {:unregister_channel, participant_id, channel_pid})
  end

  def append_message(conversation_id, sender_id, message_id, content) do
    safe_call(conversation_id, {:append_message, sender_id, message_id, content})
  end

  def acknowledge_message(conversation_id, participant_id, message_id) do
    safe_call(conversation_id, {:acknowledge_message, participant_id, message_id})
  end

  def start_typing(conversation_id, participant_id),
    do: safe_call(conversation_id, {:typing, :start, participant_id})

  def stop_typing(conversation_id, participant_id),
    do: safe_call(conversation_id, {:typing, :stop, participant_id})

  def complete_conversation(conversation_id, participant_id) do
    case safe_call(conversation_id, {:complete_conversation, participant_id}) do
      {:error, :conversation_unavailable} ->
        completed_conversation_result(conversation_id, participant_id)

      result ->
        result
    end
  end

  def trigger_safety_terminate(conversation_id) do
    with {:ok, pid} <- lookup(conversation_id) do
      GenServer.cast(pid, :safety_intervention)
      :ok
    else
      {:error, :not_started} -> {:error, :conversation_unavailable}
    end
  end

  def inspect_state(conversation_id), do: safe_call(conversation_id, :inspect_state)

  @impl true
  def init(%{conversation_id: conversation_id}) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:stop, :unknown_conversation}

      conversation ->
        participant_channels = %{
          conversation.participant_a_id => MapSet.new(),
          conversation.participant_b_id => MapSet.new()
        }

        {:ok,
         %{
           conversation: conversation,
           participant_channels: participant_channels,
           monitor_refs: %{},
           recovery_timers: %{},
           typing_timers: %{},
           pending: %{},
           completed: %{},
           pending_count: 0,
           pending_bytes: 0,
           next_sequence: 1,
           lifecycle_status: :ACTIVE,
           terminal_intent: nil
         }}
    end
  end

  @impl true
  def handle_call({:register_channel, participant_id, channel_pid}, _from, state) do
    state = prune_completed(state)

    if member?(state, participant_id) and active_conversation?(state) do
      was_connected = connected?(state, participant_id)
      state = add_channel(state, participant_id, channel_pid)
      state = cancel_recovery_timer(state, participant_id)
      state = send_presence_snapshot(state, participant_id, channel_pid)

      state =
        if was_connected,
          do: state,
          else:
            notify_other(state, participant_id, {:conversation_presence, %{status: "connected"}})

      state = ensure_absent_participant_timers(state)

      case maybe_activate_conversation(state) do
        {:ok, state} ->
          state = replay_pending(state, participant_id, channel_pid)
          {:reply, :ok, state}

        {:error, _changeset} ->
          {:reply, {:error, :conversation_status_transition_failed}, state}
      end
    else
      {:reply, {:error, :unauthorized_or_inactive_conversation}, state}
    end
  end

  def handle_call({:unregister_channel, participant_id, channel_pid}, _from, state) do
    if member?(state, participant_id) do
      state = remove_channel(state, participant_id, channel_pid)

      state =
        if connected?(state, participant_id),
          do: state,
          else: participant_disconnected(state, participant_id)

      {:reply, :ok, maybe_start_recovery_timer(state, participant_id)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:append_message, sender_id, message_id, content}, _from, state) do
    state = prune_completed(state)

    with false <- terminating?(state),
         true <- member?(state, sender_id),
         true <- active_conversation?(state),
         {:ok, _uuid} <- Ecto.UUID.cast(message_id),
         true <- is_binary(content),
         {:ok, result, state} <- accept_or_replay_message(state, sender_id, message_id, content) do
      {:reply, {:ok, result}, state}
    else
      true -> {:reply, {:error, :conversation_terminating}, state}
      false -> {:reply, {:error, :unauthorized_or_inactive_conversation}, state}
      :error -> {:reply, {:error, :invalid_message_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acknowledge_message, participant_id, message_id}, _from, state) do
    state = prune_completed(state)

    if terminating?(state) do
      {:reply, {:error, :conversation_terminating}, state}
    else
      acknowledge_pending_message(state, participant_id, message_id)
    end
  end

  def handle_call(:inspect_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:complete_conversation, participant_id}, _from, state) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      terminating?(state) ->
        {:reply, terminal_completion_result(state), state}

      active_conversation?(state) ->
        state =
          prepare_terminal_transition(
            state,
            :ENDED,
            "participant_completed",
            "PARTICIPANT_COMPLETED",
            %{
              conversation_completed: true,
              ending_type: :NATURAL_END,
              ending_initiator: participant_id
            },
            %{status: "ended", reason: "participant_completed"}
          )

        case persist_terminal_intent(state) do
          {:ok, state} -> {:stop, :normal, {:ok, %{status: "ended"}}, state}
          {:error, state} -> {:reply, {:ok, %{status: "ending"}}, state}
        end

      true ->
        {:reply, {:error, :conversation_inactive}, state}
    end
  end

  def handle_call({:typing, action, participant_id}, _from, state) do
    if member?(state, participant_id) and active_conversation?(state) do
      case action do
        :start ->
          state = schedule_typing_expiry(state, participant_id)
          notify_other(state, participant_id, {:typing_status, %{typing: true}})
          {:reply, :ok, state}

        :stop ->
          state = clear_typing(state, participant_id, true)
          {:reply, :ok, state}
      end
    else
      {:reply, {:error, :unauthorized_or_inactive_conversation}, state}
    end
  end

  defp acknowledge_pending_message(state, participant_id, message_id) do
    case Map.get(state.pending, message_id) do
      %{sender_id: ^participant_id} ->
        {:reply, {:error, :sender_cannot_acknowledge}, state}

      %{recipient_id: ^participant_id} = message ->
        state = finalize_message(state, message, :delivered, nil)
        {:reply, {:ok, %{message_id: message_id, status: "delivered"}}, state}

      nil ->
        duplicate_ack_result(state, participant_id, message_id)

      _message ->
        {:reply, {:error, :not_message_recipient}, state}
    end
  end

  @impl true
  def handle_cast(:safety_intervention, state) do
    begin_terminal_transition(state, :ENDED, "safety_terminated", "SAFETY_TERMINATED")
  end

  @impl true
  def handle_info({:retry_message, message_id, retry_token}, state) do
    case Map.get(state.pending, message_id) do
      %{retry_token: ^retry_token} = message ->
        message = %{message | retry_ref: nil, retry_token: nil}
        state = put_in(state.pending[message_id], message)

        if connected?(state, message.recipient_id) do
          deliver_to_participant(state, message.recipient_id, message)
          {:noreply, schedule_retry(state, message_id)}
        else
          {:noreply, state}
        end

      _missing_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info({:expire_message, message_id}, state) do
    case Map.get(state.pending, message_id) do
      nil -> {:noreply, prune_completed(state)}
      message -> {:noreply, finalize_message(state, message, :expired, "delivery_expired")}
    end
  end

  def handle_info({:prune_completed, message_id, completed_at}, state) do
    state =
      case Map.get(state.completed, message_id) do
        %{completed_at: ^completed_at} -> update_in(state.completed, &Map.delete(&1, message_id))
        _metadata -> state
      end

    {:noreply, prune_completed(state)}
  end

  def handle_info({:recovery_grace_expired, participant_id, timer_token}, state) do
    case Map.get(state.recovery_timers, participant_id) do
      %{token: ^timer_token} ->
        notify_other(state, participant_id, {:conversation_presence, %{status: "disconnected"}})

        begin_terminal_transition(
          state,
          :ABANDONED,
          "conversation_abandoned",
          "ABANDONED"
        )

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitor_refs, ref) do
      {nil, _monitor_refs} ->
        {:noreply, state}

      {{^pid, participant_id}, monitor_refs} ->
        state = %{state | monitor_refs: monitor_refs}
        state = remove_channel_without_demonitor(state, participant_id, pid)

        state =
          if connected?(state, participant_id),
            do: state,
            else: participant_disconnected(state, participant_id)

        {:noreply, maybe_start_recovery_timer(state, participant_id)}
    end
  end

  def handle_info({:retry_terminal_persistence, retry_token}, state) do
    case state.terminal_intent do
      %{retry_token: ^retry_token} -> attempt_terminal_persistence(clear_terminal_retry(state))
      _missing_or_stale -> {:noreply, state}
    end
  end

  def handle_info({:typing_expired, participant_id, token}, state) do
    case Map.get(state.typing_timers, participant_id) do
      %{token: ^token} -> {:noreply, clear_typing(state, participant_id, true)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp accept_or_replay_message(state, sender_id, message_id, content) do
    content_hash = :crypto.hash(:sha256, content)

    cond do
      pending = state.pending[message_id] ->
        idempotent_result(pending, sender_id, content_hash, state)

      completed = state.completed[message_id] ->
        completed_result(completed, sender_id, content_hash, state)

      byte_size(content) > @max_message_bytes ->
        {:error, :message_too_large}

      state.pending_count >= @max_buffer_messages ->
        {:error, :buffer_overflow_imminent}

      state.pending_bytes + byte_size(content) > @max_buffer_bytes ->
        {:error, :buffer_overflow_imminent}

      true ->
        recipient_id = other_participant(state, sender_id)
        sequence = state.next_sequence
        sent_at = DateTime.utc_now()
        expiry_ref = Process.send_after(self(), {:expire_message, message_id}, @message_expiry_ms)

        message = %{
          message_id: message_id,
          sender_id: sender_id,
          recipient_id: recipient_id,
          content: content,
          content_hash: content_hash,
          sequence: sequence,
          sent_at: sent_at,
          expiry_ref: expiry_ref,
          retry_ref: nil,
          retry_token: nil
        }

        state = %{
          state
          | pending: Map.put(state.pending, message_id, message),
            pending_count: state.pending_count + 1,
            pending_bytes: state.pending_bytes + byte_size(content),
            next_sequence: sequence + 1
        }

        notify_status(state, sender_id, message_id, "sent_to_server", nil)

        state =
          if connected?(state, recipient_id) do
            deliver_to_participant(state, recipient_id, message)
            schedule_retry(state, message_id)
          else
            state
          end

        {:ok, %{message_id: message_id, sequence: sequence, status: "sent_to_server"}, state}
    end
  end

  defp idempotent_result(message, sender_id, content_hash, state) do
    if message.sender_id == sender_id and message.content_hash == content_hash do
      {:ok,
       %{message_id: message.message_id, sequence: message.sequence, status: "sent_to_server"},
       state}
    else
      {:error, :message_id_conflict}
    end
  end

  defp completed_result(metadata, sender_id, content_hash, state) do
    if metadata.sender_id == sender_id and metadata.content_hash == content_hash do
      {:ok,
       %{
         message_id: metadata.message_id,
         sequence: metadata.sequence,
         status: Atom.to_string(metadata.final_state)
       }, state}
    else
      {:error, :message_id_conflict}
    end
  end

  defp duplicate_ack_result(state, participant_id, message_id) do
    case Map.get(state.completed, message_id) do
      %{sender_id: sender_id, final_state: :delivered}
      when sender_id != participant_id and
             participant_id in [
               state.conversation.participant_a_id,
               state.conversation.participant_b_id
             ] ->
        {:reply, {:ok, %{message_id: message_id, status: "delivered"}}, state}

      %{sender_id: ^participant_id} ->
        {:reply, {:error, :sender_cannot_acknowledge}, state}

      _metadata ->
        {:reply, {:error, :unknown_message}, state}
    end
  end

  defp finalize_message(state, message, final_state, reason) do
    cancel_timer(message.expiry_ref)
    cancel_timer(message.retry_ref)
    completed_at = System.monotonic_time(:millisecond)

    metadata = %{
      message_id: message.message_id,
      sender_id: message.sender_id,
      content_hash: message.content_hash,
      sequence: message.sequence,
      final_state: final_state,
      completed_at: completed_at
    }

    Process.send_after(
      self(),
      {:prune_completed, message.message_id, completed_at},
      @completed_metadata_ttl_ms
    )

    notify_status(
      state,
      message.sender_id,
      message.message_id,
      Atom.to_string(final_state),
      reason
    )

    %{
      state
      | pending: Map.delete(state.pending, message.message_id),
        completed: Map.put(state.completed, message.message_id, metadata),
        pending_count: state.pending_count - 1,
        pending_bytes: state.pending_bytes - byte_size(message.content)
    }
  end

  defp fail_all_pending(state, reason) do
    Enum.reduce(Map.values(state.pending), state, fn message, acc ->
      finalize_message(acc, message, :failed, reason)
    end)
  end

  defp begin_terminal_transition(state, target_status, failure_reason, event_reason) do
    state =
      prepare_terminal_transition(state, target_status, failure_reason, event_reason, %{}, nil)

    case persist_terminal_intent(state) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:noreply, state}
    end
  end

  defp prepare_terminal_transition(
         state,
         target_status,
         failure_reason,
         event_reason,
         persistence_attrs,
         client_payload
       ) do
    ended_at = DateTime.utc_now()

    state
    |> fail_all_pending(failure_reason)
    |> Map.put(:lifecycle_status, :TERMINATING)
    |> Map.put(:terminal_intent, %{
      target_status: target_status,
      ended_at: ended_at,
      termination_reason: event_reason,
      persistence_attrs: persistence_attrs,
      client_payload: client_payload,
      retry_ref: nil,
      retry_token: nil
    })
  end

  defp attempt_terminal_persistence(state) do
    case persist_terminal_intent(state) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:noreply, state}
    end
  end

  defp persist_terminal_intent(state) do
    intent = state.terminal_intent

    case persist_conversation_status(
           state.conversation,
           intent.target_status,
           intent.ended_at,
           intent.persistence_attrs
         ) do
      {:ok, conversation} ->
        notify_terminal_clients(state, intent.client_payload)

        dispatch_bus_payload("conversation.ended", %{
          "conversation_id" => conversation.conversation_id,
          "reason" => intent.termination_reason
        })

        {:ok,
         %{
           state
           | conversation: conversation,
             lifecycle_status: intent.target_status,
             terminal_intent: nil
         }}

      {:error, reason} ->
        Logger.error("Conversation terminal persistence failed",
          conversation_id: state.conversation.conversation_id,
          target_status: intent.target_status,
          database_error: inspect(reason)
        )

        {:error, schedule_terminal_persistence_retry(state)}
    end
  end

  defp schedule_terminal_persistence_retry(state) do
    retry_token = make_ref()

    retry_ref =
      Process.send_after(
        self(),
        {:retry_terminal_persistence, retry_token},
        @retry_interval_ms
      )

    terminal_intent = %{
      state.terminal_intent
      | retry_ref: retry_ref,
        retry_token: retry_token
    }

    %{state | terminal_intent: terminal_intent}
  end

  defp clear_terminal_retry(state) do
    terminal_intent = %{state.terminal_intent | retry_ref: nil, retry_token: nil}
    %{state | terminal_intent: terminal_intent}
  end

  defp schedule_retry(state, message_id) do
    retry_token = make_ref()

    retry_ref =
      Process.send_after(
        self(),
        {:retry_message, message_id, retry_token},
        @retry_interval_ms
      )

    state
    |> put_in([:pending, message_id, :retry_ref], retry_ref)
    |> put_in([:pending, message_id, :retry_token], retry_token)
  end

  defp replay_pending(state, participant_id, channel_pid) do
    state.pending
    |> Map.values()
    |> Enum.filter(&(&1.recipient_id == participant_id))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.reduce(state, fn message, acc ->
      send_delivery(channel_pid, message)

      if message.retry_ref do
        acc
      else
        schedule_retry(acc, message.message_id)
      end
    end)
  end

  defp deliver_to_participant(state, participant_id, message) do
    state.participant_channels
    |> Map.fetch!(participant_id)
    |> Enum.each(&send_delivery(&1, message))
  end

  defp send_delivery(channel_pid, message) do
    send(channel_pid, {
      :conversation_message,
      %{
        message_id: message.message_id,
        sequence: message.sequence,
        content: message.content,
        sent_at: DateTime.to_iso8601(message.sent_at)
      }
    })
  end

  defp notify_status(state, participant_id, message_id, status, reason) do
    payload = %{message_id: message_id, status: status}
    payload = if reason, do: Map.put(payload, :reason, reason), else: payload

    state.participant_channels
    |> Map.fetch!(participant_id)
    |> Enum.each(&send(&1, {:conversation_message_status, payload}))
  end

  defp add_channel(state, participant_id, channel_pid) do
    channels = Map.fetch!(state.participant_channels, participant_id)

    if MapSet.member?(channels, channel_pid) do
      state
    else
      ref = Process.monitor(channel_pid)

      state
      |> put_in([:participant_channels, participant_id], MapSet.put(channels, channel_pid))
      |> put_in([:monitor_refs, ref], {channel_pid, participant_id})
    end
  end

  defp remove_channel(state, participant_id, channel_pid) do
    {matching_refs, monitor_refs} =
      Enum.split_with(state.monitor_refs, fn {_ref, value} ->
        value == {channel_pid, participant_id}
      end)

    Enum.each(matching_refs, fn {ref, _value} -> Process.demonitor(ref, [:flush]) end)

    state = %{state | monitor_refs: Map.new(monitor_refs)}
    remove_channel_without_demonitor(state, participant_id, channel_pid)
  end

  defp remove_channel_without_demonitor(state, participant_id, channel_pid) do
    case Map.fetch(state.participant_channels, participant_id) do
      {:ok, channels} ->
        put_in(state.participant_channels[participant_id], MapSet.delete(channels, channel_pid))

      :error ->
        state
    end
  end

  defp ensure_absent_participant_timers(state) do
    Enum.reduce(Map.keys(state.participant_channels), state, fn participant_id, acc ->
      maybe_start_recovery_timer(acc, participant_id)
    end)
  end

  defp maybe_start_recovery_timer(state, participant_id) do
    cond do
      connected?(state, participant_id) ->
        state

      Map.has_key?(state.recovery_timers, participant_id) ->
        state

      true ->
        timer_token = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:recovery_grace_expired, participant_id, timer_token},
            @recovery_window_ms
          )

        put_in(state.recovery_timers[participant_id], %{token: timer_token, timer_ref: timer_ref})
    end
  end

  defp cancel_recovery_timer(state, participant_id) do
    case Map.pop(state.recovery_timers, participant_id) do
      {nil, _timers} ->
        state

      {%{timer_ref: timer_ref}, timers} ->
        cancel_timer(timer_ref)
        %{state | recovery_timers: timers}
    end
  end

  defp participant_disconnected(state, participant_id) do
    state
    |> clear_typing(participant_id, true)
    |> notify_other(participant_id, {:conversation_presence, %{status: "reconnecting"}})
  end

  defp send_presence_snapshot(state, participant_id, channel_pid) do
    other_id = other_participant(state, participant_id)

    status =
      cond do
        connected?(state, other_id) -> "connected"
        Map.has_key?(state.recovery_timers, other_id) -> "reconnecting"
        true -> "disconnected"
      end

    send(channel_pid, {:conversation_presence, %{status: status}})
    state
  end

  defp notify_other(state, participant_id, message) do
    state.participant_channels
    |> Map.fetch!(other_participant(state, participant_id))
    |> Enum.each(&send(&1, message))

    state
  end

  defp schedule_typing_expiry(state, participant_id) do
    state = clear_typing(state, participant_id, false)
    token = make_ref()

    timer_ref =
      Process.send_after(self(), {:typing_expired, participant_id, token}, @typing_expiry_ms)

    put_in(state.typing_timers[participant_id], %{token: token, timer_ref: timer_ref})
  end

  defp clear_typing(state, participant_id, notify?) do
    case Map.pop(state.typing_timers, participant_id) do
      {nil, _} ->
        state

      {%{timer_ref: timer_ref}, timers} ->
        cancel_timer(timer_ref)
        state = %{state | typing_timers: timers}

        if notify?,
          do: notify_other(state, participant_id, {:typing_status, %{typing: false}}),
          else: state
    end
  end

  defp maybe_activate_conversation(state) do
    if Enum.all?(state.participant_channels, fn {_participant_id, channels} ->
         not Enum.empty?(channels)
       end) and state.conversation.conversation_status == :PENDING do
      case persist_conversation_status(state.conversation, :ACTIVE, nil) do
        {:ok, conversation} -> {:ok, %{state | conversation: conversation}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, state}
    end
  end

  defp persist_conversation_status(conversation, status, ended_at, extra_attrs \\ %{}) do
    attrs = %{conversation_status: status}
    attrs = if ended_at, do: Map.put(attrs, :ended_at, ended_at), else: attrs
    attrs = Map.merge(attrs, extra_attrs)

    try do
      conversation
      |> Conversation.changeset(attrs)
      |> Repo.update()
    rescue
      exception -> {:error, exception}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp prune_completed(state) do
    cutoff = System.monotonic_time(:millisecond) - @completed_metadata_ttl_ms

    completed =
      Map.reject(state.completed, fn {_id, metadata} -> metadata.completed_at <= cutoff end)

    %{state | completed: completed}
  end

  defp active_conversation?(state) do
    state.lifecycle_status == :ACTIVE and
      state.conversation.conversation_status in [:PENDING, :ACTIVE]
  end

  defp terminating?(state), do: state.lifecycle_status == :TERMINATING

  defp terminal_completion_result(%{
         terminal_intent: %{termination_reason: "PARTICIPANT_COMPLETED"}
       }),
       do: {:ok, %{status: "ending"}}

  defp terminal_completion_result(_state), do: {:error, :conversation_terminating}

  defp completed_conversation_result(conversation_id, participant_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{conversation_status: :ENDED, conversation_completed: true} = conversation ->
        if participant_id in [conversation.participant_a_id, conversation.participant_b_id] do
          {:ok, %{status: "ended"}}
        else
          {:error, :not_conversation_member}
        end

      _conversation ->
        {:error, :conversation_unavailable}
    end
  end

  defp notify_terminal_clients(_state, nil), do: :ok

  defp notify_terminal_clients(state, payload) do
    state.participant_channels
    |> Map.values()
    |> Enum.flat_map(&MapSet.to_list/1)
    |> Enum.each(&send(&1, {:conversation_completed, payload}))
  end

  defp connected?(state, participant_id) do
    case Map.fetch(state.participant_channels, participant_id) do
      {:ok, channels} -> not Enum.empty?(channels)
      :error -> false
    end
  end

  defp member?(state, participant_id),
    do: participant_id in Map.keys(state.participant_channels)

  defp other_participant(state, sender_id) do
    Enum.find(Map.keys(state.participant_channels), &(&1 != sender_id))
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref, async: true, info: false)

  defp safe_call(conversation_id, message) do
    with {:ok, pid} <- lookup(conversation_id) do
      try do
        GenServer.call(pid, message)
      catch
        :exit, _reason -> {:error, :conversation_unavailable}
      end
    else
      {:error, :not_started} -> {:error, :conversation_unavailable}
    end
  end

  defp dispatch_bus_payload(event_name, data) do
    packet = %{
      "event" => event_name,
      "trace_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => data
    }

    Phoenix.PubSub.broadcast(
      StrangertalksNew.PubSub,
      "strangertalks:matchmaking",
      {:conversation_event, String.to_atom(event_name), packet}
    )
  end

  defp via_tuple(conversation_id) do
    {:via, Registry, {StrangertalksNew.DistributedRegistry, "conversation:#{conversation_id}"}}
  end
end
