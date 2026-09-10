defmodule StrangertalksNew.RingPresenceThreatGateTest do
  use ExUnit.Case, async: true

  @hangout_design "docs/hangouts-v1-design.md"
  @hangout_plan "docs/superpowers/plans/2026-09-10-hangouts-v1.md"
  @hangout_channel "lib/strangertalks_new_web/hangout_channel.ex"
  @ring_runtime "priv/static/assets/live_call.mjs"
  @app_runtime "priv/static/assets/app.js"
  @conversation_channel "lib/strangertalks_new_web/conversation_channel.ex"
  @conversation_server "lib/strangertalks_new/conversation_lifecycle/conversation_server.ex"

  test "B1: Hangouts documentation and implementation agree that presence is lifecycle-derived, not client heartbeat authority" do
    design = File.read!(@hangout_design)
    plan = File.read!(@hangout_plan)
    channel = File.read!(@hangout_channel)

    refute design =~ "presence:heartbeat"
    refute plan =~ "presence:heartbeat"
    refute plan =~ "heartbeat/2"
    refute channel =~ "presence:heartbeat"

    assert design =~ "RoomServer.reconnect"
    assert design =~ "RoomServer.disconnect"
    assert design =~ "room:leave"
    assert design =~ "no client-authored presence event"

    assert channel =~ "RoomServer.reconnect(room_id, participant_id)"
    assert channel =~ "RoomServer.disconnect(room_id, socket.assigns.participant_id)"
    assert channel =~ ~s(handle_in("room:leave")
  end

  test "B3: production Ring wiring has no audio-energy transport or producer" do
    ring = File.read!(@ring_runtime)
    app = File.read!(@app_runtime)
    channel = File.read!(@conversation_channel)
    server = File.read!(@conversation_server)

    # The Ring component still contains a dormant options seam from the historical
    # DELIGHT prototype. B3 closes on the threat-model's Option B: no production
    # measurement/transport/wiring exists. Any future wiring must change one of
    # these production owners and trip this gate for fresh security review.
    assert ring =~ "export class StrangerTalksRing"
    assert app =~ "ring?.update(state)"

    for forbidden <- ["localEnergy", "peerEnergy"] do
      refute app =~ forbidden,
             "production browser energy producer was added without B3 re-review: #{forbidden}"
    end

    for forbidden <- [
          "call:energy",
          "call:speaking",
          "audio_energy",
          "peer_energy",
          "local_energy"
        ] do
      refute channel =~ forbidden,
             "conversation channel gained Ring energy transport without B3 re-review: #{forbidden}"

      refute server =~ forbidden,
             "conversation authority gained Ring energy state without B3 re-review: #{forbidden}"
    end
  end
end
