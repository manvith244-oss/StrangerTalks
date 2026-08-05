# filepath: lib/strangertalks_new/matching_rules/conversation_room.ex
defmodule StrangertalksNew.MatchingRules.ConversationRoom do
  @moduledoc """
  Manages the isolated runtime heap for single active conversation sessions.
  Enforces the 50-message buffer ceiling and the 10-second flood circuit breaker.
  """
  use GenServer, restart: :temporary
  require Logger

  @max_message_count 50
  @circuit_breaker_window_ms 10_000

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(conversation_id))
  end

  def dispatch_message(conversation_id, sender_id, text) do
    GenServer.call(via_tuple(conversation_id), {:incoming_message, sender_id, text})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    {:ok,
     %{
       conversation_id: Keyword.fetch!(opts, :conversation_id),
       participant_a: Keyword.fetch!(opts, :participant_a),
       participant_b: Keyword.fetch!(opts, :participant_b),
       history: [],
       muted_senders: %{}
     }}
  end

  @impl true
  def handle_call({:incoming_message, sender_id, text}, _from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      is_muted?(state.muted_senders, sender_id, now) ->
        {:reply, {:error, :circuit_breaker_active}, state}

      length(state.history) >= @max_message_count ->
        # Limit hit: Trigger the 10-second mute circuit breaker (Section 1)
        Logger.warning("Conversation message buffer limit hit. Muting sender: #{sender_id}")
        updated_mutes = Map.put(state.muted_senders, sender_id, now + @circuit_breaker_window_ms)
        {:reply, {:error, :buffer_overflow_imminent}, %{state | muted_senders: updated_mutes}}

      true ->
        updated_state = %{state | history: [text | state.history]}
        {:reply, :ok, updated_state}
    end
  end

  defp via_tuple(conversation_id),
    do: {:via, Registry, {StrangertalksNew.ConversationRegistry, conversation_id}}

  defp is_muted?(mutes, sender_id, now) do
    case Map.get(mutes, sender_id) do
      nil -> false
      unlock_time -> now < unlock_time
    end
  end
end
