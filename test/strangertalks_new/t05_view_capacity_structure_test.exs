defmodule StrangertalksNew.T05ViewCapacityStructureTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  defp claim(conversation_id, sender_id, recipient_id, presentation_limit \\ 1) do
    media = valid_jpeg()
    client_message_id = Ecto.UUID.generate()
    {:ok, staging_token} = ViewOnceMediaStore.stage_media(conversation_id, sender_id, media)

    assert {:ok, _metadata} =
             ViewOnceMediaStore.claim_staged_media(
               staging_token,
               conversation_id,
               sender_id,
               client_message_id,
               recipient_id,
               presentation_limit
             )

    %{conversation_id: conversation_id, client_message_id: client_message_id, bytes: byte_size(media)}
  end

  test "T05-VIEW-002 A: raw store reservations for the same media are additive but independently releasable" do
    conversation_id = "t05-dup-" <> Ecto.UUID.generate()
    sender_id = Ecto.UUID.generate()
    recipient_id = Ecto.UUID.generate()
    media = claim(conversation_id, sender_id, recipient_id)
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    on_exit(fn -> ViewOnceMediaStore.delete_conversation(conversation_id) end)

    assert {:ok, reservation_1} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               conversation_id,
               media.client_message_id,
               recipient_id
             )

    assert {:ok, reservation_2} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               conversation_id,
               media.client_message_id,
               recipient_id
             )

    refute reservation_1 == reservation_2
    summary = ViewOnceMediaStore.inspect_state()
    assert summary.presentation_reservations_count == 2
    assert summary.presentation_reserved_bytes == baseline + media.bytes * 2

    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_1)
    after_one = ViewOnceMediaStore.inspect_state()
    assert after_one.presentation_reservations_count == 1
    assert after_one.presentation_reserved_bytes == baseline + media.bytes

    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_2)
    final = ViewOnceMediaStore.inspect_state()
    assert final.presentation_reservations_count == 0
    assert final.presentation_reserved_bytes == baseline
  end

  test "T05-VIEW-002 abuse finding: one recipient can occupy the entire global reservation budget across distinct eligible media" do
    recipient_id = Ecto.UUID.generate()
    media_bytes = byte_size(valid_jpeg())
    previous_limit = Application.get_env(:strangertalks_new, :view_once_presentation_reservation_limit)
    Application.put_env(:strangertalks_new, :view_once_presentation_reservation_limit, media_bytes * 2)

    conversations = for n <- 1..3, do: "t05-fairness-#{n}-#{Ecto.UUID.generate()}"

    on_exit(fn ->
      Enum.each(conversations, &ViewOnceMediaStore.delete_conversation/1)

      if is_nil(previous_limit) do
        Application.delete_env(:strangertalks_new, :view_once_presentation_reservation_limit)
      else
        Application.put_env(
          :strangertalks_new,
          :view_once_presentation_reservation_limit,
          previous_limit
        )
      end
    end)

    [media_1, media_2, media_3] =
      Enum.map(conversations, fn conversation_id ->
        claim(conversation_id, Ecto.UUID.generate(), recipient_id)
      end)

    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, reservation_1} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               media_1.conversation_id,
               media_1.client_message_id,
               recipient_id
             )

    assert {:ok, reservation_2} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               media_2.conversation_id,
               media_2.client_message_id,
               recipient_id
             )

    assert {:error, :presentation_capacity_unavailable} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               media_3.conversation_id,
               media_3.client_message_id,
               recipient_id
             )

    full = ViewOnceMediaStore.inspect_state()
    assert full.presentation_reservations_count == 2
    assert full.presentation_reserved_bytes == baseline + media_bytes * 2

    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_1)

    assert {:ok, reservation_3} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               media_3.conversation_id,
               media_3.client_message_id,
               recipient_id
             )

    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_2)
    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_3)
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline
  end
end
