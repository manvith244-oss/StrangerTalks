defmodule StrangertalksNew.QueueEngine.ParticipantConnectionTracker do
  @moduledoc """
  Tracks live ParticipantChannel processes for queue cleanup.

  A participant leaves the volatile matchmaking queue only after their final
  registered ParticipantChannel disappears. ConversationChannel liveness is
  owned independently by each ConversationServer.
  """

  use GenServer

  alias StrangertalksNew.Matchmaking.MatchmakingEngine

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def register(participant_id, channel_pid)
      when is_binary(participant_id) and is_pid(channel_pid) do
    GenServer.call(__MODULE__, {:register, participant_id, channel_pid})
  end

  def unregister(participant_id, channel_pid)
      when is_binary(participant_id) and is_pid(channel_pid) do
    GenServer.call(__MODULE__, {:unregister, participant_id, channel_pid})
  end

  @impl true
  def init(:ok), do: {:ok, %{participants: %{}, monitor_refs: %{}}}

  @impl true
  def handle_call({:register, participant_id, channel_pid}, _from, state) do
    channels = Map.get(state.participants, participant_id, MapSet.new())

    if MapSet.member?(channels, channel_pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(channel_pid)

      state = %{
        state
        | participants:
            Map.put(state.participants, participant_id, MapSet.put(channels, channel_pid)),
          monitor_refs: Map.put(state.monitor_refs, ref, {channel_pid, participant_id})
      }

      {:reply, :ok, state}
    end
  end

  def handle_call({:unregister, participant_id, channel_pid}, _from, state) do
    {state, last_channel?} = remove_channel(state, participant_id, channel_pid, true)
    if last_channel?, do: MatchmakingEngine.leave_queue(participant_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, channel_pid, _reason}, state) do
    case Map.pop(state.monitor_refs, ref) do
      {nil, _monitor_refs} ->
        {:noreply, state}

      {{^channel_pid, participant_id}, monitor_refs} ->
        state = %{state | monitor_refs: monitor_refs}
        {state, last_channel?} = remove_channel(state, participant_id, channel_pid, false)
        if last_channel?, do: MatchmakingEngine.leave_queue(participant_id)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp remove_channel(state, participant_id, channel_pid, demonitor?) do
    if demonitor? do
      state.monitor_refs
      |> Enum.filter(fn {_ref, registration} ->
        registration == {channel_pid, participant_id}
      end)
      |> Enum.each(fn {ref, _registration} -> Process.demonitor(ref, [:flush]) end)
    end

    monitor_refs =
      Map.reject(state.monitor_refs, fn {_ref, registration} ->
        registration == {channel_pid, participant_id}
      end)

    channels =
      state.participants
      |> Map.get(participant_id, MapSet.new())
      |> MapSet.delete(channel_pid)

    {participants, last_channel?} =
      if MapSet.size(channels) == 0 do
        {Map.delete(state.participants, participant_id),
         Map.has_key?(state.participants, participant_id)}
      else
        {Map.put(state.participants, participant_id, channels), false}
      end

    {%{state | participants: participants, monitor_refs: monitor_refs}, last_channel?}
  end
end
