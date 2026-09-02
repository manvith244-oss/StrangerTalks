defmodule StrangertalksNew.QueueEngine.RamMonitor do
  use GenServer
  require Logger

  # Thresholds based on a 512MB container limit measuring USED memory
  # 85% used (leaves 15% free floor)
  @eviction_trigger_mb 435.2
  # 75% used (restores 25% free ceiling)
  @recovery_ceiling_mb 384.0
  @check_interval_ms 5000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_ram_check()
    {:ok, state}
  end

  def handle_info(:check_ram, state) do
    # :erlang.memory(:total) returns total bytes allocated to the BEAM VM
    used_ram_mb = :erlang.memory(:total) / (1024 * 1024)

    cond do
      used_ram_mb >= @eviction_trigger_mb ->
        Logger.warning(
          "RAM usage high (#{Float.round(used_ram_mb, 2)}MB). Triggering LRS Eviction."
        )

        trigger_eviction_loop()

      used_ram_mb <= @recovery_ceiling_mb ->
        # Optional: Comment out this Logger.info in production to avoid log spam every 5 seconds
        # Logger.info("RAM usage normal (#{Float.round(used_ram_mb, 2)}MB).")
        :ok

      true ->
        :ok
    end

    schedule_ram_check()
    {:noreply, state}
  end

  defp schedule_ram_check do
    Process.send_after(self(), :check_ram, @check_interval_ms)
  end

  defp trigger_eviction_loop do
    StrangertalksNew.QueueEngine.QueueState.evict_stale_connections()
  end
end
