defmodule StrangertalksNew.GoogleContinuity.RateLimiter do
  @moduledoc "Compatibility facade for the canonical single-node limiter."

  def allow?(bucket, key, limit, window_seconds),
    do: StrangertalksNew.RateLimiter.allow?(bucket, key, limit, window_seconds)

  defdelegate size(), to: StrangertalksNew.RateLimiter
end
