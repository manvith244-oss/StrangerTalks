defmodule StrangertalksNew.ConversationLifecycle.ConversationServer do
  @moduledoc """
  Single-node V1 process for authorized, temporary, in-memory message delivery.

  Pending content and idempotency metadata are lost if this process or the BEAM instance dies.
  Raw live-message content is never persisted by this module.
  """

  use GenServer, restart: :transient, spawn_opt: [fullsweep_after: 10]

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.VoiceNoteStore
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore
  alias StrangertalksNew.AvatarCatalog
  alias StrangertalksNew.ExpressiveMediaCatalog
  alias StrangertalksNew.IcebreakerCatalog
  alias StrangertalksNew.C11Policy
  alias StrangertalksNew.Repo

  require Logger

  @recovery_window_ms 60_000
  @message_expiry_ms 120_000
  @retry_interval_ms 5_000
  @completed_metadata_ttl_ms 600_000
  @max_buffer_bytes 262_144
  @max_buffer_messages 50
  @max_message_bytes 16_384
  @max_replay_messages 50
  @max_replay_bytes 262_144
  @unsent_message_text "Message unsent"
  @unsent_reply_text "Unsent message"
  @unavailable_reply_text "Message unavailable"
  @typing_expiry_ms 5_000
  @mailbox_soft_limit 100
  @mailbox_hard_limit 500
  @release_terminal_statuses [:ENDED, :ABANDONED, :FAILED, :COMPLETED]

  def max_message_bytes, do: @max_message_bytes

  @doc false
  def release_terminal_status?(status), do: status in @release_terminal_statuses

  @impl true
  def format_status(_status), do: %{state: :redacted, message: :redacted}

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
    admitted_call(
      conversation_id,
      {:register_channel, participant_id, channel_pid},
      @mailbox_hard_limit,
      :conversation_busy
    )
  end

  def sync_and_register_channel(
        conversation_id,
        participant_id,
        channel_pid,
        client_epoch_id,
        last_seen_sequence
      ) do
    admitted_call(
      conversation_id,
      {:sync_and_register_channel, participant_id, channel_pid, client_epoch_id,
       last_seen_sequence},
      @mailbox_hard_limit,
      :conversation_busy
    )
  end

  def unregister_channel(conversation_id, participant_id, channel_pid) do
    safe_call(conversation_id, {:unregister_channel, participant_id, channel_pid})
  end

  def update_session_visibility(conversation_id, participant_id, channel_pid, visibility)
      when visibility in [:visible, :hidden] do
    admitted_call(
      conversation_id,
      {:update_session_visibility, participant_id, channel_pid, visibility},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def get_participant_presence(conversation_id, participant_id) do
    safe_call(conversation_id, {:get_participant_presence, participant_id})
  end

  def append_message(
        conversation_id,
        sender_id,
        message_id,
        content,
        reply_to_client_message_id \\ nil
      ) do
    admitted_call(
      conversation_id,
      {:append_message, sender_id, message_id, content, reply_to_client_message_id},
      @mailbox_hard_limit,
      :message_buffer_full
    )
  end

  def append_expressive_message(conversation_id, sender_id, message_id, expressive_id) do
    admitted_call(
      conversation_id,
      {:append_expressive_message, sender_id, message_id, expressive_id},
      @mailbox_hard_limit,
      :message_buffer_full
    )
  end

  def edit_message(
        conversation_id,
        participant_id,
        target_client_message_id,
        expected_content_revision,
        content
      ) do
    admitted_call(
      conversation_id,
      {:edit_message, participant_id, target_client_message_id, expected_content_revision,
       content},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def unsend_message(
        conversation_id,
        participant_id,
        target_client_message_id,
        expected_content_revision
      ) do
    admitted_call(
      conversation_id,
      {:unsend_message, participant_id, target_client_message_id, expected_content_revision},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def capture_report_evidence(conversation_id, reporter_id, target_client_message_id) do
    admitted_call(
      conversation_id,
      {:capture_report_evidence, reporter_id, target_client_message_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def lookup_reply_target(conversation_id, participant_id, reply_to_client_message_id) do
    admitted_call(
      conversation_id,
      {:lookup_reply_target, participant_id, reply_to_client_message_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def mutate_reaction(
        conversation_id,
        participant_id,
        target_client_message_id,
        desired_reaction,
        expected_reaction_revision
      ) do
    admitted_call(
      conversation_id,
      {:mutate_reaction, participant_id, target_client_message_id, desired_reaction,
       expected_reaction_revision},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def mutate_pin(
        conversation_id,
        participant_id,
        target_client_message_id,
        pinned,
        expected_revision
      )
      when is_binary(conversation_id) and is_binary(participant_id) and
             is_binary(target_client_message_id) and is_boolean(pinned) and
             is_integer(expected_revision) do
    admitted_call(
      conversation_id,
      {:mutate_pin, participant_id, target_client_message_id, pinned, expected_revision},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def open_composer_grant(conversation_id, participant_id, grant_params)
      when is_binary(conversation_id) and is_binary(participant_id) and is_map(grant_params) do
    admitted_call(
      conversation_id,
      {:open_composer_grant, participant_id, grant_params},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def save_reflection_with_source(conversation_id, participant_id, params)
      when is_binary(conversation_id) and is_binary(participant_id) and is_map(params) do
    admitted_call(
      conversation_id,
      {:save_reflection_with_source, participant_id, params},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def acknowledge_message(conversation_id, participant_id, message_id) do
    safe_call(conversation_id, {:acknowledge_message, participant_id, message_id})
  end

  def report_delivery_progress(
        conversation_id,
        participant_id,
        channel_pid,
        epoch_id,
        highest_contiguous_sequence
      ) do
    admitted_call(
      conversation_id,
      {:report_delivery_progress, participant_id, channel_pid, epoch_id,
       highest_contiguous_sequence},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def report_content_revision_applied(
        conversation_id,
        participant_id,
        channel_pid,
        epoch_id,
        target_client_message_id,
        content_revision
      ) do
    admitted_call(
      conversation_id,
      {:report_content_revision_applied, participant_id, channel_pid, epoch_id,
       target_client_message_id, content_revision},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def get_messages_after(conversation_id, participant_id, last_seen_sequence)
      when is_binary(conversation_id) and is_binary(participant_id) and
             is_integer(last_seen_sequence) do
    admitted_call(
      conversation_id,
      {:get_messages_after, participant_id, last_seen_sequence},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def append_voice_note(conversation_id, sender_id, attrs, binary) do
    admitted_call(
      conversation_id,
      {:append_voice_note, sender_id, attrs, binary},
      @mailbox_hard_limit,
      :conversation_busy
    )
  end

  def admit_voice_note(conversation_id) when is_binary(conversation_id) do
    with {:ok, pid} <- ensure_started(conversation_id) do
      mailbox_admission(pid, @mailbox_hard_limit, :conversation_busy)
    end
  end

  def acknowledge_voice_note(conversation_id, participant_id, voice_note_id) do
    safe_call(conversation_id, {:acknowledge_voice_note, participant_id, voice_note_id})
  end

  def append_view_once_photo(
        conversation_id,
        sender_id,
        client_message_id,
        staging_token,
        presentation_limit \\ 1
      ) do
    admitted_call(
      conversation_id,
      {:append_view_once_photo, sender_id, client_message_id, staging_token, presentation_limit},
      @mailbox_hard_limit,
      :conversation_busy
    )
  end

  def append_view_once_video(
        conversation_id,
        sender_id,
        client_message_id,
        staging_token,
        presentation_limit \\ 1
      ) do
    admitted_call(
      conversation_id,
      {:append_view_once_video, sender_id, client_message_id, staging_token, presentation_limit},
      @mailbox_hard_limit,
      :conversation_busy
    )
  end

  def open_view_once_photo(
        conversation_id,
        participant_id,
        target_client_message_id,
        attempt_id \\ nil
      ) do
    admitted_call(
      conversation_id,
      {:open_view_once_photo, participant_id, target_client_message_id, attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def open_view_once_video(
        conversation_id,
        participant_id,
        target_client_message_id,
        attempt_id \\ nil
      ) do
    admitted_call(
      conversation_id,
      {:open_view_once_photo, participant_id, target_client_message_id, attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def start_typing(conversation_id, participant_id),
    do:
      admitted_call(
        conversation_id,
        {:typing, :start, participant_id},
        @mailbox_soft_limit,
        :conversation_busy
      )

  def stop_typing(conversation_id, participant_id),
    do:
      admitted_call(
        conversation_id,
        {:typing, :stop, participant_id},
        @mailbox_soft_limit,
        :conversation_busy
      )

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

  def get_avatar_presentation(conversation_id, participant_id) do
    safe_call(conversation_id, {:get_avatar_presentation, participant_id})
  end

  # Live Communication Suite (Feature 1Q)
  def initiate_call(conversation_id, participant_id, channel_pid, session_id, call_type) do
    admitted_call(
      conversation_id,
      {:initiate_call, participant_id, channel_pid, session_id, call_type},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def accept_call(conversation_id, participant_id, channel_pid, session_id, call_attempt_id) do
    C11Policy.with_account_lock(fn ->
      c11_opts = Application.get_env(:strangertalks_new, :c11_policy, [])
      {active_reservations, terminal_exposures} = C11Policy.derive_node_reservations()

      c11_state =
        C11Policy.init_state(c11_opts)
        |> Map.put(:active_reservations, active_reservations)
        |> Map.put(:terminal_exposures, terminal_exposures)

      case C11Policy.admit_and_reserve(c11_state, conversation_id, call_attempt_id) do
        {:ok, provider, updated_c11_state} ->
          winning_reservation = Map.get(updated_c11_state.active_reservations, call_attempt_id)

          admitted_call(
            conversation_id,
            {:commit_call_admission, participant_id, channel_pid, session_id, call_attempt_id,
             provider, winning_reservation},
            @mailbox_soft_limit,
            :conversation_busy
          )

        {:error, reason, _c11_state} ->
          _ =
            admitted_call(
              conversation_id,
              {:reject_call_admission, participant_id, call_attempt_id, reason},
              @mailbox_soft_limit,
              :conversation_busy
            )

          {:error, reason}
      end
    end)
  end

  def extend_call_credentials(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id
      ) do
    C11Policy.with_account_lock(fn ->
      c11_opts = Application.get_env(:strangertalks_new, :c11_policy, [])
      {active_reservations, terminal_exposures} = C11Policy.derive_node_reservations()

      c11_state =
        C11Policy.init_state(c11_opts)
        |> Map.put(:active_reservations, active_reservations)
        |> Map.put(:terminal_exposures, terminal_exposures)

      case C11Policy.admit_extension(c11_state, call_attempt_id) do
        {:ok, provider, updated_c11_state} ->
          winning_reservation = Map.get(updated_c11_state.active_reservations, call_attempt_id)

          case admitted_call(
                 conversation_id,
                 {:commit_call_extension, participant_id, channel_pid, session_id,
                  call_attempt_id, winning_reservation},
                 @mailbox_soft_limit,
                 :conversation_busy
               ) do
            {:ok, :ok} ->
              ttl = c11_state.credential_ttl_seconds

              C11Policy.authorize_credentials(
                provider,
                conversation_id,
                participant_id,
                call_attempt_id,
                ttl
              )

            error ->
              error
          end

        {:error, reason, _c11_state} ->
          {:error, reason}
      end
    end)
  end

  def decline_call(conversation_id, participant_id, channel_pid, session_id, call_attempt_id) do
    admitted_call(
      conversation_id,
      {:decline_call, participant_id, channel_pid, session_id, call_attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def cancel_call(conversation_id, participant_id, channel_pid, session_id, call_attempt_id) do
    admitted_call(
      conversation_id,
      {:cancel_call, participant_id, channel_pid, session_id, call_attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def end_call(conversation_id, participant_id, channel_pid, session_id, call_attempt_id) do
    admitted_call(
      conversation_id,
      {:end_call, participant_id, channel_pid, session_id, call_attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def set_call_mute(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        is_muted
      ) do
    admitted_call(
      conversation_id,
      {:set_call_mute, participant_id, channel_pid, session_id, call_attempt_id, is_muted},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def set_call_effect(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        effect_active
      ) do
    admitted_call(
      conversation_id,
      {:set_call_effect, participant_id, channel_pid, session_id, call_attempt_id, effect_active},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def signal_call(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        generation,
        signal_payload
      ) do
    admitted_call(
      conversation_id,
      {:signal_call, participant_id, channel_pid, session_id, call_attempt_id, generation,
       signal_payload},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def request_call_media(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        request_type,
        proposal
      ) do
    if request_type in [:video_upgrade, "video_upgrade"] do
      admitted_call(
        conversation_id,
        {:request_call_media, participant_id, channel_pid, session_id, call_attempt_id,
         request_type, proposal},
        @mailbox_soft_limit,
        :conversation_busy
      )
    else
      {:error, :unsupported_media_type}
    end
  end

  def respond_call_media(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        media_request_id,
        decision
      ) do
    admitted_call(
      conversation_id,
      {:respond_call_media, participant_id, channel_pid, session_id, call_attempt_id,
       media_request_id, decision},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def request_call_credentials(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id
      ) do
    admitted_call(
      conversation_id,
      {:request_call_credentials, participant_id, channel_pid, session_id, call_attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def return_to_voice(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id
      ) do
    admitted_call(
      conversation_id,
      {:return_to_voice, participant_id, channel_pid, session_id, call_attempt_id},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def send_call_reaction(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        reaction_event_id,
        reaction
      ) do
    admitted_call(
      conversation_id,
      {:send_call_reaction, participant_id, channel_pid, session_id, call_attempt_id,
       reaction_event_id, reaction},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def set_reveal_ready(
        conversation_id,
        participant_id,
        channel_pid,
        session_id,
        call_attempt_id,
        media_request_id,
        ready
      ) do
    admitted_call(
      conversation_id,
      {:set_reveal_ready, participant_id, channel_pid, session_id, call_attempt_id,
       media_request_id, ready},
      @mailbox_soft_limit,
      :conversation_busy
    )
  end

  def get_call_state(conversation_id, participant_id) do
    safe_call(conversation_id, {:get_call_state, participant_id})
  end

  @impl true
  def init(%{conversation_id: conversation_id}) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:stop, :unknown_conversation}

      %Conversation{conversation_status: status}
      when status in [:ENDED, :ABANDONED, :FAILED, :COMPLETED] ->
        {:stop, :terminal_conversation}

      conversation ->
        :ok = VoiceNoteStore.register_owner(conversation_id, self())
        :ok = ViewOnceMediaStore.register_owner(conversation_id, self())

        participant_channels = %{
          conversation.participant_a_id => MapSet.new(),
          conversation.participant_b_id => MapSet.new()
        }

        participant_pins = %{
          conversation.participant_a_id => %{revision: 0, items: []},
          conversation.participant_b_id => %{revision: 0, items: []}
        }

        avatar_map =
          AvatarCatalog.derive_pair(
            conversation_id,
            conversation.participant_a_id,
            conversation.participant_b_id
          )

        epoch_id = Ecto.UUID.generate()

        {:ok,
         %{
           conversation: conversation,
           epoch_id: epoch_id,
           avatar_map: avatar_map,
           icebreaker: initial_icebreaker(conversation_id),
           participant_channels: participant_channels,
           session_visibility: %{},
           channel_sync_floors: %{},
           delivery_progress: %{
             conversation.participant_a_id => 0,
             conversation.participant_b_id => 0
           },
           pins: participant_pins,
           monitor_refs: %{},
           recovery_timers: %{},
           typing_timers: %{},
           pending: %{},
           completed: %{},
           recent_messages: [],
           replay_bytes: 0,
           pending_voice_notes: %{},
           completed_voice_notes: %{},
           pending_count: 0,
           pending_bytes: 0,
           next_sequence: 1,
           lifecycle_status: :ACTIVE,
           terminal_intent: nil,
           call_state: nil,
           terminal_c11_exposure: nil,
           c11_state:
             C11Policy.init_state(Application.get_env(:strangertalks_new, :c11_policy, []))
         }}
    end
  end

  @impl true
  def handle_call({:register_channel, participant_id, channel_pid}, _from, state) do
    state = prune_completed(state)

    if member?(state, participant_id) and recoverable_conversation?(state) do
      prev_status = derive_participant_presence(state, participant_id)
      state = add_channel(state, participant_id, channel_pid)
      new_status = derive_participant_presence(state, participant_id)

      state =
        if new_status != prev_status do
          notify_other(state, participant_id, {:conversation_presence, %{status: new_status}})
        else
          state
        end

      state =
        put_in(state.channel_sync_floors[channel_pid], %{
          epoch_id: state.epoch_id,
          participant_id: participant_id,
          sequence: 0
        })

      state = cancel_recovery_timer(state, participant_id)
      state = send_presence_snapshot(state, participant_id, channel_pid)
      state = ensure_absent_participant_timers(state)

      case maybe_activate_conversation(state) do
        {:ok, state} ->
          state = replay_pending(state, participant_id, channel_pid)
          state = replay_pending_voice_notes(state, participant_id, channel_pid)
          {:reply, :ok, state}

        {:error, _changeset} ->
          {:reply, {:error, :conversation_status_transition_failed}, state}
      end
    else
      {:reply, {:error, conversation_action_error(state, participant_id)}, state}
    end
  end

  def handle_call(
        {:sync_and_register_channel, participant_id, channel_pid, client_epoch_id, last_seen_seq},
        _from,
        state
      ) do
    sync_started_at = System.monotonic_time()
    state = prune_completed(state)

    if member?(state, participant_id) and recoverable_conversation?(state) do
      prev_status = derive_participant_presence(state, participant_id)
      state = add_channel(state, participant_id, channel_pid)
      new_status = derive_participant_presence(state, participant_id)

      state =
        if new_status != prev_status do
          notify_other(state, participant_id, {:conversation_presence, %{status: new_status}})
        else
          state
        end

      state = cancel_recovery_timer(state, participant_id)
      state = send_presence_snapshot(state, participant_id, channel_pid)
      state = ensure_absent_participant_timers(state)

      case maybe_activate_conversation(state) do
        {:ok, state} ->
          sync_payload =
            calculate_sync_payload(
              state,
              participant_id,
              client_epoch_id,
              last_seen_seq,
              sync_started_at
            )

          state =
            put_in(
              state.channel_sync_floors[channel_pid],
              %{
                epoch_id: state.epoch_id,
                participant_id: participant_id,
                sequence: sync_payload.baseline_sequence - 1
              }
            )

          {:reply, {:ok, sync_payload}, state}

        {:error, _changeset} ->
          {:reply, {:error, :conversation_status_transition_failed}, state}
      end
    else
      {:reply, {:error, conversation_action_error(state, participant_id)}, state}
    end
  end

  def handle_call({:unregister_channel, participant_id, channel_pid}, _from, state) do
    if member?(state, participant_id) do
      prev_status = derive_participant_presence(state, participant_id)

      state =
        state
        |> remove_channel(participant_id, channel_pid)
        |> drop_channel_sync_floor(channel_pid)

      new_status = derive_participant_presence(state, participant_id)

      state =
        if new_status != prev_status do
          notify_other(state, participant_id, {:conversation_presence, %{status: new_status}})
        else
          state
        end

      state =
        if not connected?(state, participant_id) do
          participant_disconnected(state, participant_id)
        else
          state
        end

      {:reply, :ok, maybe_start_recovery_timer(state, participant_id)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(
        {:update_session_visibility, participant_id, channel_pid, visibility},
        _from,
        state
      ) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not MapSet.member?(
        Map.get(state.participant_channels, participant_id, MapSet.new()),
        channel_pid
      ) ->
        {:reply, {:error, :invalid_session}, state}

      Map.get(state.session_visibility, channel_pid) == visibility ->
        {:reply, {:ok, :no_op}, state}

      true ->
        prev_status = derive_participant_presence(state, participant_id)
        state = put_in(state.session_visibility[channel_pid], visibility)
        new_status = derive_participant_presence(state, participant_id)

        state =
          if new_status != prev_status do
            notify_other(state, participant_id, {:conversation_presence, %{status: new_status}})
          else
            state
          end

        {:reply, {:ok, :applied}, state}
    end
  end

  def handle_call({:get_participant_presence, participant_id}, _from, state) do
    if member?(state, participant_id) do
      {:reply, {:ok, derive_participant_presence(state, participant_id)}, state}
    else
      {:reply, {:error, :not_conversation_member}, state}
    end
  end

  def handle_call(
        {:report_delivery_progress, participant_id, channel_pid, epoch_id,
         highest_contiguous_sequence},
        _from,
        state
      ) do
    latest_sequence = state.next_sequence - 1
    current_progress = Map.get(state.delivery_progress, participant_id, 0)
    sync_floor = Map.get(state.channel_sync_floors, channel_pid)

    cond do
      not member?(state, participant_id) ->
        emit_delivery_progress(:invalid)
        {:reply, {:error, :not_conversation_member}, state}

      epoch_id != state.epoch_id ->
        emit_delivery_progress(:stale)
        {:reply, {:ok, %{status: "stale", highest_contiguous_sequence: current_progress}}, state}

      not is_integer(highest_contiguous_sequence) or highest_contiguous_sequence < 0 or
          highest_contiguous_sequence > latest_sequence ->
        emit_delivery_progress(:invalid)
        {:reply, {:error, :invalid_sequence}, state}

      highest_contiguous_sequence <= current_progress ->
        emit_delivery_progress(:no_op)
        {:reply, {:ok, %{status: "no_op", highest_contiguous_sequence: current_progress}}, state}

      is_nil(sync_floor) or sync_floor.epoch_id != state.epoch_id or
        sync_floor.participant_id != participant_id or
          highest_contiguous_sequence < sync_floor.sequence ->
        emit_delivery_progress(:invalid)
        {:reply, {:error, :invalid_sequence}, state}

      true ->
        state = apply_delivery_progress(state, participant_id, highest_contiguous_sequence)
        emit_delivery_progress(:applied)

        {:reply,
         {:ok, %{status: "applied", highest_contiguous_sequence: highest_contiguous_sequence}},
         state}
    end
  end

  def handle_call(
        {:report_content_revision_applied, participant_id, channel_pid, epoch_id,
         target_client_message_id, content_revision},
        _from,
        state
      ) do
    sync_floor = Map.get(state.channel_sync_floors, channel_pid)

    cond do
      not member?(state, participant_id) ->
        emit_content_revision_ack(:invalid)
        {:reply, {:error, :not_conversation_member}, state}

      epoch_id != state.epoch_id ->
        emit_content_revision_ack(:stale)
        {:reply, {:ok, %{status: "stale"}}, state}

      is_nil(sync_floor) or sync_floor.epoch_id != state.epoch_id or
          sync_floor.participant_id != participant_id ->
        emit_content_revision_ack(:invalid)
        {:reply, {:error, :invalid_session}, state}

      not valid_message_id?(target_client_message_id) or
          not valid_content_revision?(content_revision) ->
        emit_content_revision_ack(:invalid)
        {:reply, {:error, :invalid_request}, state}

      true ->
        acknowledge_content_revision(
          state,
          participant_id,
          target_client_message_id,
          content_revision
        )
    end
  end

  def handle_call({:append_message, sender_id, message_id, content}, from, state) do
    handle_call({:append_message, sender_id, message_id, content, nil}, from, state)
  end

  def handle_call(
        {:append_message, sender_id, message_id, content, reply_to_client_message_id},
        _from,
        state
      ) do
    operation_started_at = System.monotonic_time()
    state = prune_completed(state)

    with false <- terminating?(state),
         true <- member?(state, sender_id),
         true <- active_conversation?(state),
         {:ok, _uuid} <- Ecto.UUID.cast(message_id),
         true <- is_binary(content) and String.valid?(content),
         {:ok, result, state} <-
           accept_or_replay_message(
             state,
             sender_id,
             message_id,
             content,
             reply_to_client_message_id,
             nil
           ) do
      unless Map.get(result, :duplicate, false) do
        emit_message_accept_duration(operation_started_at, :text, :success)
      end

      {:reply, {:ok, result}, state}
    else
      true ->
        emit_message_accept_duration(operation_started_at, :text, :failure)
        {:reply, {:error, :conversation_terminating}, state}

      false ->
        emit_message_accept_duration(operation_started_at, :text, :failure)
        {:reply, {:error, conversation_action_error(state, sender_id)}, state}

      :error ->
        emit_message_accept_duration(operation_started_at, :text, :failure)
        {:reply, {:error, :invalid_message_id}, state}

      {:error, reason} ->
        emit_message_accept_duration(operation_started_at, :text, :failure)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:append_expressive_message, sender_id, message_id, expressive_id},
        _from,
        state
      ) do
    operation_started_at = System.monotonic_time()
    state = prune_completed(state)

    with false <- terminating?(state),
         true <- member?(state, sender_id),
         true <- active_conversation?(state),
         {:ok, _uuid} <- Ecto.UUID.cast(message_id),
         {:ok, item} <- ExpressiveMediaCatalog.fetch(expressive_id),
         canonical = Map.put(item, :id, expressive_id),
         content = "expressive:" <> expressive_id,
         {:ok, result, state} <-
           accept_or_replay_message(state, sender_id, message_id, content, nil, canonical) do
      unless Map.get(result, :duplicate, false) do
        emit_message_accept_duration(operation_started_at, :expressive, :success)
      end

      {:reply, {:ok, result}, state}
    else
      true -> {:reply, {:error, :conversation_terminating}, state}
      false -> {:reply, {:error, conversation_action_error(state, sender_id)}, state}
      :error -> {:reply, {:error, :invalid_message_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:edit_message, participant_id, target_client_message_id, expected_content_revision,
         proposed_content},
        _from,
        state
      ) do
    state = prune_completed(state)

    cond do
      not member?(state, participant_id) ->
        emit_message_edit(:invalid)
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        emit_message_edit(:unavailable)
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      not valid_content_revision?(expected_content_revision) ->
        emit_message_edit(:invalid)
        {:reply, {:error, :invalid_revision}, state}

      not valid_message_id?(target_client_message_id) ->
        emit_message_edit(:invalid)
        {:reply, {:error, :invalid_message_id}, state}

      true ->
        case normalize_edited_content(proposed_content) do
          {:error, reason} ->
            emit_message_edit(:invalid)
            {:reply, {:error, reason}, state}

          {:ok, content} ->
            apply_message_edit(
              state,
              participant_id,
              target_client_message_id,
              expected_content_revision,
              content
            )
        end
    end
  end

  def handle_call(
        {:unsend_message, participant_id, target_client_message_id, expected_content_revision},
        _from,
        state
      ) do
    state = prune_completed(state)

    cond do
      not member?(state, participant_id) ->
        emit_message_unsend(:invalid)
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        emit_message_unsend(:unavailable)
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      not valid_content_revision?(expected_content_revision) ->
        emit_message_unsend(:invalid)
        {:reply, {:error, :invalid_revision}, state}

      not valid_message_id?(target_client_message_id) ->
        emit_message_unsend(:invalid)
        {:reply, {:error, :invalid_message_id}, state}

      true ->
        apply_message_unsend(
          state,
          participant_id,
          target_client_message_id,
          expected_content_revision
        )
    end
  end

  def handle_call({:open_composer_grant, participant_id, grant_params}, _from, state) do
    handle_open_composer_grant(state, participant_id, grant_params)
  end

  def handle_call({:save_reflection_with_source, participant_id, params}, _from, state) do
    handle_save_reflection_with_source(state, participant_id, params)
  end

  def handle_call(
        {:capture_report_evidence, reporter_id, target_client_message_id},
        _from,
        state
      ) do
    cond do
      not member?(state, reporter_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not recoverable_conversation?(state) ->
        {:reply, {:error, :conversation_inactive}, state}

      not valid_message_id?(target_client_message_id) ->
        {:reply, {:error, :invalid_message_id}, state}

      true ->
        case find_recent_message(state.recent_messages, target_client_message_id) do
          %{type: :text, sender_id: sender_id, availability: :unsent} = target
          when sender_id != reporter_id ->
            case Map.get(target, :safety_snapshot) do
              %{content: content, content_revision: revision}
              when is_binary(content) and is_integer(revision) ->
                emit_report_evidence_capture(:safety_snapshot)

                {:reply,
                 {:ok,
                  %{
                    target_client_message_id: target_client_message_id,
                    content: content,
                    content_revision: revision,
                    source: :safety_snapshot
                  }}, state}

              _missing_snapshot ->
                emit_report_evidence_capture(:unavailable)
                {:reply, {:error, :target_absent}, state}
            end

          %{type: :text, sender_id: sender_id, content: content} = target
          when sender_id != reporter_id and is_binary(content) ->
            emit_report_evidence_capture(:current_content)

            {:reply,
             {:ok,
              %{
                target_client_message_id: target_client_message_id,
                content: content,
                content_revision: Map.get(target, :content_revision, 0),
                source: :current_content
              }}, state}

          %{type: type, sender_id: sender_id}
          when type in [:view_once_photo, :view_once_video] and sender_id != reporter_id ->
            case ViewOnceMediaStore.capture_safety_media(
                   state.conversation.conversation_id,
                   target_client_message_id
                 ) do
              {:ok, %{binary: binary, media_type: media_type, byte_size: byte_size}} ->
                emit_report_evidence_capture(:server_owned_safety_copy)

                {:reply,
                 {:ok,
                  %{
                    type: type,
                    target_client_message_id: target_client_message_id,
                    binary: binary,
                    media_type: media_type,
                    byte_size: byte_size,
                    source: :server_owned_safety_copy
                  }}, state}

              {:error, _reason} ->
                emit_report_evidence_capture(:unavailable)
                {:reply, {:error, :target_absent}, state}
            end

          nil ->
            emit_report_evidence_capture(:absent_from_authority)
            {:reply, {:error, :target_absent}, state}

          _foreign_or_unsupported ->
            emit_report_evidence_capture(:invalid)
            {:reply, {:error, :invalid_request}, state}
        end
    end
  end

  def handle_call(
        {:lookup_reply_target, participant_id, reply_to_client_message_id},
        _from,
        state
      ) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      true ->
        case find_recent_message(state.recent_messages, reply_to_client_message_id) do
          nil ->
            StrangertalksNew.Telemetry.execute([:reply_target, :evicted], %{count: 1})

            {:reply,
             {:ok,
              %{
                status: "confirmed_unavailable",
                reply_to_client_message_id: reply_to_client_message_id
              }}, state}

          %{type: :text, delivery_status: :delivered} = target
          when not is_map_key(target, :availability) or target.availability == :available ->
            relation =
              if target.sender_id == participant_id,
                do: "same_author",
                else: "other_participant"

            snippet = derive_snippet(target.content)

            StrangertalksNew.Telemetry.execute([:reply_target, :found], %{count: 1})

            {:reply,
             {:ok,
              %{
                status: "found",
                reply_to_client_message_id: reply_to_client_message_id,
                reply_author_relation: relation,
                reply_snippet: snippet
              }}, state}

          _invalid_target ->
            {:reply, {:error, :invalid_request}, state}
        end
    end
  end

  def handle_call(
        {:mutate_reaction, participant_id, target_client_message_id, desired_reaction,
         expected_revision},
        _from,
        state
      ) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      not is_integer(expected_revision) or expected_revision < 0 or
          expected_revision > 2_147_483_647 ->
        {:reply, {:error, :invalid_revision}, state}

      true ->
        case StrangertalksNew.EmojiValidator.canonical_reaction(desired_reaction) do
          {:error, :invalid_reaction} ->
            {:reply, {:error, :invalid_request}, state}

          {:ok, canonical_desired} ->
            case find_recent_message(state.recent_messages, target_client_message_id) do
              nil ->
                StrangertalksNew.Telemetry.execute(
                  [:reaction_target, :absent_from_authority],
                  %{count: 1}
                )

                {:reply, {:error, :target_absent}, state}

              %{type: :text, delivery_status: :delivered} = target
              when not is_map_key(target, :availability) or target.availability == :available ->
                current_slot =
                  get_in(target, [:reactions, participant_id]) || %{emoji: nil, revision: 0}

                current_value = Map.get(current_slot, :emoji, Map.get(current_slot, :code))
                current_rev = current_slot.revision

                cond do
                  expected_revision > current_rev ->
                    {:reply, {:error, :invalid_revision}, state}

                  expected_revision == current_rev and canonical_desired != current_value ->
                    new_rev = current_rev + 1
                    new_slot = %{emoji: canonical_desired, revision: new_rev}

                    new_reactions =
                      Map.put(Map.get(target, :reactions, %{}), participant_id, new_slot)

                    updated_target = Map.put(target, :reactions, new_reactions)

                    recent_messages =
                      Enum.map(state.recent_messages, fn
                        %{message_id: id} when id == target.message_id -> updated_target
                        entry -> entry
                      end)

                    state = %{state | recent_messages: recent_messages}

                    StrangertalksNew.Telemetry.execute(
                      [:reaction_mutation, :applied],
                      %{count: 1}
                    )

                    notify_participant(
                      state,
                      participant_id,
                      {:conversation_reaction,
                       %{
                         target_client_message_id: target_client_message_id,
                         owner_relation: "self",
                         emoji: canonical_desired,
                         revision: new_rev
                       }}
                    )

                    notify_other(
                      state,
                      participant_id,
                      {:conversation_reaction,
                       %{
                         target_client_message_id: target_client_message_id,
                         owner_relation: "peer",
                         emoji: canonical_desired,
                         revision: new_rev
                       }}
                    )

                    {:reply,
                     {:ok,
                      %{
                        status: "applied",
                        target_client_message_id: target_client_message_id,
                        emoji: canonical_desired,
                        revision: new_rev
                      }}, state}

                  expected_revision < current_rev and canonical_desired == current_value ->
                    StrangertalksNew.Telemetry.execute(
                      [:reaction_mutation, :idempotent],
                      %{count: 1}
                    )

                    {:reply,
                     {:ok,
                      %{
                        status: "already_canonical",
                        target_client_message_id: target_client_message_id,
                        emoji: current_value,
                        revision: current_rev
                      }}, state}

                  expected_revision < current_rev and canonical_desired != current_value ->
                    StrangertalksNew.Telemetry.execute(
                      [:reaction_stale, :revision],
                      %{count: 1}
                    )

                    {:reply,
                     {:ok,
                      %{
                        status: "stale_revision",
                        target_client_message_id: target_client_message_id,
                        emoji: current_value,
                        revision: current_rev
                      }}, state}

                  expected_revision == current_rev and canonical_desired == current_value ->
                    {:reply,
                     {:ok,
                      %{
                        status: "no_op",
                        target_client_message_id: target_client_message_id,
                        emoji: current_value,
                        revision: current_rev
                      }}, state}
                end

              %{type: :text, delivery_status: status} when status in [:sent, :failed] ->
                {:reply, {:error, :invalid_request}, state}

              _non_text_or_other ->
                {:reply, {:error, :invalid_request}, state}
            end
        end
    end
  end

  def handle_call(
        {:mutate_pin, participant_id, target_client_message_id, pinned, expected_revision},
        _from,
        state
      ) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      not is_integer(expected_revision) or expected_revision < 0 or
          expected_revision > 2_147_483_647 ->
        {:reply, {:error, :invalid_revision}, state}

      true ->
        participant_pins =
          Map.get(state.pins, participant_id, %{revision: 0, items: []})

        current_rev = participant_pins.revision
        current_items = participant_pins.items

        is_already_pinned =
          Enum.any?(current_items, &(&1.target_client_message_id == target_client_message_id))

        desired_already_canonical = pinned == is_already_pinned

        cond do
          expected_revision > current_rev ->
            {:reply, {:error, :invalid_revision}, state}

          expected_revision < current_rev and desired_already_canonical ->
            {:reply,
             {:ok,
              %{
                status: "already_canonical",
                pins: current_items,
                revision: current_rev
              }}, state}

          expected_revision < current_rev and not desired_already_canonical ->
            {:reply,
             {:ok,
              %{
                status: "stale_revision",
                pins: current_items,
                revision: current_rev
              }}, state}

          expected_revision == current_rev and desired_already_canonical ->
            {:reply,
             {:ok,
              %{
                status: "no_op",
                pins: current_items,
                revision: current_rev
              }}, state}

          expected_revision == current_rev and not desired_already_canonical ->
            if pinned do
              case find_recent_message(state.recent_messages, target_client_message_id) do
                nil ->
                  {:reply, {:error, :target_absent}, state}

                %{type: :text, delivery_status: :delivered} = target
                when not is_map_key(target, :availability) or target.availability == :available ->
                  if length(current_items) >= 3 do
                    {:reply, {:error, :pin_limit_reached}, state}
                  else
                    author_relation =
                      if target.sender_id == participant_id, do: "self", else: "peer"

                    snippet = derive_snippet(target.content)

                    new_entry = %{
                      target_client_message_id: target_client_message_id,
                      author_relation: author_relation,
                      snippet: snippet
                    }

                    new_items = current_items ++ [new_entry]
                    new_rev = current_rev + 1
                    new_pins = %{revision: new_rev, items: new_items}
                    state = %{state | pins: Map.put(state.pins, participant_id, new_pins)}

                    notify_participant(
                      state,
                      participant_id,
                      {:conversation_pins,
                       %{
                         pins: new_items,
                         revision: new_rev
                       }}
                    )

                    {:reply,
                     {:ok,
                      %{
                        status: "applied",
                        pins: new_items,
                        revision: new_rev
                      }}, state}
                  end

                _ineligible_target ->
                  {:reply, {:error, :invalid_request}, state}
              end
            else
              # UNPIN
              new_items =
                Enum.reject(
                  current_items,
                  &(&1.target_client_message_id == target_client_message_id)
                )

              new_rev = current_rev + 1
              new_pins = %{revision: new_rev, items: new_items}
              state = %{state | pins: Map.put(state.pins, participant_id, new_pins)}

              notify_participant(
                state,
                participant_id,
                {:conversation_pins,
                 %{
                   pins: new_items,
                   revision: new_rev
                 }}
              )

              {:reply,
               {:ok,
                %{
                  status: "applied",
                  pins: new_items,
                  revision: new_rev
                }}, state}
            end
        end
    end
  end

  def handle_call({:acknowledge_message, participant_id, message_id}, _from, state) do
    state = prune_completed(state)

    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      terminating?(state) ->
        {:reply, {:error, :conversation_terminating}, state}

      true ->
        acknowledge_pending_message(state, participant_id, message_id)
    end
  end

  def handle_call({:append_voice_note, sender_id, attrs, binary}, _from, state) do
    operation_started_at = System.monotonic_time()
    state = prune_voice_completed(state)

    with false <- terminating?(state),
         true <- member?(state, sender_id),
         true <- active_conversation?(state),
         {:ok, result, state} <- accept_or_replay_voice_note(state, sender_id, attrs, binary) do
      unless Map.get(result, :duplicate, false) do
        emit_message_accept_duration(operation_started_at, :voice_note, :success)
      end

      {:reply, {:ok, result}, state}
    else
      true ->
        emit_message_accept_duration(operation_started_at, :voice_note, :failure)
        {:reply, {:error, :conversation_terminating}, state}

      false ->
        emit_message_accept_duration(operation_started_at, :voice_note, :failure)
        {:reply, {:error, conversation_action_error(state, sender_id)}, state}

      {:error, reason} ->
        emit_message_accept_duration(operation_started_at, :voice_note, :failure)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acknowledge_voice_note, participant_id, voice_note_id}, _from, state) do
    state = prune_voice_completed(state)

    if member?(state, participant_id) do
      case state.pending_voice_notes[voice_note_id] do
        %{sender_id: ^participant_id} ->
          {:reply, {:error, :sender_cannot_acknowledge}, state}

        %{recipient_id: ^participant_id} = note ->
          state = finalize_voice_note(state, note, :delivered, nil)
          {:reply, {:ok, %{voice_note_id: voice_note_id, status: "delivered"}}, state}

        nil ->
          duplicate_voice_ack_result(state, participant_id, voice_note_id)

        _note ->
          {:reply, {:error, :not_voice_note_recipient}, state}
      end
    else
      {:reply, {:error, :not_conversation_member}, state}
    end
  end

  def handle_call(:inspect_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:get_avatar_presentation, participant_id}, _from, state) do
    if member?(state, participant_id) do
      avatar_map =
        if Map.has_key?(state, :avatar_map) and not is_nil(state.avatar_map) do
          state.avatar_map
        else
          AvatarCatalog.derive_pair(
            state.conversation.conversation_id,
            state.conversation.participant_a_id,
            state.conversation.participant_b_id
          )
        end

      presentation = AvatarCatalog.project_for_participant(avatar_map, participant_id)
      {:reply, {:ok, presentation}, state}
    else
      {:reply, {:error, :not_conversation_member}, state}
    end
  end

  def handle_call(
        {:append_view_once_photo, sender_id, client_message_id, staging_token},
        from,
        state
      ) do
    handle_call(
      {:append_view_once_photo, sender_id, client_message_id, staging_token, 1},
      from,
      state
    )
  end

  def handle_call(
        {:append_view_once_photo, sender_id, client_message_id, staging_token,
         presentation_limit},
        _from,
        state
      ) do
    operation_started_at = System.monotonic_time()

    with false <- terminating?(state),
         true <- member?(state, sender_id),
         true <- active_conversation?(state),
         {:ok, _uuid} <- Ecto.UUID.cast(client_message_id),
         {:ok, result, state} <-
           accept_or_replay_view_once_photo(
             state,
             sender_id,
             client_message_id,
             staging_token,
             presentation_limit
           ) do
      unless Map.get(result, :duplicate, false) do
        emit_message_accept_duration(operation_started_at, :view_once_photo, :success)
      end

      {:reply, {:ok, result}, state}
    else
      true ->
        emit_message_accept_duration(operation_started_at, :view_once_photo, :failure)
        {:reply, {:error, :conversation_terminating}, state}

      false ->
        emit_message_accept_duration(operation_started_at, :view_once_photo, :failure)
        {:reply, {:error, conversation_action_error(state, sender_id)}, state}

      :error ->
        emit_message_accept_duration(operation_started_at, :view_once_photo, :failure)
        {:reply, {:error, :invalid_message_id}, state}

      {:error, reason} ->
        emit_message_accept_duration(operation_started_at, :view_once_photo, :failure)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:append_view_once_video, sender_id, client_message_id, staging_token},
        from,
        state
      ) do
    handle_call(
      {:append_view_once_video, sender_id, client_message_id, staging_token, 1},
      from,
      state
    )
  end

  def handle_call(
        {:append_view_once_video, sender_id, client_message_id, staging_token,
         presentation_limit},
        _from,
        state
      ) do
    operation_started_at = System.monotonic_time()

    with false <- terminating?(state),
         true <- member?(state, sender_id),
         true <- active_conversation?(state),
         {:ok, _uuid} <- Ecto.UUID.cast(client_message_id),
         {:ok, result, state} <-
           accept_or_replay_view_once_video(
             state,
             sender_id,
             client_message_id,
             staging_token,
             presentation_limit
           ) do
      unless Map.get(result, :duplicate, false) do
        emit_message_accept_duration(operation_started_at, :view_once_video, :success)
      end

      {:reply, {:ok, result}, state}
    else
      true ->
        emit_message_accept_duration(operation_started_at, :view_once_video, :failure)
        {:reply, {:error, :conversation_terminating}, state}

      false ->
        emit_message_accept_duration(operation_started_at, :view_once_video, :failure)
        {:reply, {:error, conversation_action_error(state, sender_id)}, state}

      :error ->
        emit_message_accept_duration(operation_started_at, :view_once_video, :failure)
        {:reply, {:error, :invalid_message_id}, state}

      {:error, reason} ->
        emit_message_accept_duration(operation_started_at, :view_once_video, :failure)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:open_view_once_photo, participant_id, target_client_message_id},
        from,
        state
      ) do
    handle_call(
      {:open_view_once_photo, participant_id, target_client_message_id, nil},
      from,
      state
    )
  end

  def handle_call(
        {:open_view_once_photo, participant_id, target_client_message_id, attempt_id},
        _from,
        state
      ) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not recoverable_conversation?(state) ->
        {:reply, {:error, :conversation_inactive}, state}

      not valid_message_id?(target_client_message_id) ->
        {:reply, {:error, :invalid_message_id}, state}

      true ->
        case find_recent_message(state.recent_messages, target_client_message_id) do
          nil ->
            {:reply, {:error, :target_absent}, state}

          %{type: type, sender_id: ^participant_id}
          when type in [:view_once_photo, :view_once_video] ->
            {:reply, {:error, :sender_cannot_acknowledge}, state}

          %{type: type} = target
          when type in [:view_once_photo, :view_once_video] and
                 is_binary(attempt_id) and attempt_id != "" and
                 is_map_key(target.completed_attempts, attempt_id) ->
            saved_result = Map.get(target.completed_attempts, attempt_id)
            {:reply, {:ok, Map.put(saved_result, :duplicate, true)}, state}

          %{type: type, view_once_state: :unavailable}
          when type in [:view_once_photo, :view_once_video] ->
            {:reply, {:error, :media_unavailable}, state}

          %{type: type, view_once_state: :viewed}
          when type in [:view_once_photo, :view_once_video] ->
            {:reply, {:error, :already_consumed}, state}

          %{type: type, view_once_state: current_st} = target
          when type in [:view_once_photo, :view_once_video] and
                 current_st in [:unviewed, :viewed_once] ->
            views_remaining = Map.get(target, :views_remaining, 1)

            if views_remaining <= 0 do
              {:reply, {:error, :already_consumed}, state}
            else
              # Before canonical consumption, reserve whole-Blob presentation capacity for video
              capacity_reservation =
                if type == :view_once_video do
                  ViewOnceMediaStore.reserve_presentation_capacity(
                    state.conversation.conversation_id,
                    target_client_message_id,
                    participant_id
                  )
                else
                  {:ok, nil}
                end

              case capacity_reservation do
                {:error, :presentation_capacity_unavailable} ->
                  # Capacity unavailable BEFORE consumption: do not burn View!
                  {:reply, {:error, :presentation_capacity_unavailable}, state}

                {:error, reason} ->
                  {:reply, {:error, reason}, state}

                {:ok, _res_token} ->
                  case ViewOnceMediaStore.issue_presentation_capability(
                         state.conversation.conversation_id,
                         target_client_message_id,
                         participant_id,
                         state.epoch_id
                       ) do
                    {:ok, presentation_token} ->
                      new_views_remaining = views_remaining - 1
                      new_views_consumed = Map.get(target, :views_consumed, 0) + 1

                      new_state_atom =
                        if new_views_remaining <= 0, do: :viewed, else: :viewed_once

                      expiry_timer =
                        if new_views_remaining <= 0 do
                          cancel_timer(target.expiry_timer_ref)
                          nil
                        else
                          target.expiry_timer_ref
                        end

                      result = %{
                        status: Atom.to_string(new_state_atom),
                        view_once_state: Atom.to_string(new_state_atom),
                        presentation_limit: Map.get(target, :presentation_limit, 1),
                        views_remaining: new_views_remaining,
                        views_consumed: new_views_consumed,
                        client_message_id: target_client_message_id,
                        sequence: target.sequence,
                        epoch_id: state.epoch_id,
                        presentation_token: presentation_token
                      }

                      completed_attempts =
                        if is_binary(attempt_id) and attempt_id != "" do
                          Map.put(Map.get(target, :completed_attempts, %{}), attempt_id, result)
                        else
                          Map.get(target, :completed_attempts, %{})
                        end

                      revised = %{
                        target
                        | view_once_state: new_state_atom,
                          views_remaining: new_views_remaining,
                          views_consumed: new_views_consumed,
                          expiry_timer_ref: expiry_timer,
                          completed_attempts: completed_attempts
                      }

                      recent_messages =
                        Enum.map(state.recent_messages, fn
                          %{message_id: id} when id == target.message_id -> revised
                          entry -> entry
                        end)

                      state = %{state | recent_messages: recent_messages}

                      viewed_payload = %{
                        client_message_id: target_client_message_id,
                        sequence: target.sequence,
                        epoch_id: state.epoch_id,
                        view_once_state: Atom.to_string(new_state_atom),
                        presentation_limit: Map.get(target, :presentation_limit, 1),
                        views_remaining: new_views_remaining,
                        views_consumed: new_views_consumed
                      }

                      notify_participant(
                        state,
                        target.sender_id,
                        {:view_once_viewed, viewed_payload}
                      )

                      notify_participant(
                        state,
                        participant_id,
                        {:view_once_viewed, viewed_payload}
                      )

                      {:reply, {:ok, result}, state}

                    {:error, :media_unavailable} ->
                      cancel_timer(target.expiry_timer_ref)

                      revised = %{
                        target
                        | view_once_state: :unavailable,
                          views_remaining: 0,
                          expiry_timer_ref: nil
                      }

                      recent_messages =
                        Enum.map(state.recent_messages, fn
                          %{message_id: id} when id == target.message_id -> revised
                          entry -> entry
                        end)

                      state = %{state | recent_messages: recent_messages}

                      unavail_payload = %{
                        client_message_id: target_client_message_id,
                        sequence: target.sequence,
                        epoch_id: state.epoch_id,
                        view_once_state: "unavailable",
                        presentation_limit: Map.get(target, :presentation_limit, 1),
                        views_remaining: 0
                      }

                      notify_participant(
                        state,
                        target.sender_id,
                        {:view_once_unavailable, unavail_payload}
                      )

                      notify_participant(
                        state,
                        participant_id,
                        {:view_once_unavailable, unavail_payload}
                      )

                      {:reply, {:error, :media_unavailable}, state}

                    {:error, reason} ->
                      {:reply, {:error, reason}, state}
                  end
              end
            end

          _other ->
            {:reply, {:error, :target_absent}, state}
        end
    end
  end

  def handle_call({:get_messages_after, participant_id, last_seen_sequence}, _from, state) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not recoverable_conversation?(state) ->
        {:reply, {:error, :conversation_inactive}, state}

      last_seen_sequence < 0 ->
        {:reply, {:error, :invalid_sequence}, state}

      last_seen_sequence > state.next_sequence - 1 ->
        {:reply, {:error, :sequence_ahead}, state}

      state.recent_messages == [] ->
        if last_seen_sequence == 0 or last_seen_sequence == state.next_sequence - 1 do
          other_id = other_participant(state, participant_id)

          {:reply,
           {:ok,
            %{
              from_sequence: last_seen_sequence + 1,
              through_sequence: state.next_sequence - 1,
              messages: [],
              epoch_id: state.epoch_id,
              current_message_revisions: current_message_revisions(state, participant_id),
              reaction_snapshots: [],
              pins: get_participant_pins(state, participant_id),
              icebreaker: icebreaker_snapshot(state),
              avatars: AvatarCatalog.project_for_participant(state.avatar_map, participant_id),
              call_state: project_call_state_for(state.call_state, participant_id),
              peer_presence: derive_participant_presence(state, other_id)
            }}, state}
        else
          {:reply, {:error, :catch_up_gap}, state}
        end

      true ->
        min_retained_seq = hd(state.recent_messages).sequence
        max_retained_seq = List.last(state.recent_messages).sequence

        if last_seen_sequence < min_retained_seq - 1 do
          {:reply, {:error, :catch_up_gap}, state}
        else
          messages =
            state.recent_messages
            |> Enum.filter(&(&1.sequence > last_seen_sequence))
            |> Enum.map(&format_replay_message/1)

          other_id = other_participant(state, participant_id)

          {:reply,
           {:ok,
            %{
              from_sequence: last_seen_sequence + 1,
              through_sequence: max_retained_seq,
              messages: messages,
              epoch_id: state.epoch_id,
              current_message_revisions: current_message_revisions(state, participant_id),
              reaction_snapshots:
                build_reaction_snapshots(state.recent_messages, participant_id, state),
              pins: get_participant_pins(state, participant_id),
              icebreaker: icebreaker_snapshot(state),
              avatars: AvatarCatalog.project_for_participant(state.avatar_map, participant_id),
              call_state: project_call_state_for(state.call_state, participant_id),
              peer_presence: derive_participant_presence(state, other_id)
            }}, state}
        end
    end
  end

  def handle_call({:complete_conversation, participant_id}, _from, state) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      terminating?(state) ->
        {:reply, terminal_completion_result(state), state}

      transition_pending?(state) ->
        state =
          prepare_terminal_transition(
            state,
            :FAILED,
            "left_during_transition",
            "LEFT_DURING_TRANSITION",
            %{
              conversation_completed: false,
              ending_type: :PARTICIPANT_LEFT,
              ending_initiator: participant_id
            },
            %{status: "ended", reason: "left_during_transition"}
          )

        case persist_terminal_intent(state) do
          {:ok, state} ->
            {:stop, :normal, {:ok, %{status: "ended"}}, state}

          {:error, state} ->
            {:reply, {:ok, %{status: "ending"}}, state}
        end

      completable_conversation?(state) ->
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
      {:reply, {:error, conversation_action_error(state, participant_id)}, state}
    end
  end

  def handle_call(
        {:initiate_call, participant_id, channel_pid, session_id, call_type},
        _from,
        state
      ) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      state.call_state != nil and state.call_state.status in [:PENDING, :CONNECTING, :ACTIVE] ->
        {:reply, {:error, :call_already_in_progress}, state}

      call_type not in [:voice, :video, "voice", "video"] ->
        {:reply, {:error, :invalid_call_type}, state}

      true ->
        norm_type = if call_type in [:video, "video"], do: :video, else: :voice
        call_attempt_id = Ecto.UUID.generate()
        other_id = other_participant(state, participant_id)

        timer_ref = Process.send_after(self(), {:call_pending_timeout, call_attempt_id}, 30_000)

        call_state = %{
          call_attempt_id: call_attempt_id,
          status: :PENDING,
          call_type: norm_type,
          caller_id: participant_id,
          callee_id: other_id,
          caller_session_id: session_id,
          callee_session_id: nil,
          caller_endpoint_pid: channel_pid,
          callee_endpoint_pid: nil,
          media_generation: 1,
          media_requests: %{},
          active_media: %{
            video: %{participant_id => norm_type == :video, other_id => false},
            screen_share: %{requester_id: nil, media_request_id: nil}
          },
          mute_state: %{participant_id => false, other_id => false},
          seen_reactions: MapSet.new(),
          reaction_rates: %{},
          active_at: nil,
          c11_reservation: nil,
          timer_ref: timer_ref
        }

        state = %{state | call_state: call_state}

        notify_participant(
          state,
          other_id,
          {:call_incoming,
           %{
             call_attempt_id: call_attempt_id,
             caller_id: participant_id,
             call_type: to_string(norm_type)
           }}
        )

        notify_participant(
          state,
          participant_id,
          {:call_initiated,
           %{
             call_attempt_id: call_attempt_id,
             call_type: to_string(norm_type)
           }}
        )

        {:reply, {:ok, project_call_state_for(call_state, participant_id)}, state}
    end
  end

  def handle_call(
        {:commit_call_admission, participant_id, channel_pid, session_id, call_attempt_id,
         _provider, winning_reservation},
        _from,
        state
      ) do
    case state.call_state do
      %{status: :PENDING, call_attempt_id: ^call_attempt_id, callee_id: ^participant_id} = call ->
        if call.timer_ref, do: Process.cancel_timer(call.timer_ref)
        active_at = System.system_time(:second)

        updated_call = %{
          call
          | status: :ACTIVE,
            callee_session_id: session_id,
            callee_endpoint_pid: channel_pid,
            active_at: active_at,
            timer_ref: nil,
            c11_reservation: winning_reservation
        }

        state = %{state | call_state: updated_call}

        notify_all_participants(
          state,
          {:call_accepted,
           %{
             call_attempt_id: call_attempt_id,
             callee_session_id: session_id,
             active_at: active_at,
             status: "ACTIVE"
           }}
        )

        {:reply, {:ok, project_call_state_for(updated_call, participant_id)}, state}

      %{status: :PENDING, call_attempt_id: ^call_attempt_id, caller_id: ^participant_id} ->
        {:reply, {:error, :invalid_call_state}, state}

      %{call_attempt_id: other_id} when other_id != call_attempt_id ->
        {:reply, {:error, :stale_attempt}, state}

      %{status: status} when status != :PENDING ->
        {:reply, {:error, :invalid_call_state}, state}

      _ ->
        {:reply, {:error, :no_active_call}, state}
    end
  end

  def handle_call(
        {:reject_call_admission, _participant_id, call_attempt_id, reason},
        _from,
        state
      ) do
    case state.call_state do
      %{call_attempt_id: ^call_attempt_id} = call ->
        if call.timer_ref, do: Process.cancel_timer(call.timer_ref)
        updated_call = %{call | status: :TERMINAL, timer_ref: nil}
        state = %{state | call_state: updated_call}

        notify_all_participants(
          state,
          {:call_ended, %{call_attempt_id: call_attempt_id, reason: to_string(reason)}}
        )

        {:reply, {:error, reason}, state}

      _ ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:commit_call_extension, participant_id, _channel_pid, _session_id, call_attempt_id,
         winning_reservation},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
          updated_call = %{call | c11_reservation: winning_reservation}
          {:reply, {:ok, :ok}, %{state | call_state: updated_call}}

        %{call_attempt_id: other_id} when other_id != call_attempt_id ->
          {:reply, {:error, :stale_attempt}, state}

        _ ->
          {:reply, {:error, :no_active_call}, state}
      end
    end
  end

  def handle_call(:get_c11_reservation, _from, state) do
    active_res =
      case state.call_state do
        %{status: :ACTIVE, c11_reservation: res} when is_map(res) -> res
        _ -> nil
      end

    {:reply,
     %{
       active_reservation: active_res,
       terminal_exposure: Map.get(state, :terminal_c11_exposure, nil)
     }, state}
  end

  def handle_call(
        {:decline_call, participant_id, _channel_pid, _session_id, call_attempt_id},
        _from,
        state
      ) do
    case state.call_state do
      %{status: :PENDING, call_attempt_id: ^call_attempt_id, callee_id: ^participant_id} = call ->
        if call.timer_ref, do: Process.cancel_timer(call.timer_ref)
        updated_call = %{call | status: :TERMINAL, timer_ref: nil}
        state = %{state | call_state: updated_call}

        notify_all_participants(
          state,
          {:call_ended,
           %{
             call_attempt_id: call_attempt_id,
             reason: "declined"
           }}
        )

        {:reply, :ok, state}

      %{call_attempt_id: other_id} when other_id != call_attempt_id ->
        {:reply, {:error, :stale_attempt}, state}

      _ ->
        {:reply, {:error, :invalid_call_state}, state}
    end
  end

  def handle_call(
        {:cancel_call, participant_id, _channel_pid, _session_id, call_attempt_id},
        _from,
        state
      ) do
    case state.call_state do
      %{status: :PENDING, call_attempt_id: ^call_attempt_id, caller_id: ^participant_id} = call ->
        if call.timer_ref, do: Process.cancel_timer(call.timer_ref)
        updated_call = %{call | status: :TERMINAL, timer_ref: nil}
        state = %{state | call_state: updated_call}

        notify_all_participants(
          state,
          {:call_ended,
           %{
             call_attempt_id: call_attempt_id,
             reason: "canceled"
           }}
        )

        {:reply, :ok, state}

      %{call_attempt_id: other_id} when other_id != call_attempt_id ->
        {:reply, {:error, :stale_attempt}, state}

      _ ->
        {:reply, {:error, :invalid_call_state}, state}
    end
  end

  def handle_call(
        {:end_call, participant_id, _channel_pid, _session_id, call_attempt_id},
        _from,
        state
      ) do
    case state.call_state do
      %{call_attempt_id: ^call_attempt_id, status: status} = call
      when status in [:PENDING, :CONNECTING, :ACTIVE] ->
        if call.timer_ref, do: Process.cancel_timer(call.timer_ref)

        terminal_exposure =
          case Map.get(call, :c11_reservation) do
            %{expires_at: exp} = res ->
              %{res | expires_at: max(exp, System.monotonic_time(:millisecond) + 10_000)}

            _ ->
              nil
          end

        updated_call = %{call | status: :TERMINAL, timer_ref: nil}
        state = %{state | call_state: updated_call, terminal_c11_exposure: terminal_exposure}

        notify_all_participants(
          state,
          {:call_ended,
           %{
             call_attempt_id: call_attempt_id,
             reason: "ended_by_user",
             ended_by: participant_id
           }}
        )

        {:reply, :ok, state}

      %{call_attempt_id: other_id} when other_id != call_attempt_id ->
        {:reply, {:error, :stale_attempt}, state}

      _ ->
        {:reply, {:error, :no_active_call}, state}
    end
  end

  def handle_call(
        {:set_call_mute, participant_id, _channel_pid, _session_id, call_attempt_id, is_muted},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
          mute_state = Map.put(call.mute_state, participant_id, is_muted == true)
          updated_call = %{call | mute_state: mute_state}
          state = %{state | call_state: updated_call}

          notify_all_participants(
            state,
            {:call_mute_changed,
             %{
               call_attempt_id: call_attempt_id,
               participant_id: participant_id,
               is_muted: is_muted == true
             }}
          )

          {:reply, {:ok, %{is_muted: is_muted == true}}, state}

        %{call_attempt_id: other_id} when other_id != call_attempt_id ->
          {:reply, {:error, :stale_attempt}, state}

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:set_call_effect, participant_id, _channel_pid, _session_id, call_attempt_id,
         effect_active},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
          effects = Map.get(call, :effect_state, %{})
          effect_state = Map.put(effects, participant_id, effect_active == true)
          updated_call = Map.put(call, :effect_state, effect_state)
          state = %{state | call_state: updated_call}

          notify_all_participants(
            state,
            {:call_effect_changed,
             %{
               call_attempt_id: call_attempt_id,
               participant_id: participant_id,
               effect_active: effect_active == true
             }}
          )

          {:reply, {:ok, %{effect_active: effect_active == true}}, state}

        %{call_attempt_id: other_id} when other_id != call_attempt_id ->
          {:reply, {:error, :stale_attempt}, state}

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:signal_call, participant_id, _channel_pid, _session_id, call_attempt_id, generation,
         signal_payload},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, media_generation: current_gen, status: status} = call
        when status in [:CONNECTING, :ACTIVE] ->
          if generation == current_gen do
            other_id = other_participant(state, participant_id)

            target_pid =
              if participant_id == call.caller_id,
                do: call.callee_endpoint_pid,
                else: call.caller_endpoint_pid

            payload = %{
              call_attempt_id: call_attempt_id,
              media_generation: generation,
              signal: signal_payload,
              sender_id: participant_id
            }

            if target_pid && Process.alive?(target_pid) do
              send(target_pid, {:call_signal, payload})
            else
              notify_participant(state, other_id, {:call_signal, payload})
            end

            {:reply, :ok, state}
          else
            {:reply, {:error, :stale_generation}, state}
          end

        %{call_attempt_id: other_id} when other_id != call_attempt_id ->
          {:reply, {:error, :stale_attempt}, state}

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:request_call_media, participant_id, _channel_pid, _session_id, call_attempt_id,
         request_type, proposal},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
          norm_req_type =
            if request_type in [:video_upgrade, "video_upgrade"],
              do: :video_upgrade,
              else: :screen_share

          media_request_id = Ecto.UUID.generate()
          other_id = other_participant(state, participant_id)

          timer_ref =
            Process.send_after(
              self(),
              {:media_request_timeout, call_attempt_id, media_request_id},
              20_000
            )

          mode =
            case proposal do
              %{"mode" => "REVEAL_TOGETHER"} -> "REVEAL_TOGETHER"
              %{mode: :reveal_together} -> "REVEAL_TOGETHER"
              %{mode: "REVEAL_TOGETHER"} -> "REVEAL_TOGETHER"
              _ -> "STANDARD_VIDEO"
            end

          req_info = %{
            media_request_id: media_request_id,
            request_type: norm_req_type,
            requester_id: participant_id,
            proposal: proposal,
            mode: mode,
            ready_state: %{participant_id => false, other_id => false},
            status: :PENDING,
            timer_ref: timer_ref
          }

          media_requests = Map.put(call.media_requests, media_request_id, req_info)
          updated_call = %{call | media_requests: media_requests}
          state = %{state | call_state: updated_call}

          notify_participant(
            state,
            other_id,
            {:call_media_requested,
             %{
               call_attempt_id: call_attempt_id,
               media_request_id: media_request_id,
               request_type: to_string(norm_req_type),
               proposal: proposal,
               requester_id: participant_id
             }}
          )

          {:reply, {:ok, %{media_request_id: media_request_id}}, state}

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:set_reveal_ready, participant_id, _channel_pid, _session_id, call_attempt_id,
         media_request_id, ready},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
          case Map.get(call.media_requests, media_request_id) do
            %{mode: "REVEAL_TOGETHER", ready_state: ready_state} = req ->
              ready_bool = ready in [true, "true", 1, "1"]
              updated_ready = Map.put(ready_state, participant_id, ready_bool)
              updated_req = %{req | ready_state: updated_ready}
              media_requests = Map.put(call.media_requests, media_request_id, updated_req)
              updated_call = %{call | media_requests: media_requests}
              state = %{state | call_state: updated_call}

              notify_all_participants(
                state,
                {:call_reveal_ready,
                 %{
                   call_attempt_id: call_attempt_id,
                   media_request_id: media_request_id,
                   participant_id: participant_id,
                   ready: ready_bool
                 }}
              )

              other_id = other_participant(state, participant_id)
              both_ready = ready_bool and Map.get(updated_ready, other_id, false)

              if both_ready do
                notify_all_participants(
                  state,
                  {:call_reveal_committed,
                   %{
                     call_attempt_id: call_attempt_id,
                     media_request_id: media_request_id
                   }}
                )
              end

              {:reply, {:ok, %{status: "ok", ready: ready_bool, both_ready: both_ready}}, state}

            _ ->
              {:reply, {:error, :invalid_media_request}, state}
          end

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:respond_call_media, participant_id, _channel_pid, _session_id, call_attempt_id,
         media_request_id, decision},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
          case Map.get(call.media_requests, media_request_id) do
            %{status: :PENDING, requester_id: req_id, request_type: req_type} = req
            when req_id != participant_id ->
              if req.timer_ref, do: Process.cancel_timer(req.timer_ref)
              media_requests = Map.delete(call.media_requests, media_request_id)

              if decision in [:accept, "accept", true] do
                new_gen = call.media_generation + 1

                active_media =
                  case req_type do
                    :video_upgrade ->
                      new_video = Map.put(call.active_media.video, req_id, true)
                      %{call.active_media | video: new_video}

                    :screen_share ->
                      %{
                        call.active_media
                        | screen_share: %{
                            requester_id: req_id,
                            media_request_id: media_request_id
                          }
                      }
                  end

                updated_call = %{
                  call
                  | media_requests: media_requests,
                    media_generation: new_gen,
                    active_media: active_media
                }

                state = %{state | call_state: updated_call}

                notify_all_participants(
                  state,
                  {:call_media_updated,
                   %{
                     call_attempt_id: call_attempt_id,
                     media_generation: new_gen,
                     active_media: active_media
                   }}
                )

                {:reply, {:ok, %{status: "accepted", media_generation: new_gen}}, state}
              else
                updated_call = %{call | media_requests: media_requests}
                state = %{state | call_state: updated_call}

                notify_participant(
                  state,
                  req_id,
                  {:call_media_declined,
                   %{
                     call_attempt_id: call_attempt_id,
                     media_request_id: media_request_id
                   }}
                )

                {:reply, {:ok, %{status: "declined"}}, state}
              end

            _ ->
              {:reply, {:error, :invalid_media_request}, state}
          end

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:request_call_credentials, participant_id, _channel_pid, _session_id, call_attempt_id},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{
          call_attempt_id: ^call_attempt_id,
          status: status,
          c11_reservation: %{provider: provider}
        }
        when status in [:CONNECTING, :ACTIVE] ->
          c11_opts = Application.get_env(:strangertalks_new, :c11_policy, [])
          ttl = Keyword.get(c11_opts, :credential_ttl_seconds, nil)

          case C11Policy.authorize_credentials(
                 provider,
                 state.conversation.conversation_id,
                 participant_id,
                 call_attempt_id,
                 ttl
               ) do
            {:ok, creds} -> {:reply, {:ok, creds}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        %{call_attempt_id: ^call_attempt_id, status: :PENDING} ->
          {:reply, {:error, :no_active_reservation}, state}

        %{call_attempt_id: ^call_attempt_id} ->
          {:reply, {:error, :no_active_reservation}, state}

        _ ->
          {:reply, {:error, :no_active_call}, state}
      end
    end
  end

  @allowed_call_reactions ["heart", "wave", "sparkle", "smile", "fire"]

  def handle_call(
        {:return_to_voice, participant_id, _channel_pid, _session_id, call_attempt_id},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      case state.call_state do
        %{call_attempt_id: ^call_attempt_id, status: status} = call
        when status in [:CONNECTING, :ACTIVE] ->
          new_gen = call.media_generation + 1

          Enum.each(call.media_requests, fn {_id, req} ->
            if req.request_type == :video_upgrade and req.timer_ref do
              Process.cancel_timer(req.timer_ref)
            end
          end)

          remaining_media_requests =
            Map.reject(call.media_requests, fn {_id, req} ->
              req.request_type == :video_upgrade
            end)

          updated_active_media = %{call.active_media | video: %{}}

          updated_call = %{
            call
            | media_generation: new_gen,
              media_requests: remaining_media_requests,
              active_media: updated_active_media
          }

          state = %{state | call_state: updated_call}

          notify_all_participants(
            state,
            {:call_media_updated,
             %{
               call_attempt_id: call_attempt_id,
               media_generation: new_gen,
               active_media: updated_active_media,
               return_to_voice: true,
               actor_id: participant_id
             }}
          )

          {:reply, {:ok, %{status: "returned_to_voice", media_generation: new_gen}}, state}

        _ ->
          {:reply, {:error, :invalid_call_state}, state}
      end
    end
  end

  def handle_call(
        {:send_call_reaction, participant_id, _channel_pid, _session_id, call_attempt_id,
         reaction_event_id, reaction},
        _from,
        state
      ) do
    if not member?(state, participant_id) do
      {:reply, {:error, :not_conversation_member}, state}
    else
      reaction_str = to_string(reaction)

      cond do
        not is_binary(reaction_event_id) or byte_size(reaction_event_id) == 0 ->
          {:reply, {:error, :invalid_payload}, state}

        reaction_str not in @allowed_call_reactions ->
          {:reply, {:error, :invalid_payload}, state}

        true ->
          case state.call_state do
            %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
              seen = Map.get(call, :seen_reactions, MapSet.new())

              if MapSet.member?(seen, reaction_event_id) do
                {:reply, {:ok, %{status: "deduplicated", reaction_event_id: reaction_event_id}},
                 state}
              else
                now_ms = System.monotonic_time(:millisecond)
                rates = Map.get(call, :reaction_rates, %{})
                user_history = Map.get(rates, participant_id, [])
                recent = Enum.filter(user_history, fn ts -> now_ms - ts < 2000 end)

                if length(recent) >= 5 do
                  {:reply, {:error, :rate_limited}, state}
                else
                  new_seen =
                    if MapSet.size(seen) >= 100 do
                      seen
                      |> MapSet.to_list()
                      |> Enum.take(50)
                      |> MapSet.new()
                      |> MapSet.put(reaction_event_id)
                    else
                      MapSet.put(seen, reaction_event_id)
                    end

                  new_rates = Map.put(rates, participant_id, [now_ms | recent])
                  updated_call = %{call | seen_reactions: new_seen, reaction_rates: new_rates}
                  state = %{state | call_state: updated_call}

                  notify_all_participants(
                    state,
                    {:call_reaction,
                     %{
                       call_attempt_id: call_attempt_id,
                       reaction_event_id: reaction_event_id,
                       reaction: reaction_str,
                       sender_id: participant_id,
                       timestamp: System.system_time(:millisecond)
                     }}
                  )

                  {:reply, {:ok, %{status: "delivered", reaction_event_id: reaction_event_id}},
                   state}
                end
              end

            %{call_attempt_id: other_id} when other_id != call_attempt_id ->
              {:reply, {:error, :stale_attempt}, state}

            _ ->
              {:reply, {:error, :invalid_call_state}, state}
          end
      end
    end
  end

  def handle_call(
        {:authorized_media_action, participant_id, channel_pid, session_id, call_attempt_id,
         message},
        from,
        state
      ) do
    case state.call_state do
      %{call_attempt_id: ^call_attempt_id} = call ->
        cond do
          not member?(state, participant_id) ->
            handle_call(message, from, state)

          authoritative_media_endpoint?(call, participant_id, channel_pid, session_id) ->
            handle_call(message, from, state)

          true ->
            {:reply, {:error, :not_media_endpoint}, state}
        end

      _ ->
        handle_call(message, from, state)
    end
  end

  def handle_call({:get_call_state, participant_id}, _from, state) do
    {:reply, {:ok, project_call_state_for(state.call_state, participant_id)}, state}
  end

  defp acknowledge_pending_message(state, participant_id, message_id) do
    case Map.get(state.pending, message_id) do
      %{sender_id: ^participant_id} ->
        {:reply, {:error, :sender_cannot_acknowledge}, state}

      %{recipient_id: ^participant_id} = message ->
        state = finalize_message(state, message, :delivered, nil)

        {:reply,
         {:ok, %{message_id: message_id, client_message_id: message_id, status: "delivered"}},
         state}

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
      message -> {:noreply, finalize_message(state, message, :failed, "delivery_expired")}
    end
  end

  def handle_info({:retry_voice_note, voice_note_id, retry_token}, state) do
    case state.pending_voice_notes[voice_note_id] do
      %{retry_token: ^retry_token} = note ->
        note = %{note | retry_ref: nil, retry_token: nil}
        state = put_in(state.pending_voice_notes[voice_note_id], note)

        if connected?(state, note.recipient_id) do
          deliver_voice_note_to_participant(state, note.recipient_id, note)
          {:noreply, schedule_voice_retry(state, voice_note_id)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:expire_voice_note, voice_note_id, expiry_token}, state) do
    case state.pending_voice_notes[voice_note_id] do
      %{expiry_token: ^expiry_token} = note ->
        {:noreply, finalize_voice_note(state, note, :expired, "delivery_expired")}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:prune_completed_voice_note, voice_note_id, completed_at}, state) do
    state =
      case state.completed_voice_notes[voice_note_id] do
        %{completed_at: ^completed_at} ->
          update_in(state.completed_voice_notes, &Map.delete(&1, voice_note_id))

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:view_once_unopened_expiry, client_message_id}, state) do
    case find_recent_message(state.recent_messages, client_message_id) do
      %{type: type, view_once_state: current_st} = target
      when type in [:view_once_photo, :view_once_video] and
             current_st in [:unviewed, :viewed_once] ->
        # If zero views were consumed, delete media from store immediately.
        # If 1 view was already consumed, ViewOnceMediaStore already has safety grace running; preserve it for safety reports.
        if Map.get(target, :views_consumed, 0) == 0 do
          ViewOnceMediaStore.delete_media(
            state.conversation.conversation_id,
            client_message_id
          )
        end

        revised = %{
          target
          | view_once_state: :unavailable,
            views_remaining: 0,
            expiry_timer_ref: nil
        }

        recent_messages =
          Enum.map(state.recent_messages, fn
            %{message_id: id} when id == target.message_id -> revised
            entry -> entry
          end)

        state = %{state | recent_messages: recent_messages}

        payload = %{
          client_message_id: client_message_id,
          sequence: target.sequence,
          epoch_id: state.epoch_id,
          view_once_state: "unavailable",
          presentation_limit: Map.get(target, :presentation_limit, 1),
          views_remaining: 0
        }

        Enum.each(
          [state.conversation.participant_a_id, state.conversation.participant_b_id],
          fn pid ->
            notify_participant(state, pid, {:view_once_unavailable, payload})
          end
        )

        {:noreply, state}

      _other ->
        {:noreply, state}
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
        prev_status = derive_participant_presence(state, participant_id)
        state = %{state | monitor_refs: monitor_refs}

        state =
          state
          |> remove_channel_without_demonitor(participant_id, pid)
          |> drop_channel_sync_floor(pid)

        new_status = derive_participant_presence(state, participant_id)

        state =
          if new_status != prev_status do
            notify_other(state, participant_id, {:conversation_presence, %{status: new_status}})
          else
            state
          end

        state =
          if not connected?(state, participant_id),
            do: participant_disconnected(state, participant_id),
            else: state

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

  def handle_info({:call_pending_timeout, call_attempt_id}, state) do
    case state.call_state do
      %{call_attempt_id: ^call_attempt_id, status: :PENDING} = call ->
        updated_call = %{call | status: :TERMINAL, timer_ref: nil}
        state = %{state | call_state: updated_call}

        notify_all_participants(
          state,
          {:call_ended,
           %{
             call_attempt_id: call_attempt_id,
             reason: "timeout"
           }}
        )

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:media_request_timeout, call_attempt_id, media_request_id}, state) do
    case state.call_state do
      %{call_attempt_id: ^call_attempt_id, media_requests: requests} = call ->
        case Map.pop(requests, media_request_id) do
          {nil, _} ->
            {:noreply, state}

          {%{requester_id: req_id}, remaining_reqs} ->
            updated_call = %{call | media_requests: remaining_reqs}
            state = %{state | call_state: updated_call}

            notify_participant(
              state,
              req_id,
              {:call_media_declined,
               %{
                 call_attempt_id: call_attempt_id,
                 media_request_id: media_request_id,
                 reason: "timeout"
               }}
            )

            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp accept_or_replay_message(
         state,
         sender_id,
         message_id,
         content,
         reply_to_client_message_id,
         expressive
       ) do
    content_hash =
      :crypto.hash(:sha256, "#{content}||reply:#{reply_to_client_message_id || ""}")

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
        with {:ok, reply_author_relation, reply_snippet} <-
               resolve_reply_context(state, sender_id, reply_to_client_message_id) do
          recipient_id = other_participant(state, sender_id)
          sequence = state.next_sequence
          sent_at = DateTime.utc_now()
          accepted_monotonic = System.monotonic_time()

          expiry_ref =
            Process.send_after(self(), {:expire_message, message_id}, @message_expiry_ms)

          message = %{
            message_id: message_id,
            sender_id: sender_id,
            recipient_id: recipient_id,
            content: content,
            content_hash: content_hash,
            content_revision: 0,
            sequence: sequence,
            sent_at: sent_at,
            accepted_monotonic: accepted_monotonic,
            reply_to_client_message_id: reply_to_client_message_id,
            reply_author_relation: reply_author_relation,
            reply_snippet: reply_snippet,
            expiry_ref: expiry_ref,
            retry_ref: nil,
            retry_token: nil,
            expressive: expressive
          }

          state = %{
            state
            | pending: Map.put(state.pending, message_id, message),
              pending_count: state.pending_count + 1,
              pending_bytes: state.pending_bytes + byte_size(content),
              next_sequence: sequence + 1
          }

          replay_entry = %{
            type: if(expressive, do: :expressive, else: :text),
            client_message_id: message_id,
            message_id: message_id,
            sender_id: sender_id,
            content: content,
            content_revision: 0,
            peer_applied_content_revision: nil,
            sequence: sequence,
            sent_at: sent_at,
            delivery_status: :sent,
            reply_to_client_message_id: reply_to_client_message_id,
            reply_author_relation: reply_author_relation,
            reply_snippet: reply_snippet,
            reactions: %{},
            expressive: expressive
          }

          state = append_recent_message(state, replay_entry)
          state = retire_icebreaker(state)

          StrangertalksNew.Telemetry.execute(
            [:message, :accepted],
            %{count: 1},
            %{
              message_type: if(expressive, do: :expressive, else: :text),
              delivery_status: :sent
            }
          )

          notify_status(state, sender_id, message_id, "sent", nil)

          state =
            if connected?(state, recipient_id) do
              deliver_to_participant(state, recipient_id, message)
              schedule_retry(state, message_id)
            else
              state
            end

          result =
            %{
              message_id: message_id,
              sequence: sequence,
              status: "sent",
              content_revision: 0,
              peer_applied_content_revision: nil,
              reply_to_client_message_id: reply_to_client_message_id,
              reply_author_relation: reply_author_relation,
              reply_snippet: reply_snippet,
              expressive: expressive
            }
            |> filter_nil_values()

          {:ok, result, state}
        end
    end
  end

  defp apply_message_edit(
         state,
         participant_id,
         target_client_message_id,
         expected_content_revision,
         content
       ) do
    case find_recent_message(state.recent_messages, target_client_message_id) do
      nil ->
        emit_message_edit(:absent_from_authority)
        {:reply, {:error, :target_absent}, state}

      %{type: :text, sender_id: ^participant_id, availability: :unsent} = target ->
        emit_message_edit(:unavailable)

        {:reply,
         {:ok,
          %{
            status: "unavailable",
            availability: "unsent",
            unsent: true,
            epoch_id: state.epoch_id,
            client_message_id: target.client_message_id,
            message_id: target.message_id,
            sequence: target.sequence,
            content_revision: Map.get(target, :content_revision, 0)
          }}, state}

      %{type: :text, sender_id: ^participant_id, delivery_status: delivery_status} = target
      when delivery_status in [:sent, :delivered] and
             (not is_map_key(target, :availability) or target.availability == :available) ->
        current_revision = Map.get(target, :content_revision, 0)

        cond do
          expected_content_revision > current_revision ->
            emit_message_edit(:invalid)
            {:reply, {:error, :invalid_revision}, state}

          expected_content_revision == current_revision and content == target.content ->
            emit_message_edit(:no_op)
            {:reply, {:ok, edit_result(target, state.epoch_id, "no_op")}, state}

          expected_content_revision == current_revision ->
            revised =
              target
              |> Map.put(:content, content)
              |> Map.put(:content_revision, current_revision + 1)

            state = replace_current_message(state, target, revised)
            state = update_pin_snippets(state, target_client_message_id, content)
            payload = edit_result(revised, state.epoch_id, "applied")
            state = notify_all_participants(state, {:conversation_message_edited, payload})
            emit_message_edit(:applied)
            {:reply, {:ok, payload}, state}

          current_revision == expected_content_revision + 1 and content == target.content ->
            emit_message_edit(:already_canonical)

            {:reply, {:ok, edit_result(target, state.epoch_id, "already_canonical")}, state}

          true ->
            emit_message_edit(:stale)
            {:reply, {:ok, edit_result(target, state.epoch_id, "stale")}, state}
        end

      _ineligible_or_foreign ->
        emit_message_edit(:invalid)
        {:reply, {:error, :invalid_request}, state}
    end
  end

  defp apply_message_unsend(
         state,
         participant_id,
         target_client_message_id,
         expected_content_revision
       ) do
    case find_recent_message(state.recent_messages, target_client_message_id) do
      nil ->
        if Map.has_key?(state.pending_voice_notes, target_client_message_id) or
             Map.has_key?(state.completed_voice_notes, target_client_message_id) do
          emit_message_unsend(:invalid)
          {:reply, {:error, :invalid_request}, state}
        else
          emit_message_unsend(:absent_from_authority)
          {:reply, {:error, :target_absent}, state}
        end

      %{type: :text, sender_id: ^participant_id, availability: :unsent} = target ->
        emit_message_unsend(:already_canonical)
        {:reply, {:ok, unsend_result(target, state.epoch_id, "already_canonical")}, state}

      %{type: :text, sender_id: ^participant_id, delivery_status: delivery_status} = target
      when delivery_status in [:sent, :delivered] ->
        current_revision = Map.get(target, :content_revision, 0)

        cond do
          expected_content_revision > current_revision ->
            emit_message_unsend(:invalid)
            {:reply, {:error, :invalid_revision}, state}

          expected_content_revision < current_revision ->
            emit_message_unsend(:stale)
            {:reply, {:ok, edit_result(target, state.epoch_id, "stale")}, state}

          true ->
            case StrangertalksNew.Reflections.withdraw_peer_excerpt(
                   state.conversation.conversation_id,
                   target.client_message_id || target.message_id,
                   participant_id
                 ) do
              {:ok, _withdrawn} ->
                snapshot = %{
                  content: target.content,
                  content_revision: current_revision
                }

                unsent =
                  target
                  |> Map.put(:availability, :unsent)
                  |> Map.put(:content, nil)
                  |> Map.put(:safety_snapshot, snapshot)
                  |> Map.put(:reactions, %{})

                recent_messages =
                  state.recent_messages
                  |> Enum.map(fn
                    %{message_id: id} when id == target.message_id -> unsent
                    message -> sanitize_reply_context(message, target_client_message_id, :unsent)
                  end)

                {recent_messages, replay_bytes, pruned} =
                  prune_replay_buffer(
                    recent_messages,
                    replay_bytes(recent_messages),
                    @max_replay_messages,
                    @max_replay_bytes
                  )

                state =
                  state
                  |> Map.put(:recent_messages, recent_messages)
                  |> Map.put(:replay_bytes, replay_bytes)
                  |> sanitize_pending_for_unsend(target, current_revision)
                  |> sanitize_completed_reply_contexts(target_client_message_id, :unsent)
                  |> mark_pin_target_unavailable(target_client_message_id, :unsent)
                  |> sanitize_pruned_unsent_references(pruned)

                payload = unsend_result(unsent, state.epoch_id, "applied")
                state = notify_all_participants(state, {:conversation_message_unsent, payload})
                emit_message_unsend(:applied)
                {:reply, {:ok, payload}, state}

              {:error, _reason} ->
                emit_message_unsend(:unavailable)
                {:reply, {:error, :unsend_failed}, state}
            end
        end

      %{type: :text, sender_id: ^participant_id} ->
        emit_message_unsend(:unavailable)
        {:reply, {:error, :invalid_request}, state}

      _ineligible_or_foreign ->
        emit_message_unsend(:invalid)
        {:reply, {:error, :invalid_request}, state}
    end
  end

  defp unsend_result(message, epoch_id, status) do
    %{
      status: status,
      availability: "unsent",
      unsent: true,
      epoch_id: epoch_id,
      client_message_id: message.client_message_id,
      message_id: message.message_id,
      sender_id: message.sender_id,
      sequence: message.sequence,
      content_revision: Map.get(message, :content_revision, 0),
      delivery_status: Atom.to_string(Map.get(message, :delivery_status, :sent))
    }
  end

  defp sanitize_pending_for_unsend(state, target, current_revision) do
    pending =
      Enum.into(state.pending, %{}, fn {message_id, message} ->
        revised =
          cond do
            message_id == target.message_id ->
              message
              |> Map.put(:content, @unsent_message_text)
              |> Map.put(:content_revision, current_revision)
              |> Map.put(:availability, :unsent)

            true ->
              sanitize_reply_context(message, target.message_id, :unsent)
          end

        {message_id, revised}
      end)

    %{state | pending: pending, pending_bytes: pending_bytes(pending)}
  end

  defp sanitize_completed_reply_contexts(state, target_client_message_id, reason) do
    completed =
      Enum.into(state.completed, %{}, fn {message_id, metadata} ->
        {message_id, sanitize_reply_context(metadata, target_client_message_id, reason)}
      end)

    %{state | completed: completed}
  end

  defp sanitize_reply_context(message, target_client_message_id, reason) do
    if Map.get(message, :reply_to_client_message_id) == target_client_message_id do
      message
      |> Map.put(
        :reply_snippet,
        if(reason == :unsent, do: @unsent_reply_text, else: @unavailable_reply_text)
      )
      |> Map.put(:reply_target_availability, reason)
    else
      message
    end
  end

  defp mark_pin_target_unavailable(state, target_client_message_id, reason) do
    snippet = if reason == :unsent, do: @unsent_reply_text, else: @unavailable_reply_text

    Enum.reduce(state.pins, state, fn {participant_id, pin_state}, acc ->
      {items, changed?} =
        Enum.map_reduce(pin_state.items, false, fn
          %{target_client_message_id: ^target_client_message_id} = item, _changed ->
            revised =
              item
              |> Map.put(:snippet, snippet)
              |> Map.put(:unavailable_reason, Atom.to_string(reason))

            {revised, revised != item}

          item, changed ->
            {item, changed}
        end)

      if changed? do
        revised_pin_state = %{pin_state | items: items}
        acc = put_in(acc.pins[participant_id], revised_pin_state)

        notify_participant(
          acc,
          participant_id,
          {:conversation_pins, %{pins: items, revision: revised_pin_state.revision}}
        )
      else
        acc
      end
    end)
  end

  defp sanitize_pruned_unsent_references(state, pruned_messages) do
    pruned_messages
    |> Enum.filter(&(Map.get(&1, :availability) == :unsent))
    |> Enum.reduce(state, fn message, acc ->
      target_client_message_id = message.client_message_id

      recent_messages =
        Enum.map(
          acc.recent_messages,
          &sanitize_reply_context(&1, target_client_message_id, :unavailable)
        )

      pending =
        Enum.into(acc.pending, %{}, fn {message_id, pending_message} ->
          {message_id,
           sanitize_reply_context(pending_message, target_client_message_id, :unavailable)}
        end)

      acc
      |> Map.put(:recent_messages, recent_messages)
      |> Map.put(:pending, pending)
      |> sanitize_completed_reply_contexts(target_client_message_id, :unavailable)
      |> mark_pin_target_unavailable(target_client_message_id, :unavailable)
    end)
  end

  defp pending_bytes(pending) do
    pending
    |> Map.values()
    |> Enum.reduce(0, fn message, total ->
      total + if(is_binary(Map.get(message, :content)), do: byte_size(message.content), else: 0)
    end)
  end

  defp replace_current_message(state, previous, revised) do
    recent_messages =
      Enum.map(state.recent_messages, fn
        %{message_id: id} when id == previous.message_id -> revised
        entry -> entry
      end)

    replay_bytes =
      max(0, state.replay_bytes - message_replay_bytes(previous) + message_replay_bytes(revised))

    {recent_messages, replay_bytes, pruned} =
      prune_replay_buffer(
        recent_messages,
        replay_bytes,
        @max_replay_messages,
        @max_replay_bytes
      )

    {pending, pending_bytes} =
      case Map.get(state.pending, previous.message_id) do
        nil ->
          {state.pending, state.pending_bytes}

        pending_message ->
          revised_pending = %{
            pending_message
            | content: revised.content,
              content_hash:
                message_content_hash(
                  revised.content,
                  Map.get(pending_message, :reply_to_client_message_id)
                ),
              content_revision: revised.content_revision
          }

          {Map.put(state.pending, previous.message_id, revised_pending),
           max(
             0,
             state.pending_bytes - byte_size(pending_message.content) +
               byte_size(revised.content)
           )}
      end

    completed =
      case Map.get(state.completed, previous.message_id) do
        nil ->
          state.completed

        metadata ->
          Map.put(
            state.completed,
            previous.message_id,
            metadata
            |> Map.put(
              :content_hash,
              message_content_hash(
                revised.content,
                Map.get(metadata, :reply_to_client_message_id)
              )
            )
            |> Map.put(:content_revision, revised.content_revision)
          )
      end

    state = %{
      state
      | recent_messages: recent_messages,
        replay_bytes: replay_bytes,
        pending: pending,
        pending_bytes: pending_bytes,
        completed: completed
    }

    sanitize_pruned_unsent_references(state, pruned)
  end

  defp update_pin_snippets(state, target_client_message_id, content) do
    snippet = derive_snippet(content)

    Enum.reduce(state.pins, state, fn {participant_id, pin_state}, acc ->
      {items, changed?} =
        Enum.map_reduce(pin_state.items, false, fn
          %{target_client_message_id: ^target_client_message_id} = item, _changed ->
            {%{item | snippet: snippet}, true}

          item, changed ->
            {item, changed}
        end)

      if changed? do
        revised_pin_state = %{pin_state | items: items}
        acc = put_in(acc.pins[participant_id], revised_pin_state)

        notify_participant(
          acc,
          participant_id,
          {:conversation_pins, %{pins: items, revision: revised_pin_state.revision}}
        )
      else
        acc
      end
    end)
  end

  defp edit_result(message, epoch_id, status) do
    revision = Map.get(message, :content_revision, 0)
    applied_revision = Map.get(message, :peer_applied_content_revision)

    %{
      status: status,
      epoch_id: epoch_id,
      client_message_id: message.client_message_id,
      message_id: message.message_id,
      sequence: message.sequence,
      content: message.content,
      content_revision: revision,
      edited: revision > 0,
      delivery_status: Atom.to_string(Map.get(message, :delivery_status, :sent)),
      peer_applied_content_revision: applied_revision,
      latest_content_status:
        if(is_integer(applied_revision) and applied_revision >= revision,
          do: "delivered",
          else: "sent"
        )
    }
  end

  defp normalize_edited_content(content) when is_binary(content) do
    normalized = String.trim(content)

    cond do
      not String.valid?(normalized) -> {:error, :invalid_request}
      normalized == "" -> {:error, :invalid_request}
      byte_size(normalized) > @max_message_bytes -> {:error, :message_too_large}
      true -> {:ok, normalized}
    end
  end

  defp normalize_edited_content(_content), do: {:error, :invalid_request}

  defp valid_content_revision?(revision),
    do: is_integer(revision) and revision >= 0 and revision <= 2_147_483_647

  defp valid_message_id?(message_id) when is_binary(message_id),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(message_id))

  defp valid_message_id?(_message_id), do: false

  defp message_content_hash(content, reply_to_client_message_id) do
    :crypto.hash(:sha256, "#{content}||reply:#{reply_to_client_message_id || ""}")
  end

  defp emit_message_edit(outcome) do
    StrangertalksNew.Telemetry.execute([:message_edit, outcome], %{count: 1})
  end

  defp emit_message_unsend(outcome) do
    StrangertalksNew.Telemetry.execute([:message_unsend, outcome], %{count: 1})
  end

  defp emit_report_evidence_capture(outcome) do
    StrangertalksNew.Telemetry.execute([:report_evidence, outcome], %{count: 1})
  end

  defp resolve_reply_context(_state, _sender_id, nil), do: {:ok, nil, nil}

  defp resolve_reply_context(state, sender_id, target_id) do
    case find_recent_message(state.recent_messages, target_id) do
      %{type: :text, delivery_status: :delivered} = target
      when not is_map_key(target, :availability) or target.availability == :available ->
        relation =
          if target.sender_id == sender_id,
            do: "same_author",
            else: "other_participant"

        snippet = derive_snippet(target.content)
        {:ok, relation, snippet}

      _ ->
        {:error, :invalid_request}
    end
  end

  @doc false
  def derive_snippet(content) when is_binary(content) do
    collapsed =
      content
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    graphemes = String.graphemes(collapsed)

    if length(graphemes) > 160 or byte_size(collapsed) > 512 do
      truncated =
        graphemes
        |> Enum.take(160)
        |> Enum.reduce_while({"", 0}, fn grapheme, {acc, bytes} ->
          g_bytes = byte_size(grapheme)

          if bytes + g_bytes <= 509 do
            {:cont, {acc <> grapheme, bytes + g_bytes}}
          else
            {:halt, {acc, bytes}}
          end
        end)
        |> elem(0)
        |> String.trim_trailing()

      truncated <> "…"
    else
      collapsed
    end
  end

  def derive_snippet(_), do: ""

  defp accept_or_replay_view_once_photo(
         state,
         sender_id,
         client_message_id,
         staging_token,
         presentation_limit
       ) do
    case find_recent_message(state.recent_messages, client_message_id) do
      %{type: :view_once_photo, sender_id: ^sender_id} = existing ->
        {:ok,
         %{
           client_message_id: client_message_id,
           sequence: existing.sequence,
           epoch_id: state.epoch_id,
           presentation_limit: Map.get(existing, :presentation_limit, 1),
           views_remaining:
             Map.get(
               existing,
               :views_remaining,
               if(existing.view_once_state == :viewed, do: 0, else: 1)
             ),
           views_consumed:
             Map.get(
               existing,
               :views_consumed,
               if(existing.view_once_state == :viewed,
                 do: Map.get(existing, :presentation_limit, 1),
                 else: 0
               )
             ),
           view_once_state: Atom.to_string(existing.view_once_state),
           duplicate: true
         }, state}

      %{client_message_id: ^client_message_id} ->
        {:error, :message_id_conflict}

      nil ->
        case Map.get(state.completed, client_message_id) do
          %{sender_id: ^sender_id} = existing ->
            {:ok,
             %{
               client_message_id: client_message_id,
               sequence: existing.sequence,
               epoch_id: state.epoch_id,
               duplicate: true
             }, state}

          other_completed when not is_nil(other_completed) ->
            {:error, :message_id_conflict}

          nil ->
            sender_unviewed_count =
              Enum.count(state.recent_messages, fn m ->
                m.type in [:view_once_photo, :view_once_video] and m.sender_id == sender_id and
                  m.view_once_state in [:unviewed, :viewed_once]
              end)

            if sender_unviewed_count >= 1 do
              {:error, :view_once_sender_unviewed_limit}
            else
              recipient_id = other_participant(state, sender_id)

              case ViewOnceMediaStore.claim_staged_media(
                     staging_token,
                     state.conversation.conversation_id,
                     sender_id,
                     client_message_id,
                     recipient_id,
                     presentation_limit
                   ) do
                {:ok, metadata} ->
                  sequence = state.next_sequence
                  sent_at = DateTime.utc_now()

                  timer_ref =
                    Process.send_after(
                      self(),
                      {:view_once_unopened_expiry, client_message_id},
                      1_800_000
                    )

                  msg = %{
                    type: :view_once_photo,
                    client_message_id: client_message_id,
                    message_id: client_message_id,
                    sequence: sequence,
                    sender_id: sender_id,
                    presentation_limit: presentation_limit,
                    views_remaining: presentation_limit,
                    views_consumed: 0,
                    view_once_state: :unviewed,
                    byte_size: metadata.byte_size,
                    media_type: metadata.media_type,
                    content_hash: metadata.content_hash,
                    sent_at: sent_at,
                    delivery_status: :sent,
                    expiry_timer_ref: timer_ref,
                    completed_attempts: %{}
                  }

                  updated_messages = state.recent_messages ++ [msg]

                  {pruned_messages, pruned_bytes, _pruned} =
                    prune_replay_buffer(
                      updated_messages,
                      replay_bytes(updated_messages),
                      @max_replay_messages,
                      @max_replay_bytes,
                      []
                    )

                  state = %{
                    state
                    | next_sequence: sequence + 1,
                      recent_messages: pruned_messages,
                      replay_bytes: pruned_bytes
                  }

                  # Broadcast new message projection to recipient (without media bytes!)
                  recipient_payload = %{
                    type: "view_once_photo",
                    epoch_id: state.epoch_id,
                    client_message_id: client_message_id,
                    message_id: client_message_id,
                    sequence: sequence,
                    sender_id: sender_id,
                    mine: false,
                    presentation_limit: presentation_limit,
                    views_remaining: presentation_limit,
                    views_consumed: 0,
                    view_once_state: "unviewed",
                    media_type: metadata.media_type,
                    byte_size: metadata.byte_size,
                    sent_at: DateTime.to_iso8601(sent_at)
                  }

                  notify_participant(
                    state,
                    recipient_id,
                    {:conversation_message, recipient_payload}
                  )

                  notify_status(state, sender_id, client_message_id, "sent", nil)

                  result = %{
                    client_message_id: client_message_id,
                    sequence: sequence,
                    epoch_id: state.epoch_id,
                    presentation_limit: presentation_limit,
                    views_remaining: presentation_limit,
                    views_consumed: 0,
                    view_once_state: "unviewed"
                  }

                  {:ok, result, state}

                {:error, reason} ->
                  {:error, reason}
              end
            end
        end
    end
  end

  defp accept_or_replay_view_once_video(
         state,
         sender_id,
         client_message_id,
         staging_token,
         presentation_limit
       ) do
    presentation_limit = if presentation_limit == 2, do: 2, else: 1

    case find_recent_message(state.recent_messages, client_message_id) do
      %{type: :view_once_video, sender_id: ^sender_id} = existing ->
        {:ok,
         %{
           client_message_id: client_message_id,
           sequence: existing.sequence,
           epoch_id: state.epoch_id,
           presentation_limit: Map.get(existing, :presentation_limit, 1),
           views_remaining:
             Map.get(
               existing,
               :views_remaining,
               if(existing.view_once_state == :viewed,
                 do: 0,
                 else: Map.get(existing, :presentation_limit, 1)
               )
             ),
           views_consumed:
             Map.get(
               existing,
               :views_consumed,
               if(existing.view_once_state == :viewed,
                 do: Map.get(existing, :presentation_limit, 1),
                 else: 0
               )
             ),
           view_once_state: Atom.to_string(existing.view_once_state),
           duplicate: true
         }, state}

      %{client_message_id: ^client_message_id} ->
        {:error, :message_id_conflict}

      nil ->
        case Map.get(state.completed, client_message_id) do
          %{sender_id: ^sender_id} = existing ->
            {:ok,
             %{
               client_message_id: client_message_id,
               sequence: existing.sequence,
               epoch_id: state.epoch_id,
               duplicate: true
             }, state}

          other_completed when not is_nil(other_completed) ->
            {:error, :message_id_conflict}

          nil ->
            sender_unviewed_count =
              Enum.count(state.recent_messages, fn m ->
                m.type in [:view_once_photo, :view_once_video] and m.sender_id == sender_id and
                  m.view_once_state in [:unviewed, :viewed_once]
              end)

            if sender_unviewed_count >= 1 do
              {:error, :view_once_sender_unviewed_limit}
            else
              recipient_id = other_participant(state, sender_id)

              case ViewOnceMediaStore.claim_staged_media(
                     staging_token,
                     state.conversation.conversation_id,
                     sender_id,
                     client_message_id,
                     recipient_id,
                     presentation_limit
                   ) do
                {:ok, metadata} ->
                  sequence = state.next_sequence
                  sent_at = DateTime.utc_now()

                  timer_ref =
                    Process.send_after(
                      self(),
                      {:view_once_unopened_expiry, client_message_id},
                      1_800_000
                    )

                  msg = %{
                    type: :view_once_video,
                    client_message_id: client_message_id,
                    message_id: client_message_id,
                    sequence: sequence,
                    sender_id: sender_id,
                    presentation_limit: presentation_limit,
                    views_remaining: presentation_limit,
                    views_consumed: 0,
                    view_once_state: :unviewed,
                    byte_size: metadata.byte_size,
                    media_type: metadata.media_type,
                    width: Map.get(metadata, :width),
                    height: Map.get(metadata, :height),
                    duration_seconds: Map.get(metadata, :duration_seconds),
                    content_hash: metadata.content_hash,
                    sent_at: sent_at,
                    delivery_status: :sent,
                    expiry_timer_ref: timer_ref,
                    completed_attempts: %{}
                  }

                  updated_messages = state.recent_messages ++ [msg]

                  {pruned_messages, pruned_bytes, _pruned} =
                    prune_replay_buffer(
                      updated_messages,
                      replay_bytes(updated_messages),
                      @max_replay_messages,
                      @max_replay_bytes,
                      []
                    )

                  state = %{
                    state
                    | next_sequence: sequence + 1,
                      recent_messages: pruned_messages,
                      replay_bytes: pruned_bytes
                  }

                  # Broadcast new message projection to recipient (without media bytes!)
                  recipient_payload = %{
                    type: "view_once_video",
                    epoch_id: state.epoch_id,
                    client_message_id: client_message_id,
                    message_id: client_message_id,
                    sequence: sequence,
                    sender_id: sender_id,
                    mine: false,
                    presentation_limit: presentation_limit,
                    views_remaining: presentation_limit,
                    views_consumed: 0,
                    view_once_state: "unviewed",
                    media_type: metadata.media_type,
                    byte_size: metadata.byte_size,
                    width: Map.get(metadata, :width),
                    height: Map.get(metadata, :height),
                    duration_seconds: Map.get(metadata, :duration_seconds),
                    sent_at: DateTime.to_iso8601(sent_at)
                  }

                  notify_participant(
                    state,
                    recipient_id,
                    {:conversation_message, recipient_payload}
                  )

                  notify_status(state, sender_id, client_message_id, "sent", nil)

                  result = %{
                    client_message_id: client_message_id,
                    sequence: sequence,
                    epoch_id: state.epoch_id,
                    presentation_limit: presentation_limit,
                    views_remaining: presentation_limit,
                    views_consumed: 0,
                    view_once_state: "unviewed"
                  }

                  {:ok, result, state}

                {:error, reason} ->
                  {:error, reason}
              end
            end
        end
    end
  end

  defp find_recent_message(messages, message_id) do
    Enum.find(messages, fn
      %{client_message_id: ^message_id} -> true
      %{message_id: ^message_id} -> true
      _ -> false
    end)
  end

  defp accept_or_replay_voice_note(state, sender_id, attrs, binary) do
    voice_note_id = attrs.voice_note_id

    cond do
      note = state.pending_voice_notes[voice_note_id] ->
        voice_idempotent_result(note, sender_id, attrs, state)

      note = state.completed_voice_notes[voice_note_id] ->
        voice_completed_result(note, sender_id, attrs, state)

      map_size(state.pending_voice_notes) >= 3 ->
        {:error, :voice_note_pending_limit}

      true ->
        recipient_id = other_participant(state, sender_id)
        sequence = state.next_sequence
        inserted_at = DateTime.utc_now()
        expires_at = DateTime.add(inserted_at, div(@message_expiry_ms, 1_000), :second)
        expiry_token = make_ref()

        stored_note =
          Map.merge(attrs, %{
            conversation_id: state.conversation.conversation_id,
            sender_id: sender_id,
            recipient_id: recipient_id,
            inserted_at: inserted_at,
            expires_at: expires_at,
            binary: binary
          })

        case VoiceNoteStore.put(stored_note) do
          {:ok, _metadata, storage_status} ->
            accepted_monotonic = System.monotonic_time()

            expiry_ref =
              Process.send_after(
                self(),
                {:expire_voice_note, voice_note_id, expiry_token},
                @message_expiry_ms
              )

            note =
              attrs
              |> Map.merge(%{
                sender_id: sender_id,
                recipient_id: recipient_id,
                sequence: sequence,
                inserted_at: inserted_at,
                accepted_monotonic: accepted_monotonic,
                expiry_ref: expiry_ref,
                expiry_token: expiry_token,
                retry_ref: nil,
                retry_token: nil
              })

            state = %{
              state
              | pending_voice_notes: Map.put(state.pending_voice_notes, voice_note_id, note),
                next_sequence: sequence + 1
            }

            replay_entry = %{
              type: :voice_note,
              voice_note_id: voice_note_id,
              sender_id: sender_id,
              sequence: sequence,
              duration_ms: attrs.duration_ms,
              byte_size: attrs.byte_size,
              media_type: attrs.media_type,
              inserted_at: inserted_at
            }

            state = append_recent_message(state, replay_entry)
            state = retire_icebreaker(state)

            StrangertalksNew.Telemetry.execute(
              [:message, :accepted],
              %{count: 1},
              %{message_type: :voice_note, delivery_status: :sent}
            )

            notify_voice_status(state, sender_id, voice_note_id, "sent_to_server", nil)

            state =
              if connected?(state, recipient_id),
                do:
                  state
                  |> deliver_voice_note_to_participant(recipient_id, note)
                  |> schedule_voice_retry(voice_note_id),
                else: state

            result = voice_result(note, "sent_to_server")
            {:ok, Map.put(result, :storage, storage_status), state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp voice_idempotent_result(note, sender_id, attrs, state) do
    if same_voice_metadata?(note, sender_id, attrs),
      do: {:ok, Map.put(voice_result(note, "sent_to_server"), :duplicate, true), state},
      else: {:error, :voice_note_id_conflict}
  end

  defp voice_completed_result(note, sender_id, attrs, state) do
    if same_voice_metadata?(note, sender_id, attrs),
      do:
        {:ok, Map.put(voice_result(note, Atom.to_string(note.final_state)), :duplicate, true),
         state},
      else: {:error, :voice_note_id_conflict}
  end

  defp same_voice_metadata?(note, sender_id, attrs) do
    note.sender_id == sender_id and
      Enum.all?(
        [:content_hash, :media_type, :duration_ms, :byte_size],
        &(Map.fetch!(note, &1) == Map.fetch!(attrs, &1))
      )
  end

  defp voice_result(note, status),
    do: %{
      voice_note_id: note.voice_note_id,
      status: status,
      duration_ms: note.duration_ms,
      byte_size: note.byte_size,
      media_type: note.media_type,
      sequence: note.sequence
    }

  defp idempotent_result(message, sender_id, content_hash, state) do
    if message.sender_id == sender_id and message.content_hash == content_hash do
      result =
        %{
          message_id: message.message_id,
          client_message_id: message.message_id,
          sequence: message.sequence,
          status: "sent",
          duplicate: true,
          reply_to_client_message_id: Map.get(message, :reply_to_client_message_id),
          reply_author_relation: Map.get(message, :reply_author_relation),
          reply_snippet: Map.get(message, :reply_snippet)
        }
        |> filter_nil_values()

      {:ok, result, state}
    else
      {:error, :message_id_conflict}
    end
  end

  defp completed_result(metadata, sender_id, content_hash, state) do
    if metadata.sender_id == sender_id and metadata.content_hash == content_hash do
      result =
        %{
          message_id: metadata.message_id,
          client_message_id: metadata.message_id,
          sequence: metadata.sequence,
          status: Atom.to_string(metadata.final_state),
          duplicate: true,
          reply_to_client_message_id: Map.get(metadata, :reply_to_client_message_id),
          reply_author_relation: Map.get(metadata, :reply_author_relation),
          reply_snippet: Map.get(metadata, :reply_snippet)
        }
        |> filter_nil_values()

      {:ok, result, state}
    else
      {:error, :message_id_conflict}
    end
  end

  defp filter_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end

  defp duplicate_ack_result(state, participant_id, message_id) do
    case Map.get(state.completed, message_id) do
      %{sender_id: sender_id, final_state: :delivered}
      when sender_id != participant_id and
             participant_id in [
               state.conversation.participant_a_id,
               state.conversation.participant_b_id
             ] ->
        {:reply,
         {:ok, %{message_id: message_id, client_message_id: message_id, status: "delivered"}},
         state}

      %{sender_id: ^participant_id} ->
        {:reply, {:error, :sender_cannot_acknowledge}, state}

      _metadata ->
        {:reply, {:error, :unknown_message}, state}
    end
  end

  defp finalize_message(state, message, final_state, reason) do
    cancel_timer(Map.get(message, :expiry_ref))
    cancel_timer(Map.get(message, :retry_ref))
    completed_at = System.monotonic_time(:millisecond)

    emit_message_terminal_duration(
      Map.get(message, :accepted_monotonic),
      :text,
      if(final_state == :delivered, do: :delivered, else: :failed)
    )

    metadata =
      %{
        message_id: message.message_id,
        sender_id: message.sender_id,
        content_hash: message.content_hash,
        content_revision: Map.get(message, :content_revision, 0),
        sequence: message.sequence,
        final_state: final_state,
        completed_at: completed_at,
        reply_to_client_message_id: Map.get(message, :reply_to_client_message_id),
        reply_author_relation: Map.get(message, :reply_author_relation),
        reply_snippet: Map.get(message, :reply_snippet)
      }
      |> filter_nil_values()

    Process.send_after(
      self(),
      {:prune_completed, message.message_id, completed_at},
      @completed_metadata_ttl_ms
    )

    if final_state == :delivered do
      StrangertalksNew.Telemetry.execute([:message, :delivered], %{count: 1}, %{
        message_type: :text
      })
    else
      StrangertalksNew.Telemetry.execute(
        [:message, :failed],
        %{count: 1},
        %{message_type: :text, reason_code: reason}
      )
    end

    notify_status(
      state,
      message.sender_id,
      message.message_id,
      Atom.to_string(final_state),
      reason
    )

    recent_messages =
      Enum.map(state.recent_messages, fn
        %{type: type, message_id: id} = entry
        when type in [:text, :expressive] and id == message.message_id ->
          %{entry | delivery_status: final_state}

        entry ->
          entry
      end)

    %{
      state
      | pending: Map.delete(state.pending, message.message_id),
        completed: Map.put(state.completed, message.message_id, metadata),
        recent_messages: recent_messages,
        pending_count: state.pending_count - 1,
        pending_bytes: state.pending_bytes - byte_size(message.content)
    }
  end

  defp fail_all_pending(state, reason) do
    state =
      Enum.reduce(Map.values(state.pending), state, fn message, acc ->
        finalize_message(acc, message, :failed, reason)
      end)

    Enum.reduce(Map.values(state.pending_voice_notes), state, fn note, acc ->
      finalize_voice_note(acc, note, :failed, reason)
    end)
  end

  defp finalize_voice_note(state, note, final_state, reason) do
    cancel_timer(note.expiry_ref)
    cancel_timer(note.retry_ref)
    :ok = VoiceNoteStore.delete(state.conversation.conversation_id, note.voice_note_id)
    completed_at = System.monotonic_time(:millisecond)

    emit_message_terminal_duration(
      Map.get(note, :accepted_monotonic),
      :voice_note,
      if(final_state == :delivered, do: :delivered, else: :failed)
    )

    metadata =
      note
      |> Map.take([
        :voice_note_id,
        :sender_id,
        :content_hash,
        :media_type,
        :duration_ms,
        :byte_size,
        :sequence
      ])
      |> Map.merge(%{final_state: final_state, completed_at: completed_at})

    Process.send_after(
      self(),
      {:prune_completed_voice_note, note.voice_note_id, completed_at},
      @completed_metadata_ttl_ms
    )

    if final_state == :delivered do
      StrangertalksNew.Telemetry.execute([:message, :delivered], %{count: 1}, %{
        message_type: :voice_note
      })
    else
      StrangertalksNew.Telemetry.execute(
        [:message, :failed],
        %{count: 1},
        %{message_type: :voice_note, reason_code: reason}
      )
    end

    notify_voice_status(
      state,
      note.sender_id,
      note.voice_note_id,
      Atom.to_string(final_state),
      reason
    )

    %{
      state
      | pending_voice_notes: Map.delete(state.pending_voice_notes, note.voice_note_id),
        completed_voice_notes: Map.put(state.completed_voice_notes, note.voice_note_id, metadata)
    }
  end

  defp duplicate_voice_ack_result(state, participant_id, voice_note_id) do
    case state.completed_voice_notes[voice_note_id] do
      %{sender_id: sender_id, final_state: :delivered}
      when sender_id != participant_id and
             participant_id in [
               state.conversation.participant_a_id,
               state.conversation.participant_b_id
             ] ->
        {:reply, {:ok, %{voice_note_id: voice_note_id, status: "delivered"}}, state}

      %{sender_id: ^participant_id} ->
        {:reply, {:error, :sender_cannot_acknowledge}, state}

      _ ->
        {:reply, {:error, :unknown_voice_note}, state}
    end
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
        source_resolver = fn client_msg_id ->
          find_recent_message(state.recent_messages, client_msg_id)
        end

        _ =
          StrangertalksNew.Reflections.finalize_conversation_terminal(
            conversation.conversation_id,
            intent.ended_at,
            source_resolver
          )

        notify_terminal_clients(state, intent.client_payload)

        dispatch_bus_payload("conversation.ended", %{
          "conversation_id" => conversation.conversation_id,
          "reason" => intent.termination_reason
        })

        maybe_requeue_transition_survivor(conversation, intent)

        {:ok,
         %{
           state
           | conversation: conversation,
             lifecycle_status: intent.target_status,
             terminal_intent: nil
         }}

      {:error, reason} ->
        Logger.error("Conversation terminal persistence failed",
          target_status: intent.target_status,
          reason_code: StrangertalksNew.DomainError.from_error(reason).code
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

  defp schedule_voice_retry(state, voice_note_id) do
    retry_token = make_ref()

    retry_ref =
      Process.send_after(
        self(),
        {:retry_voice_note, voice_note_id, retry_token},
        @retry_interval_ms
      )

    state
    |> put_in([:pending_voice_notes, voice_note_id, :retry_ref], retry_ref)
    |> put_in([:pending_voice_notes, voice_note_id, :retry_token], retry_token)
  end

  defp replay_pending(state, participant_id, channel_pid) do
    state.pending
    |> Map.values()
    |> Enum.filter(&(&1.recipient_id == participant_id))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.reduce(state, fn message, acc ->
      send_delivery(channel_pid, message, state.epoch_id)

      if message.retry_ref do
        acc
      else
        schedule_retry(acc, message.message_id)
      end
    end)
  end

  defp replay_pending_voice_notes(state, participant_id, channel_pid) do
    state.pending_voice_notes
    |> Map.values()
    |> Enum.filter(&(&1.recipient_id == participant_id))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.reduce(state, fn note, acc ->
      send_voice_note_delivery(channel_pid, note, state.epoch_id)
      if note.retry_ref, do: acc, else: schedule_voice_retry(acc, note.voice_note_id)
    end)
  end

  defp deliver_to_participant(state, participant_id, message) do
    state.participant_channels
    |> Map.fetch!(participant_id)
    |> Enum.each(&send_delivery(&1, message, state.epoch_id))
  end

  defp deliver_voice_note_to_participant(state, participant_id, note) do
    state.participant_channels
    |> Map.fetch!(participant_id)
    |> Enum.each(&send_voice_note_delivery(&1, note, state.epoch_id))

    state
  end

  defp send_voice_note_delivery(channel_pid, note, epoch_id) do
    send(
      channel_pid,
      {:conversation_voice_note,
       %{
         epoch_id: epoch_id,
         voice_note_id: note.voice_note_id,
         duration_ms: note.duration_ms,
         byte_size: note.byte_size,
         media_type: note.media_type,
         sequence: note.sequence,
         timestamp: DateTime.to_iso8601(note.inserted_at)
       }}
    )
  end

  defp send_delivery(channel_pid, %{availability: :unsent} = message, epoch_id) do
    send(
      channel_pid,
      {:conversation_message,
       unsent_projection(message)
       |> Map.put(:epoch_id, epoch_id)}
    )
  end

  defp send_delivery(channel_pid, message, epoch_id) do
    payload = %{
      epoch_id: epoch_id,
      message_id: message.message_id,
      client_message_id: message.message_id,
      sequence: message.sequence,
      content: message.content,
      content_revision: Map.get(message, :content_revision, 0),
      edited: Map.get(message, :content_revision, 0) > 0,
      sent_at: DateTime.to_iso8601(message.sent_at)
    }

    payload =
      case Map.get(message, :expressive) do
        expressive when is_map(expressive) ->
          payload
          |> Map.put(:type, "expressive")
          |> Map.put(:expressive, expressive)
          |> Map.delete(:content)

        _ ->
          payload
      end

    payload =
      if Map.get(message, :reply_to_client_message_id) do
        payload
        |> Map.put(:reply_to_client_message_id, message.reply_to_client_message_id)
        |> Map.put(:reply_author_relation, message.reply_author_relation)
        |> Map.put(:reply_snippet, message.reply_snippet)
      else
        payload
      end

    send(channel_pid, {:conversation_message, payload})
  end

  defp notify_status(state, participant_id, message_id, status, reason) do
    msg_entry = state.pending[message_id] || state.completed[message_id]

    sequence =
      case msg_entry do
        %{sequence: seq} -> seq
        _ -> nil
      end

    payload = %{
      epoch_id: state.epoch_id,
      message_id: message_id,
      client_message_id: message_id,
      status: status
    }

    payload = if sequence, do: Map.put(payload, :sequence, sequence), else: payload
    payload = if reason, do: Map.put(payload, :reason, reason), else: payload

    payload =
      case msg_entry do
        %{reply_to_client_message_id: reply_id} when is_binary(reply_id) ->
          payload
          |> Map.put(:reply_to_client_message_id, reply_id)
          |> Map.put(:reply_author_relation, msg_entry.reply_author_relation)
          |> Map.put(:reply_snippet, msg_entry.reply_snippet)

        _ ->
          payload
      end

    state.participant_channels
    |> Map.fetch!(participant_id)
    |> Enum.each(&send(&1, {:conversation_message_status, payload}))
  end

  defp notify_voice_status(state, participant_id, voice_note_id, status, reason) do
    payload = %{epoch_id: state.epoch_id, voice_note_id: voice_note_id, status: status}
    payload = if reason, do: Map.put(payload, :reason, reason), else: payload

    state.participant_channels
    |> Map.fetch!(participant_id)
    |> Enum.each(&send(&1, {:conversation_voice_note_status, payload}))
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
      |> put_in([:session_visibility, channel_pid], :unknown)
    end
  end

  defp remove_channel(state, participant_id, channel_pid) do
    {matching_refs, monitor_refs} =
      Enum.split_with(state.monitor_refs, fn {_ref, value} ->
        value == {channel_pid, participant_id}
      end)

    Enum.each(matching_refs, fn {ref, _value} -> Process.demonitor(ref, [:flush]) end)

    state = %{
      state
      | monitor_refs: Map.new(monitor_refs),
        session_visibility: Map.delete(state.session_visibility, channel_pid)
    }

    remove_channel_without_demonitor(state, participant_id, channel_pid)
  end

  defp remove_channel_without_demonitor(state, participant_id, channel_pid) do
    state = %{state | session_visibility: Map.delete(state.session_visibility, channel_pid)}

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
  end

  def derive_participant_presence(state, participant_id) do
    channels = Map.get(state.participant_channels, participant_id, MapSet.new())

    if MapSet.size(channels) == 0 do
      nil
    else
      visibilities =
        Enum.map(channels, fn pid ->
          Map.get(state.session_visibility, pid, :unknown)
        end)

      cond do
        Enum.any?(visibilities, &(&1 in [:visible, :unknown])) -> "connected"
        Enum.all?(visibilities, &(&1 == :hidden)) -> "away"
        true -> "connected"
      end
    end
  end

  defp send_presence_snapshot(state, participant_id, channel_pid) do
    other_id = other_participant(state, participant_id)
    status = derive_participant_presence(state, other_id)

    send(channel_pid, {:conversation_presence, %{status: status}})
    state
  end

  defp notify_other(state, participant_id, message) do
    state.participant_channels
    |> Map.fetch!(other_participant(state, participant_id))
    |> Enum.each(&send(&1, message))

    state
  end

  defp notify_participant(state, participant_id, message) do
    state.participant_channels
    |> Map.get(participant_id, MapSet.new())
    |> Enum.each(&send(&1, message))

    state
  end

  defp notify_all_participants(state, message) do
    Enum.each(state.participant_channels, fn {_participant_id, channels} ->
      Enum.each(channels, &send(&1, message))
    end)

    state
  end

  defp retire_icebreaker(%{icebreaker: {:active, _identity}} = state) do
    state
    |> Map.put(:icebreaker, :retired)
    |> notify_all_participants({:conversation_icebreaker, %{status: "retired"}})
  end

  defp retire_icebreaker(state), do: state

  defp apply_delivery_progress(state, participant_id, highest_contiguous_sequence) do
    state =
      state.pending
      |> Map.values()
      |> Enum.filter(fn message ->
        message.recipient_id == participant_id and
          message.sequence <= highest_contiguous_sequence
      end)
      |> Enum.sort_by(& &1.sequence)
      |> Enum.reduce(state, fn message, acc ->
        case Map.get(acc.pending, message.message_id) do
          nil -> acc
          current -> finalize_message(acc, current, :delivered, nil)
        end
      end)

    put_in(state.delivery_progress[participant_id], highest_contiguous_sequence)
  end

  defp acknowledge_content_revision(
         state,
         participant_id,
         target_client_message_id,
         content_revision
       ) do
    case find_recent_message(state.recent_messages, target_client_message_id) do
      %{type: :text, sender_id: sender_id} = message when sender_id != participant_id ->
        canonical_revision = Map.get(message, :content_revision, 0)
        applied_revision = Map.get(message, :peer_applied_content_revision)

        cond do
          is_integer(applied_revision) and content_revision <= applied_revision ->
            emit_content_revision_ack(:no_op)

            {:reply,
             {:ok,
              content_revision_ack_result(
                message,
                state.epoch_id,
                applied_revision,
                "no_op"
              )}, state}

          content_revision != canonical_revision ->
            emit_content_revision_ack(:invalid)
            {:reply, {:error, :invalid_revision}, state}

          true ->
            revised = Map.put(message, :peer_applied_content_revision, content_revision)

            recent_messages =
              Enum.map(state.recent_messages, fn
                %{message_id: id} when id == target_client_message_id -> revised
                entry -> entry
              end)

            state = %{state | recent_messages: recent_messages}

            result =
              content_revision_ack_result(
                revised,
                state.epoch_id,
                content_revision,
                "applied"
              )

            state =
              notify_participant(
                state,
                message.sender_id,
                {:conversation_message_content_status, result}
              )

            emit_content_revision_ack(:applied)
            {:reply, {:ok, result}, state}
        end

      _foreign_absent_or_non_text ->
        emit_content_revision_ack(:invalid)
        {:reply, {:error, :invalid_request}, state}
    end
  end

  defp content_revision_ack_result(message, epoch_id, applied_revision, status) do
    %{
      status: status,
      epoch_id: epoch_id,
      client_message_id: message.client_message_id,
      message_id: message.message_id,
      content_revision: Map.get(message, :content_revision, 0),
      peer_applied_content_revision: applied_revision,
      latest_content_status:
        if(applied_revision >= Map.get(message, :content_revision, 0),
          do: "delivered",
          else: "sent"
        )
    }
  end

  defp emit_content_revision_ack(outcome) do
    StrangertalksNew.Telemetry.execute([:content_revision_ack, outcome], %{count: 1})
  end

  defp emit_delivery_progress(status) do
    StrangertalksNew.Telemetry.execute([:delivery_progress, status], %{count: 1})
  end

  defp drop_channel_sync_floor(state, channel_pid) do
    %{state | channel_sync_floors: Map.delete(state.channel_sync_floors, channel_pid)}
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
      case StrangertalksNew.ConversationLifecycle.Transitions.transition(
             state.conversation,
             :participants_connected
           ) do
        {:ok, conversation} -> {:ok, %{state | conversation: conversation}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, state}
    end
  end

  defp persist_conversation_status(conversation, status, ended_at, extra_attrs) do
    event =
      case {status, extra_attrs[:ending_type]} do
        {:ACTIVE, _} -> :participants_connected
        {:PAUSED, _} -> :participant_disconnected
        {:ENDED, :SAFETY_ACTION} -> :safety_terminated
        {:ENDED, _} -> :participant_completed
        {:ABANDONED, _} -> :recovery_timeout
        {:FAILED, _} -> :initialization_failed
        _ -> :abandon
      end

    attrs = if ended_at, do: Map.put(extra_attrs, :ended_at, ended_at), else: extra_attrs

    Repo.transaction(fn ->
      case StrangertalksNew.ConversationLifecycle.Transitions.transition(
             conversation,
             event,
             attrs
           ) do
        {:ok, persisted_conversation} ->
          case maybe_release_pairing_reservations(persisted_conversation, ended_at) do
            :ok -> persisted_conversation
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, persisted_conversation} -> {:ok, persisted_conversation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_release_pairing_reservations(
         %Conversation{conversation_status: status} = conversation,
         ended_at
       ) do
    if release_terminal_status?(status) do
      release_pairing_reservations(
        conversation.match_id,
        ended_at || conversation.ended_at || DateTime.utc_now()
      )
    else
      :ok
    end
  end

  defp release_pairing_reservations(match_id, released_at) do
    with {:ok, dumped_match_id} <- Ecto.UUID.dump(match_id),
         {:ok, _result} <-
           Repo.query(
             """
             UPDATE participant_pairing_reservations
             SET released_at = $2
             WHERE match_id = $1
               AND released_at IS NULL
             """,
             [dumped_match_id, DateTime.to_naive(released_at)]
           ) do
      :ok
    else
      :error -> {:error, :invalid_match_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prune_completed(state) do
    cutoff = System.monotonic_time(:millisecond) - @completed_metadata_ttl_ms

    completed =
      Map.reject(state.completed, fn {_id, metadata} -> metadata.completed_at <= cutoff end)

    %{state | completed: completed}
  end

  defp prune_voice_completed(state) do
    cutoff = System.monotonic_time(:millisecond) - @completed_metadata_ttl_ms

    %{
      state
      | completed_voice_notes:
          Map.reject(state.completed_voice_notes, fn {_id, metadata} ->
            metadata.completed_at <= cutoff
          end)
    }
  end

  defp active_conversation?(state) do
    state.lifecycle_status == :ACTIVE and
      state.conversation.conversation_status in [:PENDING, :ACTIVE]
  end

  defp recoverable_conversation?(state) do
    state.lifecycle_status == :ACTIVE and
      state.conversation.conversation_status in [:PENDING, :ACTIVE, :PAUSED]
  end

  defp completable_conversation?(state) do
    state.lifecycle_status == :ACTIVE and
      state.conversation.conversation_status in [:ACTIVE, :PAUSED]
  end

  defp transition_pending?(state) do
    state.lifecycle_status == :ACTIVE and state.conversation.conversation_status == :PENDING
  end

  defp requeue_transition_survivor(conversation, survivor_id) do
    matching = Repo.get(StrangertalksNew.Matching, conversation.match_id)

    if matching do
      _ =
        matching
        |> StrangertalksNew.Matching.changeset(%{
          match_status: :FAILED,
          failure_reason: :LEFT_DURING_TRANSITION,
          match_end_time: DateTime.utc_now()
        })
        |> Repo.update()
    end

    recovery_result =
      try do
        StrangertalksNew.Matchmaking.MatchmakingEngine.requeue_transition_survivor(
          survivor_id,
          participant_entry_door(matching, survivor_id, conversation.door_type),
          matching.conversation_language,
          conversation.conversation_id
        )
      catch
        :exit, reason -> {:error, reason}
      end

    case recovery_result do
      {:ok, %{status: :queued, queue_attempt_id: queue_attempt_id}} ->
        Phoenix.PubSub.broadcast(
          StrangertalksNew.PubSub,
          "strangertalks:matchmaking",
          {:transition_survivor_requeued, survivor_id, conversation.conversation_id,
           queue_attempt_id}
        )

      _failure ->
        Phoenix.PubSub.broadcast(
          StrangertalksNew.PubSub,
          "strangertalks:matchmaking",
          {:transition_recovery_failed, survivor_id, conversation.conversation_id}
        )
    end

    :ok
  end

  defp participant_entry_door(matching, participant_id, fallback_door) do
    cond do
      matching && matching.participant_a_id == participant_id ->
        matching.participant_a_door_type

      matching && matching.participant_b_id == participant_id ->
        matching.participant_b_door_type

      true ->
        fallback_door
    end
  end

  defp maybe_requeue_transition_survivor(
         conversation,
         %{
           target_status: :FAILED,
           termination_reason: "LEFT_DURING_TRANSITION",
           persistence_attrs: %{ending_initiator: leaving_participant_id}
         }
       ) do
    requeue_transition_survivor(
      conversation,
      other_participant_id(conversation, leaving_participant_id)
    )
  end

  defp maybe_requeue_transition_survivor(_conversation, _intent), do: :ok

  defp other_participant_id(conversation, participant_id) do
    if conversation.participant_a_id == participant_id,
      do: conversation.participant_b_id,
      else: conversation.participant_a_id
  end

  defp conversation_action_error(state, participant_id) do
    if member?(state, participant_id),
      do: :conversation_inactive,
      else: :not_conversation_member
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

      %Conversation{
        conversation_status: :FAILED,
        ending_type: :PARTICIPANT_LEFT,
        ending_initiator: leaving_participant_id
      } = conversation ->
        if participant_id in [conversation.participant_a_id, conversation.participant_b_id] do
          if participant_id != leaving_participant_id do
            _ =
              StrangertalksNew.Matchmaking.MatchmakingEngine.cancel_transition_survivor(
                participant_id,
                conversation.conversation_id
              )
          end

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

  defp authoritative_media_endpoint?(call, participant_id, channel_pid, session_id) do
    cond do
      participant_id == Map.get(call, :caller_id) ->
        Map.get(call, :caller_endpoint_pid) == channel_pid and
          Map.get(call, :caller_session_id) == session_id

      participant_id == Map.get(call, :callee_id) ->
        Map.get(call, :callee_endpoint_pid) == channel_pid and
          Map.get(call, :callee_session_id) == session_id

      true ->
        false
    end
  end

  @media_endpoint_actions [
    :cancel_call,
    :end_call,
    :set_call_mute,
    :set_call_effect,
    :signal_call,
    :request_call_media,
    :respond_call_media,
    :request_call_credentials,
    :return_to_voice,
    :send_call_reaction,
    :set_reveal_ready,
    :commit_call_extension
  ]

  defp wrap_media_endpoint_action(message) when is_tuple(message) and tuple_size(message) >= 5 do
    if elem(message, 0) in @media_endpoint_actions do
      {:authorized_media_action, elem(message, 1), elem(message, 2), elem(message, 3),
       elem(message, 4), message}
    else
      message
    end
  end

  defp wrap_media_endpoint_action(message), do: message

  defp admitted_call(conversation_id, message, mailbox_limit, pressure_error) do
    with {:ok, pid} <- lookup(conversation_id),
         :ok <- mailbox_admission(pid, mailbox_limit, pressure_error) do
      call_pid(pid, wrap_media_endpoint_action(message))
    else
      {:error, :not_started} -> {:error, :conversation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mailbox_admission(pid, mailbox_limit, pressure_error) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queue_len} when queue_len < mailbox_limit -> :ok
      {:message_queue_len, _queue_len} -> {:error, pressure_error}
      nil -> {:error, :conversation_unavailable}
    end
  end

  defp call_pid(pid, message) do
    try do
      GenServer.call(pid, message)
    catch
      :exit, _reason -> {:error, :conversation_unavailable}
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

  defp append_recent_message(state, message) do
    msg_bytes = message_replay_bytes(message)

    updated_messages = state.recent_messages ++ [message]
    updated_bytes = state.replay_bytes + msg_bytes

    {pruned_messages, pruned_bytes, pruned} =
      prune_replay_buffer(
        updated_messages,
        updated_bytes,
        @max_replay_messages,
        @max_replay_bytes
      )

    state = %{state | recent_messages: pruned_messages, replay_bytes: pruned_bytes}
    sanitize_pruned_unsent_references(state, pruned)
  end

  defp prune_replay_buffer(messages, bytes, max_count, max_bytes, pruned \\ []) do
    if length(messages) > max_count or (bytes > max_bytes and length(messages) > 1) do
      [oldest | rest] = messages

      prune_replay_buffer(
        rest,
        max(0, bytes - message_replay_bytes(oldest)),
        max_count,
        max_bytes,
        [oldest | pruned]
      )
    else
      {messages, bytes, Enum.reverse(pruned)}
    end
  end

  defp replay_bytes(messages), do: Enum.reduce(messages, 0, &(&2 + message_replay_bytes(&1)))

  defp message_replay_bytes(%{availability: :unsent} = message) do
    @unsent_message_text
    |> byte_size()
    |> Kernel.+(safety_snapshot_bytes(Map.get(message, :safety_snapshot)))
  end

  defp message_replay_bytes(%{content: content}) when is_binary(content), do: byte_size(content)
  defp message_replay_bytes(_message), do: 0

  defp safety_snapshot_bytes(%{content: content}) when is_binary(content), do: byte_size(content)
  defp safety_snapshot_bytes(_snapshot), do: 0

  defp format_replay_message(%{type: type} = msg)
       when type in [:view_once_photo, :view_once_video] do
    %{
      type: Atom.to_string(type),
      client_message_id: msg.client_message_id,
      message_id: msg.message_id,
      sequence: msg.sequence,
      sender_id: msg.sender_id,
      presentation_limit: Map.get(msg, :presentation_limit, 1),
      views_remaining:
        Map.get(msg, :views_remaining, if(msg.view_once_state == :viewed, do: 0, else: 1)),
      views_consumed:
        Map.get(
          msg,
          :views_consumed,
          if(msg.view_once_state == :viewed,
            do: Map.get(msg, :presentation_limit, 1),
            else: 0
          )
        ),
      view_once_state: Atom.to_string(msg.view_once_state),
      media_type: msg.media_type,
      byte_size: msg.byte_size,
      width: Map.get(msg, :width),
      height: Map.get(msg, :height),
      duration_seconds: Map.get(msg, :duration_seconds),
      sent_at: DateTime.to_iso8601(msg.sent_at)
    }
  end

  defp format_replay_message(%{type: :voice_note} = note) do
    %{
      type: "voice_note",
      voice_note_id: note.voice_note_id,
      sequence: note.sequence,
      sender_id: note.sender_id,
      duration_ms: note.duration_ms,
      byte_size: note.byte_size,
      media_type: note.media_type,
      timestamp: DateTime.to_iso8601(note.inserted_at)
    }
  end

  defp format_replay_message(%{type: :expressive} = msg) do
    %{
      type: "expressive",
      client_message_id: msg.client_message_id,
      message_id: msg.message_id,
      sequence: msg.sequence,
      sender_id: msg.sender_id,
      expressive: msg.expressive,
      sent_at: DateTime.to_iso8601(msg.sent_at)
    }
  end

  defp format_replay_message(%{type: :text, availability: :unsent} = msg) do
    unsent_projection(msg)
  end

  defp format_replay_message(msg) do
    base = %{
      type: "text",
      client_message_id: msg.client_message_id,
      message_id: msg.message_id,
      sequence: msg.sequence,
      sender_id: msg.sender_id,
      content: msg.content,
      content_revision: Map.get(msg, :content_revision, 0),
      peer_applied_content_revision: Map.get(msg, :peer_applied_content_revision),
      edited: Map.get(msg, :content_revision, 0) > 0,
      delivery_status: Atom.to_string(Map.get(msg, :delivery_status, :sent)),
      sent_at: DateTime.to_iso8601(msg.sent_at)
    }

    if Map.get(msg, :reply_to_client_message_id) do
      base
      |> Map.put(:reply_to_client_message_id, msg.reply_to_client_message_id)
      |> Map.put(:reply_author_relation, msg.reply_author_relation)
      |> Map.put(:reply_snippet, msg.reply_snippet)
    else
      base
    end
  end

  defp unsent_projection(msg) do
    delivery_status = Atom.to_string(Map.get(msg, :delivery_status, :sent))

    base = %{
      type: "text",
      availability: "unsent",
      unsent: true,
      client_message_id: Map.get(msg, :client_message_id, msg.message_id),
      message_id: msg.message_id,
      sequence: msg.sequence,
      sender_id: msg.sender_id,
      content_revision: Map.get(msg, :content_revision, 0),
      edited: false,
      delivery_status: delivery_status,
      status: delivery_status,
      sent_at: DateTime.to_iso8601(msg.sent_at)
    }

    if Map.get(msg, :reply_to_client_message_id) do
      base
      |> Map.put(:reply_to_client_message_id, msg.reply_to_client_message_id)
      |> Map.put(:reply_author_relation, msg.reply_author_relation)
      |> Map.put(:reply_snippet, msg.reply_snippet)
    else
      base
    end
  end

  defp calculate_sync_payload(
         state,
         participant_id,
         client_epoch_id,
         last_seen_seq,
         sync_started_at
       ) do
    latest_seq = state.next_sequence - 1

    retained_baseline =
      case state.recent_messages do
        [] -> latest_seq + 1
        [first | _rest] -> first.sequence
      end

    payload =
      cond do
        is_nil(client_epoch_id) or client_epoch_id == "" ->
          messages = format_replay_for_participant(state.recent_messages, participant_id, state)

          %{
            status: "initial",
            epoch_id: state.epoch_id,
            latest_sequence: latest_seq,
            messages: messages
          }

        client_epoch_id != state.epoch_id ->
          messages = format_replay_for_participant(state.recent_messages, participant_id, state)

          %{
            status: "epoch_changed",
            epoch_id: state.epoch_id,
            latest_sequence: latest_seq,
            messages: messages
          }

        is_integer(last_seen_seq) and last_seen_seq > latest_seq ->
          %{
            status: "sequence_inconsistent",
            epoch_id: state.epoch_id,
            latest_sequence: latest_seq,
            messages: []
          }

        state.recent_messages == [] ->
          status =
            if is_integer(last_seen_seq) and last_seen_seq < latest_seq,
              do: "catch_up_partial",
              else: "up_to_date"

          %{
            status: status,
            epoch_id: state.epoch_id,
            latest_sequence: latest_seq,
            messages: []
          }

        true ->
          min_retained_seq = hd(state.recent_messages).sequence
          seq_num = if is_integer(last_seen_seq), do: last_seen_seq, else: 0

          if seq_num < min_retained_seq - 1 do
            messages = format_replay_for_participant(state.recent_messages, participant_id, state)

            %{
              status: "catch_up_partial",
              epoch_id: state.epoch_id,
              latest_sequence: latest_seq,
              messages: messages
            }
          else
            filtered = Enum.filter(state.recent_messages, &(&1.sequence > seq_num))
            messages = format_replay_for_participant(filtered, participant_id, state)
            status = if messages == [], do: "up_to_date", else: "catch_up_complete"

            %{
              status: status,
              epoch_id: state.epoch_id,
              latest_sequence: latest_seq,
              messages: messages
            }
          end
      end

    baseline_sequence =
      if payload.status in ["initial", "epoch_changed", "catch_up_partial"] do
        retained_baseline
      else
        min(
          max(if(is_integer(last_seen_seq), do: last_seen_seq, else: 0) + 1, retained_baseline),
          latest_seq + 1
        )
      end

    avatar_presentation =
      if Map.has_key?(state, :avatar_map) and not is_nil(state.avatar_map) do
        AvatarCatalog.project_for_participant(state.avatar_map, participant_id)
      else
        avatar_map =
          AvatarCatalog.derive_pair(
            state.conversation.conversation_id,
            state.conversation.participant_a_id,
            state.conversation.participant_b_id
          )

        AvatarCatalog.project_for_participant(avatar_map, participant_id)
      end

    payload =
      payload
      |> Map.put(:baseline_sequence, baseline_sequence)
      |> Map.put(:icebreaker, icebreaker_snapshot(state))
      |> Map.put(:avatars, avatar_presentation)
      |> Map.put(:call_state, project_call_state_for(state.call_state, participant_id))

    payload =
      if payload.status != "sequence_inconsistent" do
        other_id = other_participant(state, participant_id)

        payload
        |> Map.put(:current_message_revisions, current_message_revisions(state, participant_id))
        |> Map.put(
          :reaction_snapshots,
          build_reaction_snapshots(state.recent_messages, participant_id, state)
        )
        |> Map.put(:pins, get_participant_pins(state, participant_id))
        |> Map.put(:peer_presence, derive_participant_presence(state, other_id))
      else
        payload
      end

    StrangertalksNew.Telemetry.execute(
      [:timeline, :synchronized],
      %{
        count: 1,
        duration: System.monotonic_time() - sync_started_at,
        message_count: length(payload.messages)
      },
      %{sync_status: String.to_atom(payload.status)}
    )

    payload
  end

  defp get_participant_pins(state, participant_id) do
    Map.get(state.pins, participant_id, %{revision: 0, items: []})
  end

  defp current_message_revisions(state, participant_id) do
    state.recent_messages
    |> Enum.filter(fn message ->
      (message.type == :text and
         (Map.get(message, :availability) == :unsent or
            Map.get(message, :delivery_status, :sent) in [:sent, :delivered])) or
        message.type in [:view_once_photo, :view_once_video, :expressive, :voice_note]
    end)
    |> format_replay_for_participant(participant_id, state)
  end

  defp initial_icebreaker(conversation_id) do
    identity = IcebreakerCatalog.identity_for(conversation_id)
    if IcebreakerCatalog.approved?(identity), do: {:active, identity}, else: :retired
  rescue
    _error -> :retired
  end

  defp icebreaker_snapshot(%{icebreaker: {:active, identity}}) do
    %{status: "active", identity: identity}
  end

  defp icebreaker_snapshot(_state), do: %{status: "retired"}

  defp build_reaction_snapshots(messages, participant_id, state) do
    other_id = other_participant(state, participant_id)

    messages
    |> Enum.filter(
      &(&1.type == :text and Map.get(&1, :delivery_status, :sent) == :delivered and
          Map.get(&1, :availability, :available) == :available)
    )
    |> Enum.map(fn msg ->
      self_slot = get_in(msg, [:reactions, participant_id]) || %{emoji: nil, revision: 0}
      peer_slot = get_in(msg, [:reactions, other_id]) || %{emoji: nil, revision: 0}

      self_val = Map.get(self_slot, :emoji, Map.get(self_slot, :code))
      peer_val = Map.get(peer_slot, :emoji, Map.get(peer_slot, :code))

      %{
        target_client_message_id: msg.client_message_id,
        self_reaction: %{emoji: self_val, revision: self_slot.revision},
        peer_reaction: %{emoji: peer_val, revision: peer_slot.revision}
      }
    end)
  end

  defp emit_message_accept_duration(started_at, message_type, result) do
    StrangertalksNew.Telemetry.execute(
      [:message, :accept],
      %{duration: System.monotonic_time() - started_at},
      %{message_type: message_type, result: result}
    )
  end

  defp emit_message_terminal_duration(started_at, message_type, outcome)
       when is_integer(started_at) do
    StrangertalksNew.Telemetry.execute(
      [:message, :terminal],
      %{duration: System.monotonic_time() - started_at},
      %{message_type: message_type, outcome: outcome}
    )
  end

  defp emit_message_terminal_duration(_started_at, _message_type, _outcome), do: :ok

  defp format_replay_for_participant(messages, participant_id, state) do
    Enum.map(messages, fn
      %{type: type} = msg when type in [:view_once_photo, :view_once_video] ->
        limit = Map.get(msg, :presentation_limit, 1)

        %{
          type: Atom.to_string(type),
          epoch_id: state.epoch_id,
          client_message_id: msg.client_message_id,
          message_id: msg.message_id,
          sequence: msg.sequence,
          sender_id: msg.sender_id,
          mine: msg.sender_id == participant_id,
          presentation_limit: limit,
          views_remaining:
            Map.get(
              msg,
              :views_remaining,
              if(msg.view_once_state == :viewed, do: 0, else: limit)
            ),
          views_consumed:
            Map.get(
              msg,
              :views_consumed,
              if(msg.view_once_state == :viewed, do: limit, else: 0)
            ),
          view_once_state: Atom.to_string(msg.view_once_state),
          media_type: msg.media_type,
          byte_size: msg.byte_size,
          width: Map.get(msg, :width),
          height: Map.get(msg, :height),
          duration_seconds: Map.get(msg, :duration_seconds),
          sent_at: DateTime.to_iso8601(msg.sent_at)
        }

      %{type: :voice_note} = note ->
        %{
          type: "voice_note",
          epoch_id: state.epoch_id,
          voice_note_id: note.voice_note_id,
          sequence: note.sequence,
          sender_id: note.sender_id,
          mine: note.sender_id == participant_id,
          duration_ms: note.duration_ms,
          byte_size: note.byte_size,
          media_type: note.media_type,
          timestamp: DateTime.to_iso8601(note.inserted_at)
        }

      %{type: :text, availability: :unsent} = msg ->
        msg
        |> unsent_projection()
        |> Map.put(:epoch_id, state.epoch_id)
        |> Map.put(:mine, msg.sender_id == participant_id)

      %{type: :text} = msg ->
        status =
          case Map.get(msg, :delivery_status, :sent) do
            :delivered -> "delivered"
            :failed -> "failed"
            _ -> "sent"
          end

        if status == "failed" and msg.sender_id != participant_id do
          %{
            type: "text",
            disposition: "skipped_terminal_failure",
            epoch_id: state.epoch_id,
            client_message_id: msg.client_message_id,
            message_id: msg.message_id,
            sequence: msg.sequence,
            sender_id: msg.sender_id,
            sent_at: DateTime.to_iso8601(msg.sent_at)
          }
        else
          base = %{
            type: "text",
            epoch_id: state.epoch_id,
            client_message_id: msg.client_message_id,
            message_id: msg.message_id,
            sequence: msg.sequence,
            sender_id: msg.sender_id,
            mine: msg.sender_id == participant_id,
            content: msg.content,
            content_revision: Map.get(msg, :content_revision, 0),
            peer_applied_content_revision: Map.get(msg, :peer_applied_content_revision),
            edited: Map.get(msg, :content_revision, 0) > 0,
            status: status,
            sent_at: DateTime.to_iso8601(msg.sent_at)
          }

          if Map.get(msg, :reply_to_client_message_id) do
            base
            |> Map.put(:reply_to_client_message_id, msg.reply_to_client_message_id)
            |> Map.put(:reply_author_relation, msg.reply_author_relation)
            |> Map.put(:reply_snippet, msg.reply_snippet)
          else
            base
          end
        end

      %{type: :expressive} = msg ->
        status = if(Map.get(msg, :delivery_status) == :delivered, do: "delivered", else: "sent")

        %{
          type: "expressive",
          epoch_id: state.epoch_id,
          client_message_id: msg.client_message_id,
          message_id: msg.message_id,
          sequence: msg.sequence,
          sender_id: msg.sender_id,
          mine: msg.sender_id == participant_id,
          expressive: msg.expressive,
          status: status,
          sent_at: DateTime.to_iso8601(msg.sent_at)
        }
    end)
  end

  defp project_call_state_for(nil, _participant_id), do: nil

  defp project_call_state_for(call_state, participant_id) do
    other_id =
      if participant_id == call_state.caller_id,
        do: call_state.callee_id,
        else: call_state.caller_id

    %{
      call_attempt_id: call_state.call_attempt_id,
      status: to_string(call_state.status),
      call_type: to_string(call_state.call_type),
      role: if(participant_id == call_state.caller_id, do: "caller", else: "callee"),
      caller_id: call_state.caller_id,
      callee_id: call_state.callee_id,
      media_generation: call_state.media_generation,
      self_muted: Map.get(call_state.mute_state, participant_id, false),
      peer_muted: Map.get(call_state.mute_state, other_id, false),
      active_media: %{
        self_video: Map.get(call_state.active_media.video, participant_id, false),
        peer_video: Map.get(call_state.active_media.video, other_id, false),
        screen_share: call_state.active_media.screen_share
      },
      active_at: call_state.active_at,
      elapsed_seconds:
        if(call_state.active_at,
          do: max(0, System.system_time(:second) - call_state.active_at),
          else: 0
        ),
      pending_media_request: current_pending_media_request_for(call_state, participant_id)
    }
  end

  defp current_pending_media_request_for(%{media_requests: requests}, participant_id)
       when is_map(requests) do
    case Enum.find(requests, fn {_id, req} -> req.status == :PENDING end) do
      {id, req} ->
        %{
          media_request_id: id,
          request_type: to_string(req.request_type),
          requester_id: req.requester_id,
          proposal: req.proposal,
          incoming: req.requester_id != participant_id
        }

      nil ->
        nil
    end
  end

  defp handle_open_composer_grant(state, participant_id, grant_params) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      true ->
        target_id =
          grant_params[:source_client_message_id] || grant_params["source_client_message_id"]

        expected_rev =
          grant_params[:expected_source_revision] || grant_params["expected_source_revision"]

        start_g =
          grant_params[:selection_start_grapheme] || grant_params["selection_start_grapheme"]

        end_g =
          grant_params[:selection_end_grapheme] || grant_params["selection_end_grapheme"]

        case find_recent_message(state.recent_messages, target_id) do
          nil ->
            {:reply, {:error, :target_absent}, state}

          %{type: :text, availability: :unsent} ->
            {:reply, {:error, :target_absent}, state}

          %{type: :text} = target ->
            current_rev = Map.get(target, :content_revision, 0)

            cond do
              expected_rev != current_rev ->
                {:reply, {:error, :stale}, state}

              is_nil(target.content) ->
                {:reply, {:error, :invalid_request}, state}

              true ->
                total_graphemes = String.length(target.content)

                if not is_integer(start_g) or not is_integer(end_g) or start_g < 0 or
                     end_g <= start_g or end_g > total_graphemes do
                  {:reply, {:error, :invalid_request}, state}
                else
                  len = end_g - start_g
                  slice = String.slice(target.content, start_g, len)

                  case StrangertalksNew.Reflections.validate_source_excerpt(slice) do
                    {:ok, valid_slice} ->
                      attrs = %{
                        source_conversation_id: state.conversation.conversation_id,
                        source_client_message_id: target.client_message_id || target.message_id,
                        source_epoch_id: state.epoch_id,
                        selection_start_grapheme: start_g,
                        selection_end_grapheme: end_g,
                        expected_source_revision: current_rev
                      }

                      case StrangertalksNew.Reflections.open_composer_grant(participant_id, attrs) do
                        {:ok, %{grant: grant, raw_secret: raw_secret}} ->
                          grant_info = %{
                            grant_id: grant.grant_id,
                            raw_secret: raw_secret,
                            excerpt: valid_slice,
                            source_client_message_id:
                              target.client_message_id || target.message_id
                          }

                          {:reply, {:ok, grant_info}, state}

                        {:error, reason} ->
                          {:reply, {:error, reason}, state}
                      end

                    {:error, reason} ->
                      {:reply, {:error, reason}, state}
                  end
                end
            end

          _non_text_or_ineligible ->
            {:reply, {:error, :invalid_request}, state}
        end
    end
  end

  defp handle_save_reflection_with_source(state, participant_id, params) do
    cond do
      not member?(state, participant_id) ->
        {:reply, {:error, :not_conversation_member}, state}

      not active_conversation?(state) ->
        {:reply, {:error, conversation_action_error(state, participant_id)}, state}

      true ->
        grant_id = params["grant_id"] || params[:grant_id]
        grant_secret = params["grant_secret"] || params[:grant_secret]
        op_id = params["create_operation_id"] || params[:create_operation_id]
        note_text = params["own_reflection_text"] || params[:own_reflection_text]

        with %StrangertalksNew.Reflections.ComposerGrant{} = grant <-
               StrangertalksNew.Reflections.get_grant(grant_id, participant_id),
             true <- grant.state == "OPEN" || {:error, :grant_consumed},
             true <-
               :crypto.hash(:sha256, grant_secret) == grant.secret_verifier ||
                 {:error, :invalid_grant_secret},
             true <-
               is_nil(grant.source_epoch_id) or grant.source_epoch_id == state.epoch_id ||
                 {:error, :epoch_mismatch},
             target when not is_nil(target) <-
               find_recent_message(state.recent_messages, grant.source_client_message_id),
             true <- target.type == :text || {:error, :invalid_request},
             true <- target.availability != :unsent || {:error, :target_absent},
             current_rev = Map.get(target, :content_revision, 0),
             true <- current_rev == grant.expected_source_revision || {:error, :stale},
             true <- not is_nil(target.content) || {:error, :invalid_request},
             total_graphemes = String.length(target.content),
             true <-
               (is_integer(grant.selection_start_grapheme) and
                  is_integer(grant.selection_end_grapheme) and
                  grant.selection_start_grapheme >= 0 and
                  grant.selection_end_grapheme > grant.selection_start_grapheme and
                  grant.selection_end_grapheme <= total_graphemes) ||
                 {:error, :invalid_request},
             len = grant.selection_end_grapheme - grant.selection_start_grapheme,
             slice = String.slice(target.content, grant.selection_start_grapheme, len),
             {:ok, valid_slice} <-
               StrangertalksNew.Reflections.validate_source_excerpt(slice) do
          {source_conv_id, source_msg_id, source_epoch_id} =
            if target.sender_id == participant_id do
              {nil, nil, nil}
            else
              {state.conversation.conversation_id, target.client_message_id || target.message_id,
               state.epoch_id}
            end

          StrangertalksNew.Repo.transaction(fn ->
            grant
            |> StrangertalksNew.Reflections.ComposerGrant.changeset(%{
              state: "CONSUMED",
              updated_at: DateTime.utc_now()
            })
            |> StrangertalksNew.Repo.update!()

            reflection_attrs = %{
              create_operation_id: op_id,
              own_reflection_text: note_text,
              source_excerpt: valid_slice,
              source_conversation_id: source_conv_id,
              source_client_message_id: source_msg_id,
              source_epoch_id: source_epoch_id
            }

            case StrangertalksNew.Reflections.create_reflection(participant_id, reflection_attrs) do
              {:ok, result} -> result
              {:error, reason} -> StrangertalksNew.Repo.rollback(reason)
            end
          end)
          |> case do
            {:ok, result} -> {:reply, {:ok, result}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        else
          nil -> {:reply, {:error, :grant_not_found}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp via_tuple(conversation_id) do
    {:via, Registry, {StrangertalksNew.DistributedRegistry, "conversation:#{conversation_id}"}}
  end
end
