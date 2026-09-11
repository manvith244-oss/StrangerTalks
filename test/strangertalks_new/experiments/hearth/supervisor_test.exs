defmodule StrangertalksNew.Experiments.Hearth.SupervisorTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Experiments.Hearth.{Authority, Supervisor, TelemetryRecorder}

  setup do
    previous_app =
      Application.get_env(:strangertalks_new, :experiment_hearth_telemetry_enabled, :__missing__)

    previous_env = System.get_env("EXPERIMENT_HEARTH_TELEMETRY_ENABLED")
    System.delete_env("EXPERIMENT_HEARTH_TELEMETRY_ENABLED")

    on_exit(fn ->
      case previous_app do
        :__missing__ ->
          Application.delete_env(:strangertalks_new, :experiment_hearth_telemetry_enabled)

        value ->
          Application.put_env(:strangertalks_new, :experiment_hearth_telemetry_enabled, value)
      end

      case previous_env do
        nil -> System.delete_env("EXPERIMENT_HEARTH_TELEMETRY_ENABLED")
        value -> System.put_env("EXPERIMENT_HEARTH_TELEMETRY_ENABLED", value)
      end
    end)

    :ok
  end

  test "telemetry recorder is absent by default" do
    Application.put_env(:strangertalks_new, :experiment_hearth_telemetry_enabled, false)
    assert {:ok, {_flags, children}} = Supervisor.init([])

    ids = Enum.map(children, & &1.id)
    assert Authority in ids
    refute TelemetryRecorder in ids
  end

  test "telemetry recorder is supervised only when its separate flag is enabled" do
    Application.put_env(:strangertalks_new, :experiment_hearth_telemetry_enabled, true)
    assert {:ok, {_flags, children}} = Supervisor.init([])

    ids = Enum.map(children, & &1.id)
    assert Authority in ids
    assert TelemetryRecorder in ids
  end
end
