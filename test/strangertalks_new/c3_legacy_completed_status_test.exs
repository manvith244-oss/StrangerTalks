defmodule StrangertalksNew.C3LegacyCompletedStatusTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, Transitions}

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
end
