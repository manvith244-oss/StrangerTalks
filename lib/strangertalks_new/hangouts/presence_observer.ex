defmodule StrangertalksNew.Hangouts.PresenceObserver do
  @moduledoc false

  use GenServer

  alias StrangertalksNew.Hangouts.RoomServer

  @registry StrangertalksNew.Hangouts.PresenceRegistry
  @attach_retry_ms 25

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    send(self(), :attach_registry_monitor)
    {:ok, %{counts: %{}, registry_pid: nil, registry_ref: nil}}
  end

  @impl true
  def handle_info({:register, @registry, key, _partition, _value}, state) do
    {:noreply, update_in(state.counts, &Map.update(&1, key, 1, fn count -> count + 1 end))}
  end

  def handle_info({:unregister, @registry, key, _partition}, state) do
    {remaining, counts} = decrement(state.counts, key)

    if remaining == 0 do
      disconnect_key(key)
    end

    {:noreply, %{state | counts: counts}}
  end

  def handle_info(:attach_registry_monitor, state) do
    case Process.whereis(@registry) do
      pid when is_pid(pid) and pid != state.registry_pid ->
        if state.registry_ref, do: Process.demonitor(state.registry_ref, [:flush])
        ref = Process.monitor(pid)
        {:noreply, %{state | registry_pid: pid, registry_ref: ref}}

      pid when is_pid(pid) ->
        {:noreply, state}

      nil ->
        Process.send_after(self(), :attach_registry_monitor, @attach_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{registry_ref: ref, registry_pid: pid} = state
      ) do
    # Registry and Endpoint share a rest-for-one failure domain. Registry loss
    # means every tracked transport registration is invalid and the Endpoint is
    # being restarted, so fail closed for every participant we knew was live.
    Enum.each(Map.keys(state.counts), &disconnect_key/1)
    Process.send_after(self(), :attach_registry_monitor, @attach_retry_ms)
    {:noreply, %{state | counts: %{}, registry_pid: nil, registry_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp decrement(counts, key) do
    case Map.get(counts, key, 0) do
      count when count <= 1 -> {0, Map.delete(counts, key)}
      count -> {count - 1, Map.put(counts, key, count - 1)}
    end
  end

  defp disconnect_key({room_id, participant_id})
       when is_binary(room_id) and is_binary(participant_id) do
    _ = RoomServer.disconnect(room_id, participant_id)
    :ok
  end

  defp disconnect_key(_key), do: :ok
end
