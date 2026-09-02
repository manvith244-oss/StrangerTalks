defmodule StrangertalksNew.QueueEngine.SafetyReceiver do
  @moduledoc """
  ACTIVE BUT NON-AUTHORITATIVE legacy safety-event subscriber.

  Current V1 final safety authority is the persisted BoundaryBlock / closed-Relationship
  re-read performed by `MatchmakingEngine` while both participant activity locks are held.
  This process does not replace that boundary. Its `QueueState.apply_veto/2` call is a
  compatibility placeholder and is not relied on to prevent Match persistence.

  There is no Redis runtime dependency in the current V1 application.
  """

  use GenServer
  require Logger

  @pubsub_topic "strangertalks:safety_events"

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(state) do
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @pubsub_topic)
    {:ok, state}
  end

  def handle_info(%{event_type: "safety.veto", data: payload}, state) do
    Logger.warning("Legacy safety veto notification received", operation: :apply_safety_veto)

    StrangertalksNew.QueueEngine.QueueState.apply_veto(
      payload["initiating_participant_id"],
      payload["blocked_participant_id"]
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
