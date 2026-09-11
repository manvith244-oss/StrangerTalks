defmodule StrangertalksNew.Experiments.Hearth.TelemetryRecorderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias StrangertalksNew.Experiments.Hearth.TelemetryRecorder

  @room_id "0c9ac476-82c7-4af4-84f3-58aa8f543bde"
  @bridge_id "efdc86ee-027c-4ead-8053-414f040d75cb"

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      if pid = Process.whereis(TelemetryRecorder), do: GenServer.stop(pid)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "records only allowlisted structural room fields" do
    start_supervised!({TelemetryRecorder, name: TelemetryRecorder})

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute(
          [:strangertalks_new, :experiment, :hearth, :experiment_room_ended],
          %{count: 1, duration_ms: 12_345, turn_count: 14, monotonic_time: 9_999},
          %{
            variant: :treatment,
            reason: :explicit_leave,
            room_id: @room_id,
            participant_id: "must-not-leak",
            content: "raw chat must not leak",
            contribution: "raw hearth input must not leak"
          }
        )
      end)

    assert log =~ "HEARTH_EVENT"
    assert log =~ ~s("event":"experiment_room_ended")
    assert log =~ ~s("room_id":"#{@room_id}")
    assert log =~ ~s("variant":"treatment")
    assert log =~ ~s("reason":"explicit_leave")
    assert log =~ ~s("duration_ms":12345)
    assert log =~ ~s("turn_count":14)

    refute log =~ "must-not-leak"
    refute log =~ "raw chat"
    refute log =~ "raw hearth"
    refute log =~ "participant_id"
    refute log =~ "content"
    refute log =~ "contribution"
    refute log =~ "monotonic_time"
  end

  test "records bridge correlation without participant identifiers or payloads" do
    start_supervised!({TelemetryRecorder, name: TelemetryRecorder})

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute(
          [:strangertalks_new, :experiment, :hearth, :bridge_step_in],
          %{count: 1, monotonic_time: 100},
          %{
            variant: :treatment,
            bridge_id: @bridge_id,
            participant_id: "never-log-me",
            contribution: "Air fryer"
          }
        )
      end)

    assert log =~ ~s("event":"bridge_step_in")
    assert log =~ ~s("bridge_id":"#{@bridge_id}")
    refute log =~ "never-log-me"
    refute log =~ "Air fryer"
  end

  test "drops unknown events instead of becoming a generic telemetry logger" do
    start_supervised!({TelemetryRecorder, name: TelemetryRecorder})

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute(
          [:strangertalks_new, :experiment, :hearth, :future_payload_event],
          %{count: 1},
          %{content: "should never be logged"}
        )
      end)

    refute log =~ "HEARTH_EVENT"
    refute log =~ "should never be logged"
  end

  test "detaches its telemetry handler when stopped" do
    {:ok, pid} = TelemetryRecorder.start_link(name: TelemetryRecorder)
    GenServer.stop(pid)

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute(
          [:strangertalks_new, :experiment, :hearth, :experiment_room_ended],
          %{count: 1, duration_ms: 10, turn_count: 2},
          %{variant: :control, reason: :disconnect, room_id: @room_id}
        )
      end)

    refute log =~ "HEARTH_EVENT"
  end
end
