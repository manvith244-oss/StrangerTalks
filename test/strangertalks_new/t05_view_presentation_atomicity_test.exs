defmodule StrangertalksNew.T05ViewPresentationAtomicityTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  defp unique(prefix), do: prefix <> "-" <> Ecto.UUID.generate()

  defp claim_media(presentation_limit \\ 1) do
    conversation_id = unique("t05-view-conv")
    sender_id = unique("sender")
    recipient_id = unique("recipient")
    client_message_id = Ecto.UUID.generate()
    media = valid_jpeg()

    {:ok, staging_token} = ViewOnceMediaStore.stage_media(conversation_id, sender_id, media)

    {:ok, _metadata} =
      ViewOnceMediaStore.claim_staged_media(
        staging_token,
        conversation_id,
        sender_id,
        client_message_id,
        recipient_id,
        presentation_limit
      )

    on_exit(fn -> ViewOnceMediaStore.delete_conversation(conversation_id) end)

    %{
      conversation_id: conversation_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      client_message_id: client_message_id,
      media: media,
      byte_size: byte_size(media)
    }
  end

  defp store_pid, do: Process.whereis(ViewOnceMediaStore)
  defp store_state, do: :sys.get_state(store_pid())

  defp media_entry(ctx) do
    Map.fetch!(store_state().media, {ctx.conversation_id, ctx.client_message_id})
  end

  defp expire(message) do
    send(store_pid(), message)
    _ = :sys.get_state(store_pid())
    :ok
  end

  test "T05-VIEW-002 B: reservation expiry releases accounting exactly once" do
    ctx = claim_media()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, reservation_token} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline + ctx.byte_size
    assert ViewOnceMediaStore.inspect_state().presentation_reservations_count == 1

    expire({:expire_reservation, reservation_token})

    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline
    assert ViewOnceMediaStore.inspect_state().presentation_reservations_count == 0

    expire({:expire_reservation, reservation_token})

    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline
    assert ViewOnceMediaStore.inspect_state().presentation_reservations_count == 0
  end

  test "T05-VIEW-002 C: repeated explicit reservation release is idempotent and cannot underflow" do
    ctx = claim_media()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, reservation_token} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_token)
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline

    assert :ok = ViewOnceMediaStore.release_presentation_reservation(reservation_token)
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline
    assert ViewOnceMediaStore.inspect_state().presentation_reservations_count == 0
  end

  test "T05-VIEW-002 D: reservation to capability transition replaces accounting exactly once" do
    ctx = claim_media()
    epoch_id = Ecto.UUID.generate()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, _reservation_token} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline + ctx.byte_size
    assert ViewOnceMediaStore.inspect_state().presentation_reservations_count == 1

    assert {:ok, capability_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    summary = ViewOnceMediaStore.inspect_state()
    assert summary.presentation_reserved_bytes == baseline + ctx.byte_size
    assert summary.presentation_reservations_count == 0
    assert summary.capabilities_count == 1
    assert is_binary(capability_token)
  end

  test "T05-VIEW-002 E/G: capability expiry releases bytes but does not restore an already committed view" do
    ctx = claim_media()
    epoch_id = Ecto.UUID.generate()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, _reservation_token} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert {:ok, capability_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    committed = media_entry(ctx)
    assert committed.views_remaining == 0
    assert committed.views_consumed == 1
    assert committed.status == :safety_grace

    expire({:expire_capability, capability_token})

    summary = ViewOnceMediaStore.inspect_state()
    assert summary.presentation_reserved_bytes == baseline
    assert summary.capabilities_count == 0

    after_expiry = media_entry(ctx)
    assert after_expiry.views_remaining == 0
    assert after_expiry.views_consumed == 1
    assert after_expiry.status == :safety_grace

    assert {:error, :capability_invalid_or_expired} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_token,
               ctx.recipient_id,
               epoch_id
             )

    expire({:expire_capability, capability_token})
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline
  end

  test "T05-VIEW-002 F: successful consume delivers exact bytes once and releases capability accounting once" do
    ctx = claim_media()
    epoch_id = Ecto.UUID.generate()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, _reservation_token} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert {:ok, capability_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    assert {:ok, bytes, "image/jpeg"} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_token,
               ctx.recipient_id,
               epoch_id
             )

    assert bytes == ctx.media

    summary = ViewOnceMediaStore.inspect_state()
    assert summary.presentation_reserved_bytes == baseline
    assert summary.capabilities_count == 0

    committed = media_entry(ctx)
    assert committed.views_remaining == 0
    assert committed.views_consumed == 1

    assert {:error, :capability_invalid_or_expired} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_token,
               ctx.recipient_id,
               epoch_id
             )
  end

  test "T05-VIEW-002 H: View Twice interrupted first delivery cannot create a third presentation" do
    ctx = claim_media(2)
    epoch_id = Ecto.UUID.generate()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, _reservation_1} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert {:ok, capability_1} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    first_commit = media_entry(ctx)
    assert first_commit.views_remaining == 1
    assert first_commit.views_consumed == 1
    assert first_commit.status == :partially_viewed

    expire({:expire_capability, capability_1})
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes == baseline

    assert {:ok, _reservation_2} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id
             )

    assert {:ok, capability_2} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    assert {:ok, bytes, "image/jpeg"} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_2,
               ctx.recipient_id,
               epoch_id
             )

    assert bytes == ctx.media

    final = media_entry(ctx)
    assert final.views_remaining == 0
    assert final.views_consumed == 2
    assert final.status == :safety_grace

    assert {:error, :already_consumed} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )
  end

  test "T05-VIEW-002 I: concurrent capability issuance allows only canonical remaining authority" do
    ctx = claim_media()
    epoch_id = Ecto.UUID.generate()

    task_1 =
      Task.async(fn ->
        ViewOnceMediaStore.issue_presentation_capability(
          ctx.conversation_id,
          ctx.client_message_id,
          ctx.recipient_id,
          epoch_id
        )
      end)

    task_2 =
      Task.async(fn ->
        ViewOnceMediaStore.issue_presentation_capability(
          ctx.conversation_id,
          ctx.client_message_id,
          ctx.recipient_id,
          epoch_id
        )
      end)

    results = [Task.await(task_1), Task.await(task_2)]

    assert length(Enum.filter(results, &match?({:ok, _}, &1))) == 1
    assert length(Enum.filter(results, &match?({:error, :already_consumed}, &1))) == 1

    committed = media_entry(ctx)
    assert committed.views_remaining == 0
    assert committed.views_consumed == 1
    assert ViewOnceMediaStore.inspect_state().capabilities_count == 1
  end

  test "T05-VIEW-002 J: stale epoch consume fails closed, destroys the token, and does not restore the committed view" do
    ctx = claim_media()
    issued_epoch = Ecto.UUID.generate()
    stale_epoch = Ecto.UUID.generate()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, capability_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               issued_epoch
             )

    assert {:error, :invalid_request} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_token,
               ctx.recipient_id,
               stale_epoch
             )

    summary = ViewOnceMediaStore.inspect_state()
    assert summary.presentation_reserved_bytes == baseline
    assert summary.capabilities_count == 0

    assert {:error, :capability_invalid_or_expired} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_token,
               ctx.recipient_id,
               issued_epoch
             )

    committed = media_entry(ctx)
    assert committed.views_remaining == 0
    assert committed.views_consumed == 1
  end

  test "T05-VIEW-002 K/L: safety grace starts at capability issuance and safety-only bytes cannot grant another ordinary view" do
    ctx = claim_media()
    epoch_id = Ecto.UUID.generate()

    before_issue = media_entry(ctx)
    assert before_issue.grace_timer_ref == nil
    assert before_issue.status == :unviewed

    assert {:ok, capability_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    after_issue = media_entry(ctx)
    assert is_reference(after_issue.grace_timer_ref)
    assert after_issue.status == :safety_grace
    assert after_issue.views_remaining == 0
    assert after_issue.views_consumed == 1

    assert {:ok, safety_copy} =
             ViewOnceMediaStore.capture_safety_media(ctx.conversation_id, ctx.client_message_id)

    assert safety_copy.binary == ctx.media

    assert {:error, :already_consumed} =
             ViewOnceMediaStore.issue_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               ctx.recipient_id,
               epoch_id
             )

    assert {:ok, bytes, "image/jpeg"} =
             ViewOnceMediaStore.consume_presentation_capability(
               ctx.conversation_id,
               ctx.client_message_id,
               capability_token,
               ctx.recipient_id,
               epoch_id
             )

    assert bytes == ctx.media
  end

  test "T05-VIEW-002 M: media deletion and conversation teardown recover reservation/capability capacity" do
    reservation_ctx = claim_media()
    capability_ctx = claim_media()
    epoch_id = Ecto.UUID.generate()
    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    assert {:ok, _reservation_token} =
             ViewOnceMediaStore.reserve_presentation_capacity(
               reservation_ctx.conversation_id,
               reservation_ctx.client_message_id,
               reservation_ctx.recipient_id
             )

    assert {:ok, capability_token} =
             ViewOnceMediaStore.issue_presentation_capability(
               capability_ctx.conversation_id,
               capability_ctx.client_message_id,
               capability_ctx.recipient_id,
               epoch_id
             )

    assert is_binary(capability_token)
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes ==
             baseline + reservation_ctx.byte_size + capability_ctx.byte_size

    assert :ok =
             ViewOnceMediaStore.delete_media(
               reservation_ctx.conversation_id,
               reservation_ctx.client_message_id
             )

    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes ==
             baseline + capability_ctx.byte_size

    assert :ok = ViewOnceMediaStore.delete_conversation(capability_ctx.conversation_id)

    summary = ViewOnceMediaStore.inspect_state()
    assert summary.presentation_reserved_bytes == baseline
    assert summary.presentation_reservations_count == 0
    assert summary.capabilities_count == 0
  end
end
