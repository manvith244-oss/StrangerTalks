defmodule StrangertalksNewWeb.ChannelCrashDiagnosticPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  @conversation_sentinel "SENTINEL-CONVERSATION-D4-7A9C"
  @participant_sentinel "SENTINEL-PARTICIPANT-D4-8B2D"
  @message_sentinel "SENTINEL-MESSAGE-D4-4E6F"
  @client_message_sentinel "SENTINEL-CLIENT-MESSAGE-D4-1C3A"
  @epoch_sentinel "SENTINEL-EPOCH-D4-5D7B"

  test "D4 real unhandled Phoenix Channel crash remains diagnosable without product identity or state" do
    Process.flag(:trap_exit, true)

    socket =
      socket(
        StrangertalksNewWeb.UserSocket,
        "participant_socket:#{@participant_sentinel}",
        %{
          participant_id: @participant_sentinel,
          conversation_id: @conversation_sentinel,
          message: @message_sentinel
        }
      )

    topic = "conversation:#{@conversation_sentinel}"

    assert {:ok, %{}, socket} =
             subscribe_and_join(socket, StrangertalksNewWeb.D4CrashChannel, topic, %{})

    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)

    retained_diagnostic =
      capture_log([level: :debug], fn ->
        push(socket, "d4:crash", %{
          "content" => @message_sentinel,
          "client_message_id" => @client_message_sentinel,
          "sequence" => 42,
          "epoch_id" => @epoch_sentinel
        })

        assert_receive {:DOWN, ^monitor, :process, _, reason}
        refute reason in [:normal, :shutdown]
      end)

    assert retained_diagnostic =~ "Phoenix Channel process crashed"
    assert retained_diagnostic =~ "Failure kind: error"
    assert retained_diagnostic =~ "Failure class: ArgumentError"
    assert retained_diagnostic =~ "D4CrashChannel.handle_in/3"

    forbidden_values = [
      @conversation_sentinel,
      @participant_sentinel,
      "participant_socket:#{@participant_sentinel}",
      topic,
      @message_sentinel,
      @client_message_sentinel,
      @epoch_sentinel
    ]

    Enum.each(forbidden_values, &refute(String.contains?(retained_diagnostic, &1)))

    forbidden_state_markers = [
      "client_message_id",
      "sequence",
      "epoch_id",
      "%Phoenix.Socket{",
      "assigns:",
      "transport_pid:",
      "Last message",
      "Process Label",
      "State:"
    ]

    Enum.each(forbidden_state_markers, &refute(String.contains?(retained_diagnostic, &1)))
  end
end
