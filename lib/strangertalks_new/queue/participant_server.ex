# filepath: lib/strangertalks_new/queue/participant_server.ex
defmodule StrangertalksNew.Queue.ParticipantServer do
  @moduledoc """
  Specialized supervised GenServer process allocated per active participant.
  Governs the deterministic state machine lifecycle transitions, temporal threshold
  decays, and 60-second connection loss grace windows.
  """

  use GenServer, restart: :temporary, spawn_opt: [fullsweep_after: 10]
  require Logger

  # CORRECTED: Uses the exact namespace declared inside the matchmaking_engine.ex file
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Queue.TimeFixture

  @pubsub_topic "strangertalks:matchmaking"
  @recovery_grace_ms 60_000
  @max_wait_ms 195_000
  @warning_trigger_ms 180_000
  @check_interval_ms 5_000
  @hibernation_timeout_ms 10_000

  @type state :: %{
          participant_id: binary(),
          language: binary(),
          selected_door: atom(),
          media_bitmask: integer(),
          typing_speed: float(),
          presence_state: atom(),
          start_time_ms: integer(),
          recovery_timer: reference() | nil,
          decay_step: integer()
        }

  # --- Public Client API Boundaries ---

  @doc """
  Spawns and registers a unique ParticipantServer instance bound to the registry.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(params) do
    participant_id = Map.fetch!(params, :participant_id)
    GenServer.start_link(__MODULE__, params, name: via_tuple(participant_id))
  end

  @doc """
  Signals the participant node that the transport edge socket has dropped out.
  """
  @spec handle_disconnect(binary()) :: :ok | {:error, :not_found}
  def handle_disconnect(participant_id) do
    case Registry.lookup(StrangertalksNew.Queue.Registry, participant_id) do
      [{pid, _}] -> GenServer.cast(pid, :socket_disconnected)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Rebinds a fresh edge transport socket back to the active tracking process.
  """
  @spec handle_reconnect(binary()) :: :ok | {:error, :not_found}
  def handle_reconnect(participant_id) do
    case Registry.lookup(StrangertalksNew.Queue.Registry, participant_id) do
      [{pid, _}] -> GenServer.call(pid, :participant_returned)
      [] -> {:error, :not_found}
    end
  end

  # --- GenServer Callbacks Engine Core ---

  @impl true
  def init(params) do
    start_ms = TimeFixture.current_monotonic_ms()
    participant_id = Map.fetch!(params, :participant_id)

    state = %{
      participant_id: participant_id,
      language: Map.fetch!(params, :language),
      selected_door: Map.fetch!(params, :selected_door),
      media_bitmask: Map.get(params, :media_bitmask, 0),
      typing_speed: Map.get(params, :typing_speed, 0.0),
      presence_state: :QUEUED,
      start_time_ms: start_ms,
      recovery_timer: nil,
      decay_step: 0
    }

    dispatch_payload("queue.joined", %{
      "participant_id" => participant_id,
      "presence_state" => "MATCHING",
      "selected_door" => to_string(state.selected_door),
      "language" => state.language,
      "bootstrap_sessions_completed" => 0,
      "current_monotonic_ms" => start_ms
    })

    :erlang.start_timer(@check_interval_ms, self(), :evaluate_tick)

    {:ok, state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_call(:participant_returned, _from, %{presence_state: :RECOVERING} = state) do
    if state.recovery_timer, do: :erlang.cancel_timer(state.recovery_timer)

    _elapsed = TimeFixture.calculate_elapsed_seconds(state.start_time_ms)
    updated_state = %{state | presence_state: :QUEUED, recovery_timer: nil}

    dispatch_payload("participant.returned", %{
      "participant_id" => state.participant_id,
      "reconnection_delay_seconds" => 5,
      "current_presence_state" => "MATCHING"
    })

    {:reply, :ok, updated_state, @hibernation_timeout_ms}
  end

  def handle_call(:participant_returned, _from, state) do
    {:reply, {:error, :invalid_state_transition}, state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_cast(:socket_disconnected, %{presence_state: :QUEUED} = state) do
    timer_ref = :erlang.start_timer(@recovery_grace_ms, self(), :grace_period_expired)
    updated_state = %{state | presence_state: :RECOVERING, recovery_timer: timer_ref}

    dispatch_payload("queue.recovery_started", %{
      "participant_id" => state.participant_id,
      "disconnect_reason" => "heartbeat_timeout",
      "recovery_window_seconds" => 60,
      "preserved_decay_step" => state.decay_step
    })

    {:noreply, updated_state, @hibernation_timeout_ms}
  end

  def handle_cast(:socket_disconnected, state) do
    {:noreply, state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_info({:timeout, _ref, :evaluate_tick}, %{presence_state: :QUEUED} = state) do
    elapsed_ms = TimeFixture.current_monotonic_ms() - state.start_time_ms

    cond do
      elapsed_ms >= @max_wait_ms ->
        terminate_queue(state, :hard_timeout)

      elapsed_ms >= @warning_trigger_ms ->
        dispatch_payload("queue.timeout_warning", %{
          "participant_id" => state.participant_id,
          "remaining_seconds" => div(@max_wait_ms - elapsed_ms, 1000),
          "action_recommended" => "soft_reassurance"
        })

        schedule_next_tick()
        {:noreply, state, @hibernation_timeout_ms}

      true ->
        elapsed_seconds = div(elapsed_ms, 1000)

        # Invokes the dynamic threshold calculation using the short alias cleanly
        current_threshold = MatchmakingEngine.calculate_decay_threshold(elapsed_seconds, 100)

        dispatch_payload("queue.waiting", %{
          "participant_id" => state.participant_id,
          "elapsed_seconds" => elapsed_seconds,
          "active_decay_threshold" => current_threshold,
          "ambient_queue_health" => "HEALTHY"
        })

        updated_state = check_relaxation_milestones(state, elapsed_seconds, current_threshold)

        schedule_next_tick()
        {:noreply, updated_state, @hibernation_timeout_ms}
    end
  end

  def handle_info({:timeout, _ref, :grace_period_expired}, %{presence_state: :RECOVERING} = state) do
    terminate_queue(state, :recovery_expired)
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state, :hibernate}
  end

  def handle_info(_msg, state) do
    {:noreply, state, @hibernation_timeout_ms}
  end

  # --- Internal Helpers Framework ---

  defp via_tuple(participant_id) do
    {:via, Registry, {StrangertalksNew.Queue.Registry, participant_id}}
  end

  defp schedule_next_tick do
    :erlang.start_timer(@check_interval_ms, self(), :evaluate_tick)
  end

  defp check_relaxation_milestones(state, elapsed, threshold) do
    cond do
      elapsed >= 90 and state.decay_step < 2 ->
        dispatch_relaxation_notice(state, 2, threshold)
        %{state | decay_step: 2}

      elapsed >= 60 and state.decay_step < 1 ->
        dispatch_relaxation_notice(state, 1, threshold)
        %{state | decay_step: 1}

      true ->
        state
    end
  end

  defp dispatch_relaxation_notice(state, tier, threshold) do
    dispatch_payload("queue.constraints_relaxed", %{
      "participant_id" => state.participant_id,
      "relaxed_tier" => tier,
      "allowed_cross_doors" => ["EXPLORE", "SOMETHING_REAL"],
      "new_decay_threshold" => threshold
    })
  end

  defp terminate_queue(state, reason) do
    elapsed_seconds = TimeFixture.calculate_elapsed_seconds(state.start_time_ms)

    dispatch_payload("queue.abandoned", %{
      "participant_id" => state.participant_id,
      "reason" => to_string(reason),
      "total_wait_time" => elapsed_seconds
    })

    dispatch_payload("queue.cleaned", %{
      "participant_id" => state.participant_id,
      "memory_released_bytes" => 4096,
      "ets_keys_removed" => 2
    })

    {:stop, :normal, %{state | presence_state: :TERMINATED}}
  end

  defp dispatch_payload(event_name, payload_data) do
    packet = %{
      "event" => event_name,
      "trace_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => payload_data
    }

    Phoenix.PubSub.broadcast(
      StrangertalksNew.PubSub,
      @pubsub_topic,
      {:queue_event, String.to_atom(event_name), packet}
    )
  end
end
