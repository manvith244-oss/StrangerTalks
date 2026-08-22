defmodule StrangertalksNew.QueueEngine.QueueState do
  @moduledoc """
  Volatile, in-memory RAM process for current matchmaking queue attempts.

  This is Elixir's ordinary `Agent` state primitive, not an autonomous StrangerTalks Agent.
  Canonical queue mutation is owned by `MatchmakingEngine`; live participant-tab ownership is
  tracked by `ParticipantConnectionTracker`.
  """
  use Agent
  require Logger

  @doc """
  Starts the Agent with an empty map for transient state.
  """
  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Legacy RamMonitor hook. Current implementation is a no-op placeholder.
  """
  def evict_stale_connections do
    Logger.info("Legacy QueueState eviction hook invoked")
    Agent.update(__MODULE__, fn state -> state end)
    :ok
  end

  @doc """
  Legacy SafetyReceiver compatibility hook.

  PLACEHOLDER ONLY: this function intentionally does not mutate authoritative safety state and
  MUST NOT be treated as final safety enforcement. V1 safety authority is persisted in
  BoundaryBlock / closed Relationship state and is re-read by `MatchmakingEngine` under the
  participant activity lock immediately before Match + Conversation persistence.
  """
  def apply_veto(_initiating_participant_id, _blocked_participant_id) do
    Logger.warning("Legacy QueueState safety-veto hook invoked", operation: :apply_safety_veto)
    Agent.update(__MODULE__, fn state -> state end)
    :ok
  end
end
