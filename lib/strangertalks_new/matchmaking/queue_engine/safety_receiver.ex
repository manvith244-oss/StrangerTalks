defmodule StrangertalksNew.QueueEngine.SafetyReceiver do
  use GenServer
  require Logger

  @pubsub_topic "strangertalks:safety_events"

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(state) do
    # Subscribe to Elixir Phoenix PubSub which is bridged to Redis Pub/Sub
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @pubsub_topic)
    {:ok, state}
  end

  def handle_info(%{event_type: "safety.veto", data: payload}, state) do
    Logger.warning("Safety veto received", operation: :apply_safety_veto)

    # Immediately apply atomic lock/veto via Redis and kill active evaluations
    StrangertalksNew.QueueEngine.QueueState.apply_veto(
      payload["initiating_participant_id"],
      payload["blocked_participant_id"]
    )

    {:noreply, state}
  end
end
