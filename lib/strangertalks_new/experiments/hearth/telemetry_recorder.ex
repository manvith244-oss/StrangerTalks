defmodule StrangertalksNew.Experiments.Hearth.TelemetryRecorder do
  use GenServer

  require Logger

  @handler_id "strangertalks-hearth-h01a-structural-recorder"
  @prefix [:strangertalks_new, :experiment, :hearth]

  @event_specs %{
    hearth_viewed: %{measurements: [:count], metadata: [:variant]},
    experiment_assigned: %{measurements: [:count], metadata: [:variant]},
    hearth_submitted: %{measurements: [:count], metadata: [:variant]},
    bridge_offered: %{measurements: [:count], metadata: [:variant, :bridge_id]},
    bridge_step_in: %{measurements: [:count], metadata: [:variant, :bridge_id]},
    bridge_passed: %{measurements: [:count], metadata: [:variant, :bridge_id]},
    bridge_expired: %{measurements: [:count], metadata: [:variant, :bridge_id]},
    experiment_room_started: %{measurements: [:count], metadata: [:variant, :room_id]},
    experiment_first_message: %{
      measurements: [:count, :elapsed_ms],
      metadata: [:variant, :room_id]
    },
    experiment_turn: %{
      measurements: [:count],
      metadata: [:variant, :room_id, :turn_number]
    },
    experiment_room_ended: %{
      measurements: [:count, :duration_ms, :turn_count],
      metadata: [:variant, :room_id, :reason]
    },
    experiment_exit_reason: %{
      measurements: [:count],
      metadata: [:variant, :room_id, :reason]
    }
  }

  @events Enum.map(Map.keys(@event_specs), &(@prefix ++ [&1]))
  @variants ~w(control treatment)
  @room_end_reasons ~w(explicit_leave disconnect)
  @feedback_reasons ~w(ran_out one_sided good_chat uncomfortable passing_through)
  @reasons @room_end_reasons ++ @feedback_reasons

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def enabled? do
    Application.get_env(:strangertalks_new, :experiment_hearth_telemetry_enabled, false) == true or
      System.get_env("EXPERIMENT_HEARTH_TELEMETRY_ENABLED", "false") in ["true", "1"]
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> {:ok, %{handler_id: @handler_id}}
      {:error, :already_exists} -> {:stop, :telemetry_handler_already_attached}
    end
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  def handle_event(@prefix ++ [event], measurements, metadata, _config) do
    case Map.fetch(@event_specs, event) do
      {:ok, spec} ->
        payload =
          %{"event" => Atom.to_string(event)}
          |> put_allowlisted(spec.measurements, measurements)
          |> put_allowlisted(spec.metadata, metadata)

        Logger.info("HEARTH_EVENT " <> Jason.encode!(payload))

      :error ->
        :ok
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp put_allowlisted(payload, keys, source) do
    Enum.reduce(keys, payload, fn key, acc ->
      case sanitize(key, Map.get(source, key)) do
        {:ok, value} -> Map.put(acc, Atom.to_string(key), value)
        :drop -> acc
      end
    end)
  end

  defp sanitize(:variant, value) when value in [:control, :treatment],
    do: {:ok, Atom.to_string(value)}

  defp sanitize(:variant, value) when value in @variants, do: {:ok, value}

  defp sanitize(:reason, value) when is_atom(value),
    do: sanitize(:reason, Atom.to_string(value))

  defp sanitize(:reason, value) when value in @reasons, do: {:ok, value}

  defp sanitize(key, value) when key in [:room_id, :bridge_id] and is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :drop
    end
  end

  defp sanitize(key, value)
       when key in [:count, :elapsed_ms, :duration_ms, :turn_count, :turn_number] and
              is_integer(value) and value >= 0,
       do: {:ok, value}

  defp sanitize(_key, _value), do: :drop
end