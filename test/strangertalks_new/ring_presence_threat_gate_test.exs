defmodule StrangertalksNew.RingPresenceThreatGateTest do
  use ExUnit.Case, async: true

  @hangout_design "docs/hangouts-v1-design.md"
  @hangout_plan "docs/superpowers/plans/2026-09-10-hangouts-v1.md"
  @hangout_channel "lib/strangertalks_new_web/hangout_channel.ex"
  @ring_runtime "priv/static/assets/live_call.mjs"
  @app_runtime "priv/static/assets/app.js"
  @app_css "priv/static/assets/app.css"

  test "B1: Hangouts documentation and implementation agree that presence is lifecycle-derived, not client heartbeat authority" do
    design = File.read!(@hangout_design)
    plan = File.read!(@hangout_plan)
    channel = File.read!(@hangout_channel)

    refute design =~ "presence:heartbeat"
    refute plan =~ "presence:heartbeat"
    refute channel =~ "presence:heartbeat"

    assert design =~ "RoomServer.reconnect"
    assert design =~ "RoomServer.disconnect"
    assert design =~ "room:leave"
    assert design =~ "no client-authored presence event"

    assert channel =~ "RoomServer.reconnect(room_id, participant_id)"
    assert channel =~ "RoomServer.disconnect(room_id, socket.assigns.participant_id)"
    assert channel =~ ~s(handle_in("room:leave")
  end

  test "B3: Ring has no unwired audio-energy fingerprint surface" do
    ring = File.read!(@ring_runtime)
    app = File.read!(@app_runtime)
    css = File.read!(@app_css)

    for forbidden <- [
          "localEnergy",
          "peerEnergy",
          "--ring-local-energy",
          "--ring-peer-energy",
          "ring-state-self-speaking",
          "ring-state-peer-speaking"
        ] do
      refute ring =~ forbidden, "unwired Ring energy surface remains in live_call.mjs: #{forbidden}"
      refute app =~ forbidden, "unexpected production Ring energy producer exists in app.js: #{forbidden}"
      refute css =~ forbidden, "dead Ring energy styling remains in app.css: #{forbidden}"
    end
  end
end
