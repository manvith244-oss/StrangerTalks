defmodule StrangertalksNew.C3LegacyCompletedStatusTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, Transitions}
  alias StrangertalksNew.RetentionCleanup

  @conversation_server_path "lib/strangertalks_new/conversation_lifecycle/conversation_server.ex"

  test "Conversation application authority rejects legacy COMPLETED" do
    changeset = Conversation.changeset(%Conversation{}, %{conversation_status: :COMPLETED})

    assert "is invalid" in errors_on(changeset).conversation_status
  end

  test "legacy COMPLETED is not a lifecycle terminal status" do
    refute Transitions.terminal?(:COMPLETED)
  end

  test "legacy COMPLETED does not release participant pairing reservations" do
    refute ConversationServer.release_terminal_status?(:COMPLETED)
  end

  test "ConversationServer startup terminal authority reuses canonical release statuses" do
    source = File.read!(@conversation_server_path)

    assert source =~ "when status in @release_terminal_statuses ->"
    refute source =~ "when status in [:ENDED, :ABANDONED, :FAILED, :COMPLETED] ->"
  end

  test "legacy COMPLETED is not terminal retention authority" do
    refute RetentionCleanup.terminal_conversation_expired?(
             :COMPLETED,
             ~U[2025-01-01 00:00:00Z],
             ~U[2026-09-10 00:00:00Z]
           )
  end
end
