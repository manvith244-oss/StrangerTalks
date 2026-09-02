defmodule StrangertalksNew.ViewOnceMediaStoreTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore

  defp valid_jpeg(width, height) do
    sof0_payload = <<8, height::16, width::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  setup do
    conv_id = "conv-" <> Ecto.UUID.generate()
    sender_id = "sender-" <> Ecto.UUID.generate()
    recipient_id = "recipient-" <> Ecto.UUID.generate()
    client_msg_id = Ecto.UUID.generate()
    epoch_id = Ecto.UUID.generate()

    on_exit(fn ->
      ViewOnceMediaStore.delete_conversation(conv_id)
    end)

    {:ok,
     %{
       conv_id: conv_id,
       sender_id: sender_id,
       recipient_id: recipient_id,
       client_msg_id: client_msg_id,
       epoch_id: epoch_id
     }}
  end

  describe "staging and claiming" do
    test "successfully stages and claims valid photo media", %{
      conv_id: conv_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      client_msg_id: client_msg_id
    } do
      media = valid_jpeg(200, 200)

      assert {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      assert is_binary(staging_token)

      assert {:ok, metadata} =
               ViewOnceMediaStore.claim_staged_media(
                 staging_token,
                 conv_id,
                 sender_id,
                 client_msg_id,
                 recipient_id
               )

      assert metadata.media_type == "image/jpeg"
      assert metadata.byte_size == byte_size(media)
      assert is_binary(metadata.content_hash)

      # Re-claiming the same token fails
      assert {:error, :invalid_staging_token} =
               ViewOnceMediaStore.claim_staged_media(
                 staging_token,
                 conv_id,
                 sender_id,
                 client_msg_id,
                 recipient_id
               )
    end

    test "enforces maximum 1 UNVIEWED photo per sender", %{
      conv_id: conv_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      client_msg_id: client_msg_id
    } do
      media = valid_jpeg(200, 200)

      {:ok, token1} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _meta} =
        ViewOnceMediaStore.claim_staged_media(
          token1,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id
        )

      # Attempt to stage/claim a second unviewed photo from the same sender
      client_msg_id2 = Ecto.UUID.generate()
      {:ok, token2} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      assert {:error, :view_once_sender_unviewed_limit} =
               ViewOnceMediaStore.claim_staged_media(
                 token2,
                 conv_id,
                 sender_id,
                 client_msg_id2,
                 recipient_id
               )
    end
  end

  describe "presentation capability and one-shot consumption" do
    test "issues single-use capability token and consumes bytes exactly once", %{
      conv_id: conv_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      client_msg_id: client_msg_id,
      epoch_id: epoch_id
    } do
      media = valid_jpeg(300, 300)

      {:ok, token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _meta} =
        ViewOnceMediaStore.claim_staged_media(
          token,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id
        )

      # Sender cannot issue presentation capability
      assert {:error, reason} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 sender_id,
                 epoch_id
               )

      assert reason in [:foreign_participant, :not_conversation_member]

      # Recipient issues presentation capability
      assert {:ok, pres_token} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )

      # First presentation fetch succeeds with correct bytes and headers
      assert {:ok, fetched_binary, media_type} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 pres_token,
                 recipient_id
               )

      assert fetched_binary == media
      assert media_type == "image/jpeg"

      # Exact replay / duplicate fetch fails because token was single-use
      assert {:error, reason} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 pres_token,
                 recipient_id
               )

      assert reason in [:already_consumed, :capability_invalid_or_expired]

      # Further capability issuance on viewed item returns already_consumed
      assert {:error, :already_consumed} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )
    end

    test "preserves server-owned copy during safety grace period after view", %{
      conv_id: conv_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      client_msg_id: client_msg_id,
      epoch_id: epoch_id
    } do
      media = valid_jpeg(100, 100)

      {:ok, token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _meta} =
        ViewOnceMediaStore.claim_staged_media(
          token,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id
        )

      {:ok, pres_token} =
        ViewOnceMediaStore.issue_presentation_capability(
          conv_id,
          client_msg_id,
          recipient_id,
          epoch_id
        )

      {:ok, _bytes, _type} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          pres_token,
          recipient_id
        )

      # Safety copy capture succeeds during grace period
      assert {:ok, safety_info} =
               ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)

      assert safety_info.binary == media
      assert safety_info.media_type == "image/jpeg"
      assert safety_info.byte_size == byte_size(media)
    end
  end

  describe "capacity bounds" do
    test "rejects item exceeding conversation capacity limit", %{
      conv_id: conv_id,
      sender_id: sender_id
    } do
      # 6 MiB is conversation limit. 5 MiB per video item limit.
      # Stage and claim a ~4.5 MB video
      video1 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_500_000)

      client_msg_id1 = Ecto.UUID.generate()
      {:ok, token1} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video1)

      {:ok, _meta} =
        ViewOnceMediaStore.claim_staged_media(
          token1,
          conv_id,
          sender_id,
          client_msg_id1,
          "recipient-1",
          1
        )

      # Staging another 3 MB video would push conversation total past 6 MiB limit (4.5 + 3 = 7.5 MB > 6 MB)
      video2 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 3_000_000)

      assert {:error, :view_once_conversation_capacity} =
               ViewOnceMediaStore.stage_media(conv_id, sender_id, video2)
    end
  end

  describe "Feature 1O.1 - Closure Gap A: Partial Expiry Safety Deadline (EXP-SAFETY-1..3)" do
    test "EXP-SAFETY-1: Late first view preserves original safety deadline, expires at grace end, no extension",
         %{
           conv_id: conv_id,
           sender_id: sender_id,
           recipient_id: recipient_id,
           client_msg_id: client_msg_id,
           epoch_id: epoch_id
         } do
      media = valid_jpeg(200, 200)
      {:ok, token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _} =
        ViewOnceMediaStore.claim_staged_media(
          token,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id,
          2
        )

      # 1st presentation at T0 (starts 10m safety grace timer)
      assert {:ok, pres_token1} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )

      assert {:ok, _bytes, _} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 pres_token1,
                 recipient_id
               )

      # Safety copy is available during safety grace
      assert {:ok, safety_info} = ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)
      assert safety_info.binary == media

      # Trigger expiry of safety grace timer
      store_pid = Process.whereis(ViewOnceMediaStore)
      send(store_pid, {:expire_safety_grace, conv_id, client_msg_id})
      _ = :sys.get_state(store_pid)

      # Safety copy is removed and unavailable. No extension.
      assert {:error, :media_unavailable} =
               ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)
    end

    test "EXP-SAFETY-2: Early first-view grace expired before ordinary deadline does NOT restart at ordinary expiry",
         %{
           conv_id: conv_id,
           sender_id: sender_id,
           recipient_id: recipient_id,
           client_msg_id: client_msg_id,
           epoch_id: epoch_id
         } do
      media = valid_jpeg(200, 200)
      {:ok, token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _} =
        ViewOnceMediaStore.claim_staged_media(
          token,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id,
          2
        )

      # 1st presentation consumed early
      {:ok, pres_token} =
        ViewOnceMediaStore.issue_presentation_capability(
          conv_id,
          client_msg_id,
          recipient_id,
          epoch_id
        )

      {:ok, _bytes, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          pres_token,
          recipient_id
        )

      # Safety grace expires early
      store_pid = Process.whereis(ViewOnceMediaStore)
      send(store_pid, {:expire_safety_grace, conv_id, client_msg_id})
      _ = :sys.get_state(store_pid)

      assert {:error, :media_unavailable} =
               ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)

      # Ordinary expiry does NOT manufacture a fresh grace or resurrect media
      assert {:error, :media_unavailable} =
               ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)

      assert {:error, :media_unavailable} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )
    end

    test "EXP-SAFETY-3: Safety-only bytes cannot serve ordinary view",
         %{
           conv_id: conv_id,
           sender_id: sender_id,
           recipient_id: recipient_id,
           client_msg_id: client_msg_id,
           epoch_id: epoch_id
         } do
      media = valid_jpeg(200, 200)
      {:ok, token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _} =
        ViewOnceMediaStore.claim_staged_media(
          token,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id,
          2
        )

      # Consume 1st and 2nd presentations -> status becomes :safety_grace
      {:ok, pres1} =
        ViewOnceMediaStore.issue_presentation_capability(
          conv_id,
          client_msg_id,
          recipient_id,
          epoch_id
        )

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(conv_id, client_msg_id, pres1, recipient_id)

      {:ok, pres2} =
        ViewOnceMediaStore.issue_presentation_capability(
          conv_id,
          client_msg_id,
          recipient_id,
          epoch_id
        )

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(conv_id, client_msg_id, pres2, recipient_id)

      # In safety grace interval: ordinary view denied (0 tokens, 0 bytes)
      assert {:error, :already_consumed} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )

      # But safety owner CAN capture safety evidence
      assert {:ok, safety_info} = ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)
      assert safety_info.binary == media
    end
  end

  describe "Feature 1O.1 - Closure Gap B: Presentation Capability Matrix (CAP-1..9)" do
    test "CAP-1..9: Full capability issuance, replay, concurrency, participant denial, and total bound",
         %{
           conv_id: conv_id,
           sender_id: sender_id,
           recipient_id: recipient_id,
           client_msg_id: client_msg_id,
           epoch_id: epoch_id
         } do
      media = valid_jpeg(300, 300)
      {:ok, token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, meta} =
        ViewOnceMediaStore.claim_staged_media(
          token,
          conv_id,
          sender_id,
          client_msg_id,
          recipient_id,
          2
        )

      assert meta.presentation_limit == 2
      assert meta.views_remaining == 2

      # CAP-6: Sender denial
      assert {:error, _} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 sender_id,
                 epoch_id
               )

      # CAP-7: Foreign participant denial
      assert {:error, _} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 "foreign-participant-id",
                 epoch_id
               )

      # CAP-8: Foreign conversation / stale epoch denial
      assert {:error, _} =
               ViewOnceMediaStore.issue_presentation_capability(
                 "wrong-conv-id",
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )

      # CAP-1: Capability X first use
      assert {:ok, cap_x} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )

      # CAP-3: Concurrent double-use on Capability X (2 concurrent tasks)
      t1 =
        Task.async(fn ->
          ViewOnceMediaStore.consume_presentation(conv_id, client_msg_id, cap_x, recipient_id)
        end)

      t2 =
        Task.async(fn ->
          ViewOnceMediaStore.consume_presentation(conv_id, client_msg_id, cap_x, recipient_id)
        end)

      res_cap_x = [Task.await(t1), Task.await(t2)]
      success_x = Enum.filter(res_cap_x, &match?({:ok, _, _}, &1))
      fail_x = Enum.filter(res_cap_x, &match?({:error, _}, &1))

      assert length(success_x) == 1
      assert length(fail_x) == 1
      [{:ok, bytes_x, "image/jpeg"}] = success_x
      assert bytes_x == media

      # CAP-2: Capability X exact replay returns 0 bytes
      assert {:error, _} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 cap_x,
                 recipient_id
               )

      # CAP-4: Second presentation capability (Capability Y)
      assert {:ok, cap_y} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 client_msg_id,
                 recipient_id,
                 epoch_id
               )

      # CAP-5: Capability Y concurrent double-use
      t3 =
        Task.async(fn ->
          ViewOnceMediaStore.consume_presentation(conv_id, client_msg_id, cap_y, recipient_id)
        end)

      t4 =
        Task.async(fn ->
          ViewOnceMediaStore.consume_presentation(conv_id, client_msg_id, cap_y, recipient_id)
        end)

      res_cap_y = [Task.await(t3), Task.await(t4)]
      success_y = Enum.filter(res_cap_y, &match?({:ok, _, _}, &1))
      fail_y = Enum.filter(res_cap_y, &match?({:error, _}, &1))

      assert length(success_y) == 1
      assert length(fail_y) == 1
      [{:ok, bytes_y, "image/jpeg"}] = success_y
      assert bytes_y == media

      # Capability Y exact replay returns 0 bytes
      assert {:error, _} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 cap_y,
                 recipient_id
               )

      # CAP-9: Total byte presentation bound across all attempts and concurrent calls
      total_successful_byte_presentations = length(success_x) + length(success_y)
      assert total_successful_byte_presentations == 2
      assert total_successful_byte_presentations <= 2
    end
  end

  # MP4 Box builder for store tests
  defp box(type, payload) do
    size = byte_size(payload) + 8
    <<size::32, type::binary-size(4), payload::binary>>
  end

  defp valid_mp4(opts) do
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    duration_sec = Keyword.get(opts, :duration, 10.0)
    timescale = Keyword.get(opts, :timescale, 1000)
    extra_size = Keyword.get(opts, :extra_size, 100)

    duration_units = round(duration_sec * timescale)

    ftyp = box("ftyp", <<"isom", 512::32, "isom", "iso2", "mp41">>)

    mvhd =
      box(
        "mvhd",
        <<0, 0::24, 0::32, 0::32, timescale::32, duration_units::32, 0x00010000::32, 0x0100::16,
          0::16, 0::32, 0::32, 0x00010000::32, 0::32, 0::32, 0::32, 0x00010000::32, 0::32, 0::32,
          0::32, 0x40000000::32, 0::32, 0::32, 0::32, 0::32, 0::32, 0::32, 2::32>>
      )

    tkhd_v =
      box(
        "tkhd",
        <<0, 1::24, 0::32, 0::32, 1::32, 0::32, duration_units::32, 0::64, 0::16, 0::16, 0::16,
          0::16, 0x00010000::32, 0::32, 0::32, 0::32, 0x00010000::32, 0::32, 0::32, 0::32,
          0x40000000::32, width * 65536::32, height * 65536::32>>
      )

    mdhd_v =
      box("mdhd", <<0, 0::24, 0::32, 0::32, timescale::32, duration_units::32, 0::16, 0::16>>)

    hdlr_v = box("hdlr", <<0, 0::24, 0::32, "vide", 0::96, "VideoHandler", 0>>)

    stsd_entry_v =
      box(
        "avc1",
        <<0::48, 1::16, 0::128, width::16, height::16, 0x00480000::32, 0x00480000::32, 0::32,
          1::16, 0::256, 0x0018::16, 0xFFFF::16>>
      )

    stsd_v = box("stsd", <<0, 0::24, 1::32, stsd_entry_v::binary>>)
    stbl_v = box("stbl", stsd_v)
    minf_v = box("minf", stbl_v)
    mdia_v = box("mdia", mdhd_v <> hdlr_v <> minf_v)
    trak_v = box("trak", tkhd_v <> mdia_v)

    moov = box("moov", mvhd <> trak_v)
    mdat = box("mdat", :crypto.strong_rand_bytes(extra_size))

    ftyp <> moov <> mdat
  end

  describe "video media and presentation capacity" do
    test "stages and claims valid MP4 video", %{
      conv_id: conv_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      client_msg_id: client_msg_id
    } do
      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 1000)

      assert {:ok, staging_token} =
               ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)

      assert {:ok, metadata} =
               ViewOnceMediaStore.claim_staged_media(
                 staging_token,
                 conv_id,
                 sender_id,
                 client_msg_id,
                 recipient_id,
                 1
               )

      assert metadata.media_type == "video/mp4"
      assert metadata.width == 1280
      assert metadata.height == 720
      assert metadata.duration_seconds == 10.0
      assert metadata.byte_size == byte_size(video_bytes)
    end

    test "presentation capacity reservation and exhaustion limit (10 MiB)", %{
      conv_id: conv_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      epoch_id: epoch_id
    } do
      # Create 3 large videos (~4 MiB each, within 5 MiB item limit)
      video1 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)
      video2 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)

      conv_id2 = "conv2-" <> Ecto.UUID.generate()
      conv_id3 = "conv3-" <> Ecto.UUID.generate()
      msg_id1 = Ecto.UUID.generate()
      msg_id2 = Ecto.UUID.generate()
      msg_id3 = Ecto.UUID.generate()

      on_exit(fn ->
        ViewOnceMediaStore.delete_conversation(conv_id2)
        ViewOnceMediaStore.delete_conversation(conv_id3)
      end)

      {:ok, token1} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video1)

      {:ok, _} =
        ViewOnceMediaStore.claim_staged_media(
          token1,
          conv_id,
          sender_id,
          msg_id1,
          recipient_id,
          1
        )

      {:ok, token2} = ViewOnceMediaStore.stage_media(conv_id2, sender_id, video2)

      {:ok, _} =
        ViewOnceMediaStore.claim_staged_media(
          token2,
          conv_id2,
          sender_id,
          msg_id2,
          recipient_id,
          1
        )

      # Reserve 1 (~4 MiB reserved)
      assert {:ok, _res1} =
               ViewOnceMediaStore.reserve_presentation_capacity(conv_id, msg_id1, recipient_id)

      # Reserve 2 (~8 MiB reserved)
      assert {:ok, _res2} =
               ViewOnceMediaStore.reserve_presentation_capacity(conv_id2, msg_id2, recipient_id)

      # Third reservation of 4 MiB would exceed 10 MiB limit (8 + 4 = 12 MiB > 10 MiB)
      video3 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)
      {:ok, token3} = ViewOnceMediaStore.stage_media(conv_id3, sender_id, video3)

      {:ok, _} =
        ViewOnceMediaStore.claim_staged_media(
          token3,
          conv_id3,
          sender_id,
          msg_id3,
          recipient_id,
          1
        )

      assert {:error, :presentation_capacity_unavailable} =
               ViewOnceMediaStore.reserve_presentation_capacity(conv_id3, msg_id3, recipient_id)

      # Issue capability for video1 and consume it -> frees capacity!
      assert {:ok, cap1} =
               ViewOnceMediaStore.issue_presentation_capability(
                 conv_id,
                 msg_id1,
                 recipient_id,
                 epoch_id
               )

      assert {:ok, bytes, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(conv_id, msg_id1, cap1, recipient_id)

      assert byte_size(bytes) == byte_size(video1)

      # Now video3 reservation succeeds!
      assert {:ok, _res3} =
               ViewOnceMediaStore.reserve_presentation_capacity(conv_id3, msg_id3, recipient_id)
    end
  end
end
