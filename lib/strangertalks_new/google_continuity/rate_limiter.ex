defmodule StrangertalksNew.GoogleContinuity.RateLimiter do
  @moduledoc "Single-node V1 limiter; replace with shared enforcement before multi-node deployment."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def allow?(bucket, key, limit, window_seconds),
    do: GenServer.call(__MODULE__, {:allow, bucket, key, limit, window_seconds})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:allow, bucket, key, limit, window_seconds}, _from, state) do
    now = System.monotonic_time(:second)
    entry_key = {bucket, key}
    {count, started} = Map.get(state, entry_key, {0, now})
    {count, started} = if now - started >= window_seconds, do: {0, now}, else: {count, started}
    allowed = count < limit
    next = if allowed, do: Map.put(state, entry_key, {count + 1, started}), else: state
    {:reply, allowed, next}
  end
end
