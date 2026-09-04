defmodule StrangertalksNew.AIService.CircuitBreaker do
  @moduledoc false

  @failure_threshold 5
  @open_interval_ms 30_000

  @eligible MapSet.new([
              "AI_AUTH_FAILED",
              "AI_PROVIDER_UNAVAILABLE",
              "AI_PROVIDER_TIMEOUT",
              "AI_INTERNAL_ERROR",
              "AI_SERVICE_UNAVAILABLE",
              "AI_SERVICE_TIMEOUT",
              "AI_MALFORMED_RESPONSE"
            ])

  @type lease :: :closed | :half_open

  @spec failure_threshold() :: pos_integer()
  def failure_threshold, do: @failure_threshold

  @spec open_interval_ms() :: pos_integer()
  def open_interval_ms, do: @open_interval_ms

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    Agent.start_link(fn ->
      %{
        mode: :closed,
        failures: 0,
        opened_at_ms: nil,
        probe_in_flight: false,
        clock: clock
      }
    end)
  end

  @spec checkout(pid()) :: {:ok, lease()} | {:error, :open}
  def checkout(pid) do
    Agent.get_and_update(pid, fn state ->
      now = state.clock.()

      case state.mode do
        :closed ->
          {{:ok, :closed}, state}

        :open when now - state.opened_at_ms < @open_interval_ms ->
          {{:error, :open}, state}

        :open ->
          next = %{state | mode: :half_open, probe_in_flight: true}
          {{:ok, :half_open}, next}

        :half_open when state.probe_in_flight ->
          {{:error, :open}, state}
      end
    end)
  end

  @spec record_outcome(pid(), :success | {:error, String.t()}) :: :ok
  def record_outcome(pid, outcome) do
    Agent.update(pid, fn state -> transition(state, outcome) end)
  end

  @spec snapshot(pid()) :: map()
  def snapshot(pid), do: Agent.get(pid, &Map.drop(&1, [:clock]))

  defp transition(%{mode: :half_open} = state, :success), do: close(state)

  defp transition(%{mode: :half_open} = state, {:error, code}) do
    if eligible?(code), do: open(state), else: close(state)
  end

  defp transition(%{mode: :closed} = state, :success), do: %{state | failures: 0}

  defp transition(%{mode: :closed} = state, {:error, code}) do
    if eligible?(code) do
      failures = state.failures + 1

      if failures >= @failure_threshold do
        open(%{state | failures: failures})
      else
        %{state | failures: failures}
      end
    else
      %{state | failures: 0}
    end
  end

  defp transition(state, _outcome), do: state

  defp eligible?(code), do: MapSet.member?(@eligible, code)

  defp open(state) do
    %{
      state
      | mode: :open,
        failures: @failure_threshold,
        opened_at_ms: state.clock.(),
        probe_in_flight: false
    }
  end

  defp close(state) do
    %{state | mode: :closed, failures: 0, opened_at_ms: nil, probe_in_flight: false}
  end
end
