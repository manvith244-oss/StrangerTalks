# filepath: lib/strangertalks_new/queue/time_fixture.ex
defmodule StrangertalksNew.Queue.TimeFixture do
  @moduledoc """
  Monotonic clock utility ensuring drift-resistant queue calculations.
  """

  @spec current_monotonic_ms() :: integer()
  def current_monotonic_ms, do: :erlang.monotonic_time(:millisecond)

  @spec calculate_elapsed_seconds(integer()) :: integer()
  def calculate_elapsed_seconds(start_monotonic_ms) do
    elapsed_ms = current_monotonic_ms() - start_monotonic_ms
    max(0, div(elapsed_ms, 1000))
  end
end
