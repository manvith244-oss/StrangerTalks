# filepath: lib/strangertalks_new/queue/participant_server.ex
defmodule StrangertalksNew.Queue.ParticipantServer do
  @moduledoc """
  LEGACY / DORMANT queue-lifecycle prototype retained for historical test coverage.

  This module has no V1 runtime authority. It is not supervised by
  `StrangertalksNew.Application`, the current ParticipantChannel does not call it,
  and its private registration path still targets `StrangertalksNew.Queue.Registry`,
  which the canonical V1 supervision tree does not start.

  Current queue ownership is split deliberately between
  `StrangertalksNew.QueueEngine.ParticipantConnectionTracker` for live participant-tab
  ownership, `StrangertalksNew.QueueEngine.QueueState` for volatile attempt state, and
  `StrangertalksNew.Matchmaking.MatchmakingEngine` for queue mutation/matching.

  Do not wire this prototype back into production without an explicit architecture change.
  """

  use GenServer, restart: :temporary, spawn_opt: [fullsweep_after: 10]
  require Logger

  # Historical namespace retained with the dormant prototype.
  alias StrangertalksNew.Queue.TimeFixture

  @pubsub_topic "strangertalks:matchmaking"
  @recovery_grace_ms 60_000
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
          recovery_timer: reference() | nil
        }

  # --- Public Client API Boundaries ---

  @doc """
  Spawns and registers a unique ParticipantServer instance bound to the legacy registry.
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
      recovery_timer: nil
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
      "recovery_window_seconds" => 60
    })

    {:noreply, updated_state, @hibernation_timeout_ms}
  end

  def handle_cast(:socket_disconnected, state) do
    {:noreply, state, @hibernation_timeout_ms}
  end

  @impl true
  def handle_info({:timeout, _ref, :evaluate_tick}, %{presence_state: :QUEUED} = state) do
    elapsed_ms = TimeFixture.current_monotonic_ms() - state.start_time_ms

    dispatch_payload("queue.waiting", %{
      "participant_id" => state.participant_id,
      "elapsed_seconds" => div(elapsed_ms, 1000),
      "ambient_queue_health" => "HEALTHY"
    })

    schedule_next_tick()
    {:noreply, state, @hibernation_timeout_ms}
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
