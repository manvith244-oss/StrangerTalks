defmodule StrangertalksNew.TelemetryPrivacyTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Telemetry

  test "sanitizer strips content, identifiers and credentials while preserving bounded metadata" do
    sanitized =
      Telemetry.sanitize_metadata(%{
        content: "ordinary Conversation text",
        message: "raw message",
        participant_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        client_message_id: Ecto.UUID.generate(),
        report_evidence: "private report text",
        token: "secret-token",
        authorization: "Bearer secret",
        cookie: "session=secret",
        door_type: :EXPLORE,
        result: :success,
        sync_status: :ready
      })

    refute Map.has_key?(sanitized, :content)
    refute Map.has_key?(sanitized, :message)
    refute Map.has_key?(sanitized, :participant_id)
    refute Map.has_key?(sanitized, :conversation_id)
    refute Map.has_key?(sanitized, :client_message_id)
    refute Map.has_key?(sanitized, :token)
    refute Map.has_key?(sanitized, :authorization)
    refute Map.has_key?(sanitized, :cookie)

    assert sanitized.door_type == :EXPLORE
    assert sanitized.result == :success
    assert sanitized.sync_status == :ready
    assert sanitized.report_evidence == :redacted
  end

  test "all string values outside canonical reason codes are redacted" do
    assert Telemetry.sanitize_metadata(%{surface: "conversation"}) == %{surface: :redacted}
  end
end
