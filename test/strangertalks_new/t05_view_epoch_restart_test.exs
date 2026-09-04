defmodule StrangertalksNew.T05ViewEpochRestartTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  test "T05-VIEW-002 J: owner death destroys old-epoch capability and returns its capacity" do
    conversation_id = "t05-epoch-" <> Ecto.UUID.generate()
    sender_id = Ecto.UUID.generate()
    recipient_id = Ecto.UUID.generate()
    client_message_id = Ecto.UUID.generate()
    epoch_id = Ecto.UUID.generate()
    media = valid_jpeg()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      ViewOnceMediaStore.delete_conversation(conversation_id)
      if Process.alive?(owner), do: send(owner, :stop)
    end)

    assert :ok = ViewOnceMediaStore.register_owner(conversation_id, owner)

    {:ok, staging_token} =
      ViewOnceMediaStore.stage_media(conversation_id, sender_id, media)

    assert {:ok, _metadata} =
             ViewOnceMediaStore.claim_staged_media(
               staging_token,
               conversation_id,
               sender_id,
               client_message_id,
               recipient_id,
               1
             )

    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, presentation_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               conversation_id,
               client_message_id,
               recipient_id,
               epoch_id
             )

    before_down = ViewOnceMediaStore.inspect_state()
    assert before_down.capabilities_count == 1
    assert before_down.presentation_reserved_bytes == baseline + byte_size(media)

    store_pid = Process.whereis(ViewOnceMediaStore)
    store_state = :sys.get_state(store_pid)
    owner_ref = store_state.owners[conversation_id].ref

    send(store_pid, {:DOWN, owner_ref, :process, owner, :killed})
    _ = :sys.get_state(store_pid)

    after_down = ViewOnceMediaStore.inspect_state()
    assert after_down.capabilities_count == 0
    assert after_down.presentation_reservations_count == 0
    assert after_down.presentation_reserved_bytes == baseline
    assert ViewOnceMediaStore.has_media?(conversation_id, client_message_id) == false

    assert {:error, :capability_invalid_or_expired} =
             ViewOnceMediaStore.consume_presentation_capability(
               conversation_id,
               client_message_id,
               presentation_token,
               recipient_id,
               epoch_id
             )
  end
end
