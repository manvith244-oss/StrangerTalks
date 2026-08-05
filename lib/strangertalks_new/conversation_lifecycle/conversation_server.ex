# filepath: lib/strangertalks_new/conversation_lifecycle/conversation_server.ex
defmodule StrangertalksNew.ConversationLifecycle.ConversationServer do
  @moduledoc """
  Active stateful in-memory supervisor node managing ephemeral conversation lifecycle rules.
  Bypasses database writes for raw messages to enforce the Ghost in the Machine persistence model.
  """

  use GenServer, restart: :transient, spawn_opt: [fullsweep_after: 10]
  require Logger

  @pubsub_topic "strangertalks:matchmaking"
  @recovery_window_ms 60_000
  @max_buffer_bytes 262_144
  @max_buffer_messages 50
  @hibernation_timeout_ms 10_000

  @type state :: %{
          conversation_id: binary(),
          messages: list(),
          message_count: integer(),
          byte_size: integer(),
          recovery_timer: reference() | nil,
          status: atom(),
          disconnected_participants: list()
        }

  # --- Public Client API Boundaries ---

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{conversation_id: conversation_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(conversation_id))
  end

  @spec append_message(binary(), binary(), binary()) :: :ok | {:error, atom()}
  def append_message(conversation_id, sender_id, ciphertext) do
    GenServer.call(via_tuple(conversation_id), {:append_message, sender_id, ciphertext})
  end

  @spec trigger_disconnect(binary(), binary()) :: :ok
  def trigger_disconnect(conversation_id, participant_id) do
    GenServer.cast(via_tuple(conversation_id), {:participant_disconnected, participant_id})
  end

  @spec trigger_reconnect(binary(), binary()) :: :ok | {:error, atom()}
  def trigger_reconnect(conversation_id, participant_id) do
    GenServer.call(via_tuple(conversation_id), {:participant_reentered, participant_id})
  end

  @spec trigger_safety_terminate(binary()) :: :ok
  def trigger_safety_terminate(conversation_id) do
    GenServer.cast(via_tuple(conversation_id), :safety_intervention)
  end

  # --- GenServer Engine Callbacks Engine Core ---

  @impl true
  def init(%{conversation_id: conversation_id}) do
    Process.flag(:trap_exit, true)

    state = %{
      conversation_id: conversation_id,
      messages: [],
      message_count: 0,
      byte_size: 0,
      recovery_timer: nil,
      status: :ACTIVE,
      disconnected_participants: []
    }

    {:ok, state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_call({:append_message, sender_id, ciphertext}, _from, state) do
    msg_size = byte_size(ciphertext)

    if state.message_count >= @max_buffer_messages or
         state.byte_size + msg_size >= @max_buffer_bytes do
      {:reply, {:error, :buffer_overflow_imminent}, state, @hibernation_timeout_ms}
    else
      new_message = %{
        message_id: Ecto.UUID.generate(),
        sender_id: sender_id,
        content: ciphertext,
        created_at: DateTime.utc_now()
      }

      new_state = %{
        state
        | messages: [new_message | state.messages],
          message_count: state.message_count + 1,
          byte_size: state.byte_size + msg_size
      }

      {:reply, :ok, new_state, @hibernation_timeout_ms}
    end
  end

  @impl true
  def handle_call({:participant_reentered, participant_id}, _from, %{status: :RECOVERING} = state) do
    if state.recovery_timer, do: :erlang.cancel_timer(state.recovery_timer)

    updated_disconnected = List.delete(state.disconnected_participants, participant_id)

    new_status = if Enum.empty?(updated_disconnected), do: :ACTIVE, else: :RECOVERING
    new_timer = if new_status == :RECOVERING, do: state.recovery_timer, else: nil

    new_state = %{
      state
      | status: new_status,
        recovery_timer: new_timer,
        disconnected_participants: updated_disconnected
    }

    dispatch_bus_payload("conversation.reconnected", %{
      "conversation_id" => state.conversation_id,
      "participant_id" => participant_id
    })

    {:reply, :ok, new_state, @hibernation_timeout_ms}
  end

  def handle_call({:participant_reentered, _id}, _from, state) do
    {:reply, {:error, :invalid_lifecycle_state}, state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_cast({:participant_disconnected, participant_id}, %{status: :ACTIVE} = state) do
    timer_ref = :erlang.start_timer(@recovery_window_ms, self(), :recovery_grace_expired)

    new_state = %{
      state
      | status: :RECOVERING,
        recovery_timer: timer_ref,
        disconnected_participants: [participant_id | state.disconnected_participants]
    }

    dispatch_bus_payload("conversation.recovery_started", %{
      "conversation_id" => state.conversation_id,
      "participant_id" => participant_id
    })

    {:noreply, new_state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_cast({:participant_disconnected, participant_id}, %{status: :RECOVERING} = state) do
    new_state = %{
      state
      | disconnected_participants: [participant_id | state.disconnected_participants]
    }

    {:noreply, new_state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_cast(:safety_intervention, state) do
    dispatch_bus_payload("conversation.ended", %{
      "conversation_id" => state.conversation_id,
      "reason" => "SAFETY_TERMINATED"
    })

    {:stop, :normal, %{state | status: :SAFETY_TERMINATED}}
  end

  @impl true
  def handle_info({:timeout, _ref, :recovery_grace_expired}, %{status: :RECOVERING} = state) do
    dispatch_bus_payload("conversation.ended", %{
      "conversation_id" => state.conversation_id,
      "reason" => "ABANDONED"
    })

    {:stop, :normal, %{state | status: :ABANDONED}}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state, :hibernate}
  end

  def handle_info(_msg, state) do
    {:noreply, state, @hibernation_timeout_ms}
  end

  # --- Internal Helpers Framework ---

  defp via_tuple(conversation_id) do
    # FIXED: Replaced Horde with native BEAM Registry routing
    {:via, Registry, {StrangertalksNew.DistributedRegistry, "conversation:#{conversation_id}"}}
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
      @pubsub_topic,
      {:conversation_event, String.to_atom(event_name), packet}
    )
  end
end
