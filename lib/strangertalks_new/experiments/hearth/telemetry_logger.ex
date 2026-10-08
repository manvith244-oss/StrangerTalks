defmodule StrangertalksNew.Experiments.Hearth.TelemetryLogger do
  @moduledoc false

  use GenServer
  require Logger

  @handler_id "hearth-h01a-structural-telemetry"
  @prefix [:strangertalks_new, :experiment, :hearth]
  @events ~w(
    hearth_viewed
    experiment_assigned
    hearth_submitted
    bridge_offered
    bridge_step_in
    bridge_passed
    bridge_expired
    experiment_room_started
    experiment_turn
    experiment_first_message
    experiment_room_ended
    experiment_exit_reason
  )a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        Enum.map(@events, &(@prefix ++ [&1])),
        &__MODULE__.handle_event/4,
        nil
      )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  def handle_event(event, measurements, metadata, _config) do
    case safe_payload(List.last(event), measurements, metadata) do
      :drop -> :ok
      payload -> Logger.info("HEARTH_H01A_EVENT " <> Jason.encode!(payload))
    end
  end

  def safe_payload(event, measurements, metadata) when event in @events do
    %{
      event: Atom.to_string(event),
      measurements: safe_measurements(event, measurements),
      metadata: safe_metadata(event, metadata)
    }
  end

  def safe_payload(_event, _measurements, _metadata), do: :drop

  defp safe_measurements(event, measurements) do
    allowed =
      case event do
        :experiment_first_message -> [:count, :elapsed_ms]
        :experiment_room_ended -> [:count, :duration_ms, :turn_count]
        _ -> [:count]
      end

    take_allowed(measurements, allowed)
  end

  defp safe_metadata(event, metadata) do
    allowed =
      case event do
        :experiment_turn -> [:variant, :turn_number]
        :experiment_room_ended -> [:variant, :reason]
        :experiment_exit_reason -> [:variant, :reason]
        _ -> [:variant]
      end

    metadata
    |> take_allowed(allowed)
    |> Enum.into(%{}, fn {key, value} -> {key, normalize(value)} end)
  end

  defp take_allowed(values, allowed) when is_map(values) do
    Map.take(values, allowed)
  end

  defp take_allowed(_values, _allowed), do: %{}

  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_integer(value) or is_binary(value), do: value
  defp normalize(_value), do: nil
end
