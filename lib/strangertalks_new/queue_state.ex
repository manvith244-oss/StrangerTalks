defmodule StrangertalksNew.QueueState do
  @moduledoc """
  In-memory queue state tracking — participants waiting to be matched.
  Per architecture spec, this data is ephemeral and never written to disk.
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def join_queue(participant_id, intent_vibe_vector \\ %{}) do
    entry = %{
      participant_id: participant_id,
      readiness_snapshot_at: DateTime.utc_now(),
      intent_vibe_vector: intent_vibe_vector,
      wait_duration_seconds: 0
    }

    Agent.update(__MODULE__, fn state -> Map.put(state, participant_id, entry) end)
    {:ok, entry}
  end

  def leave_queue(participant_id) do
    Agent.update(__MODULE__, fn state -> Map.delete(state, participant_id) end)
    :ok
  end

  def get(participant_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state, participant_id) end)
  end

  def list_all do
    Agent.get(__MODULE__, fn state -> Map.values(state) end)
  end
end
