defmodule StrangertalksNew.GoogleContinuity.RateLimiter do
  @moduledoc "Single-node V1 limiter; replace with shared enforcement before multi-node deployment."
  use GenServer

  @capacity 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def allow?(bucket, key, limit, window_seconds),
    do: GenServer.call(__MODULE__, {:allow, bucket, key, limit, window_seconds})

  def size, do: GenServer.call(__MODULE__, :size)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:allow, bucket, key, limit, window_seconds}, _from, state) do
    now = System.monotonic_time(:second)
    state = Map.reject(state, fn {_key, {_count, _started, expires}} -> expires <= now end)
    entry_key = {bucket, :crypto.hash(:sha256, :erlang.term_to_binary(key))}
    existing? = Map.has_key?(state, entry_key)

    if not existing? and map_size(state) >= @capacity do
      {:reply, false, state}
    else
      {count, started, _expires} = Map.get(state, entry_key, {0, now, now + window_seconds})
      {count, started} = if now - started >= window_seconds, do: {0, now}, else: {count, started}
      allowed = count < limit

      next =
        if allowed,
          do: Map.put(state, entry_key, {count + 1, started, started + window_seconds}),
          else: state

      {:reply, allowed, next}
    end
  end

  def handle_call(:size, _from, state), do: {:reply, map_size(state), state}
end
