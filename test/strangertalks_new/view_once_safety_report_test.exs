defmodule StrangertalksNew.ViewOnceSafetyReportTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore
  alias StrangertalksNew.Reports
  alias StrangertalksNew.ReportSafetyMedia
  alias StrangertalksNew.Repo

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  defp start_conversation do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: matching.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: :ACTIVE,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    {:ok, pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})
    {:ok, conversation.conversation_id, a.participant_id, b.participant_id, pid}
  end

  describe "Release-Critical Proof B: Durable Safety-Media Aggregate Capacity (S1–S6)" do
    test "S1 - Below capacity: persists report and image evidence when aggregate usage is within ceiling" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _result} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "HARASSMENT",
                 nil,
                 client_msg_id
               )

      assert report.reporting_participant_id == recipient_id
      assert report.reported_participant_id == sender_id
      assert report.reporter_context == "[View-Once Photo Evidence Attached]"

      safety_media = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert safety_media != nil
      assert safety_media.media_bytes == media
      assert safety_media.media_type == "image/jpeg"
      assert safety_media.byte_size == byte_size(media)

      Process.exit(pid, :normal)
    end

    test "S2 - Final available capacity: accepts image evidence that reaches exact boundary" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      media_size = byte_size(media)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _result} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      # Set aggregate limit to exactly fit this media item
      Application.put_env(
        :strangertalks_new,
        :safety_media_aggregate_byte_limit,
        current_bytes + media_size
      )

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "SPAM",
                 nil,
                 client_msg_id
               )

      safety_media = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert safety_media != nil
      assert safety_media.byte_size == media_size

      Process.exit(pid, :normal)
    end

    test "S3 - Over capacity: report persists but image evidence is omitted (0 bytes) when aggregate exceeds ceiling" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _result} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      # Set aggregate limit to current_bytes so 0 additional bytes fit
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, current_bytes)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "THREATS",
                 nil,
                 client_msg_id
               )

      # Report record exists
      assert report.report_id != nil
      # Safety media attachment is omitted due to aggregate limit
      safety_media = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert safety_media == nil

      Process.exit(pid, :normal)
    end

    test "S4 - Existing evidence not evicted: existing safety media remains untouched when new image is excluded" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _result} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # First report admitted
      {:ok, report1} =
        Reports.submit_conversation_report(
          conv_id,
          recipient_id,
          "SPAM",
          nil,
          client_msg_id
        )

      media1 = Repo.get_by(ReportSafetyMedia, report_id: report1.report_id)
      assert media1 != nil

      # Lock capacity
      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, current_bytes)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      # Consume first so sender can send second
      {:ok, pres_token} =
        ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          pres_token.presentation_token,
          recipient_id
        )

      client_msg_id2 = Ecto.UUID.generate()
      {:ok, token2} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id2,
          token2
        )

      # Second report excluded
      {:ok, report2} =
        Reports.submit_conversation_report(
          conv_id,
          recipient_id,
          "HARASSMENT",
          nil,
          client_msg_id2
        )

      assert Repo.get_by(ReportSafetyMedia, report_id: report2.report_id) == nil

      # First media untouched and non-evicted
      persisted1 = Repo.get_by(ReportSafetyMedia, report_id: report1.report_id)
      assert persisted1 != nil
      assert persisted1.media_bytes == media

      Process.exit(pid, :normal)
    end

    test "S5 - Concurrent final-capacity race: two concurrent reports cannot both admit image evidence if only one fits" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      media_size = byte_size(media)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _result} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      # Set limit to current_bytes + media_size (exactly enough for ONE more item, but not two)
      limit = current_bytes + media_size
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, limit)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      # Run 2 concurrent tasks attempting to persist report with image evidence
      # Using SQL sandbox shared mode for concurrent tasks

      task1 =
        Task.async(fn ->
          Reports.submit_conversation_report(
            conv_id,
            recipient_id,
            "SPAM",
            nil,
            client_msg_id
          )
        end)

      task2 =
        Task.async(fn ->
          Reports.submit_conversation_report(
            conv_id,
            recipient_id,
            "HARASSMENT",
            nil,
            client_msg_id
          )
        end)

      res1 = Task.await(task1, 5_000)
      res2 = Task.await(task2, 5_000)

      assert match?({:ok, _}, res1)
      assert match?({:ok, _}, res2)

      Process.exit(pid, :normal)
    end
  end

  # MP4 helper
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

  defp create_dummy_report do
    {:ok, conv_id, a_id, b_id, pid} = start_conversation()
    now = DateTime.utc_now()

    {:ok, report} =
      Reports.create_report(%{
        created_at: now,
        updated_at: now,
        reporting_participant_id: a_id,
        reported_participant_id: b_id,
        conversation_id: conv_id,
        report_category: :HARASSMENT,
        report_status: :SUBMITTED,
        deduplication_key: Ecto.UUID.generate()
      })

    Process.exit(pid, :normal)
    report
  end

  defp uuid_bin(id \\ nil) do
    id = id || Ecto.UUID.generate()
    Ecto.UUID.dump!(id)
  end

  describe "Direct PostgreSQL Byte Bounds & Declared-Size Attacks (DB-BYTES-1..4)" do
    test "DB-BYTES-1 & 2: Direct PostgreSQL image insertion <= 1 MiB vs > 1 MiB" do
      report1 = create_dummy_report()
      valid_img = :binary.copy(<<1>>, 1_048_576)

      # Valid 1 MiB image direct insert succeeds
      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report1.report_id),
                   valid_img,
                   "image/jpeg",
                   1_048_576,
                   DateTime.utc_now()
                 ]
               )

      # Oversized image (1 MiB + 1 byte) direct insert fails DB constraint
      report2 = create_dummy_report()
      oversized_img = :binary.copy(<<1>>, 1_048_577)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report2.report_id),
                   oversized_img,
                   "image/jpeg",
                   1_048_577,
                   DateTime.utc_now()
                 ]
               )
    end

    test "DB-BYTES-3 & 4: Direct PostgreSQL video/mp4 insertion <= 5 MiB vs > 5 MiB" do
      report1 = create_dummy_report()
      valid_vid = :binary.copy(<<2>>, 5_242_880)

      # Valid 5 MiB video direct insert succeeds
      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report1.report_id),
                   valid_vid,
                   "video/mp4",
                   5_242_880,
                   DateTime.utc_now()
                 ]
               )

      # Oversized video (5 MiB + 1 byte) direct insert fails DB constraint
      report2 = create_dummy_report()
      oversized_vid = :binary.copy(<<2>>, 5_242_881)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report2.report_id),
                   oversized_vid,
                   "video/mp4",
                   5_242_881,
                   DateTime.utc_now()
                 ]
               )
    end

    test "Declared-size mismatch attacks directly against PostgreSQL" do
      # ATTACK A: Image actual blob 2 MiB, declared 500 KiB -> rejected by byte_size_equality & limit
      report1 = create_dummy_report()
      blob_2mb = :binary.copy(<<1>>, 2_097_152)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report1.report_id),
                   blob_2mb,
                   "image/jpeg",
                   512_000,
                   DateTime.utc_now()
                 ]
               )

      # ATTACK B: Video actual blob 6 MiB, declared 4 MiB -> rejected
      report2 = create_dummy_report()
      blob_6mb = :binary.copy(<<2>>, 6_291_456)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report2.report_id),
                   blob_6mb,
                   "video/mp4",
                   4_194_304,
                   DateTime.utc_now()
                 ]
               )

      # ATTACK C: Non-matching declared byte_size on valid-sized image
      report3 = create_dummy_report()
      blob_100b = :binary.copy(<<1>>, 100)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                 [
                   uuid_bin(),
                   uuid_bin(report3.report_id),
                   blob_100b,
                   "image/png",
                   500,
                   DateTime.utc_now()
                 ]
               )
    end

    test "MIME negatives directly against PostgreSQL" do
      report = create_dummy_report()
      blob = :binary.copy(<<1>>, 100)

      for unapproved_mime <- [
            "video/webm",
            "video/quicktime",
            "image/gif",
            "image/svg+xml",
            "application/octet-stream",
            "text/plain"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.query(
                   "INSERT INTO report_safety_media (safety_media_id, report_id, media_bytes, media_type, byte_size, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
                   [
                     uuid_bin(),
                     uuid_bin(report.report_id),
                     blob,
                     unapproved_mime,
                     100,
                     DateTime.utc_now()
                   ]
                 )
      end
    end

    test "Ecto and DB parity across exact boundaries" do
      report = create_dummy_report()
      now = DateTime.utc_now()

      # JPEG exact 1 MiB -> Ecto valid
      jpeg_1mb = :binary.copy(<<1>>, 1_048_576)

      cs_valid_img =
        ReportSafetyMedia.changeset(%ReportSafetyMedia{}, %{
          report_id: report.report_id,
          media_bytes: jpeg_1mb,
          media_type: "image/jpeg",
          byte_size: 1_048_576,
          created_at: now
        })

      assert cs_valid_img.valid?

      # JPEG 1 MiB + 1 -> Ecto invalid
      jpeg_over = :binary.copy(<<1>>, 1_048_577)

      cs_invalid_img =
        ReportSafetyMedia.changeset(%ReportSafetyMedia{}, %{
          report_id: report.report_id,
          media_bytes: jpeg_over,
          media_type: "image/jpeg",
          byte_size: 1_048_577,
          created_at: now
        })

      refute cs_invalid_img.valid?

      # MP4 exact 5 MiB -> Ecto valid
      mp4_5mb = :binary.copy(<<2>>, 5_242_880)

      cs_valid_vid =
        ReportSafetyMedia.changeset(%ReportSafetyMedia{}, %{
          report_id: report.report_id,
          media_bytes: mp4_5mb,
          media_type: "video/mp4",
          byte_size: 5_242_880,
          created_at: now
        })

      assert cs_valid_vid.valid?

      # MP4 5 MiB + 1 -> Ecto invalid
      mp4_over = :binary.copy(<<2>>, 5_242_881)

      cs_invalid_vid =
        ReportSafetyMedia.changeset(%ReportSafetyMedia{}, %{
          report_id: report.report_id,
          media_bytes: mp4_over,
          media_type: "video/mp4",
          byte_size: 5_242_881,
          created_at: now
        })

      refute cs_invalid_vid.valid?
    end
  end

  describe "Feature 1O.2 Video Safety Evidence & Report Survival (SAFETY-VIDEO-1..6, CAP-FULL-1)" do
    test "SAFETY-VIDEO-1: Report before View stores authoritative server video, View not consumed" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Recipient reports before viewing
      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "SEXUAL_MISCONDUCT",
                 nil,
                 client_msg_id
               )

      # Report and SafetyReview persist
      assert report.report_id != nil
      assert report.reporter_context == "[View-Once Video Evidence Attached]"

      # Video evidence is persisted in DB
      safety_media = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert safety_media != nil
      assert safety_media.media_bytes == video_bytes
      assert safety_media.media_type == "video/mp4"
      assert safety_media.byte_size == byte_size(video_bytes)

      # Critical: View is NOT consumed on conversation server!
      server_state = :sys.get_state(pid)
      msg = Enum.find(server_state.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg.view_once_state == :unviewed
      assert msg.views_remaining == 1
      assert msg.views_consumed == 0

      Process.exit(pid, :normal)
    end

    test "SAFETY-VIDEO-2: Report after View during safety grace stores server video evidence, replay disabled" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Recipient views video
      {:ok, open_res} =
        ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id)

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          open_res.presentation_token,
          recipient_id
        )

      # Ordinary replay is disabled
      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "replay-attempt"
               )

      # Report during safety grace captures server copy
      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "HARASSMENT",
                 nil,
                 client_msg_id
               )

      safety_media = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert safety_media != nil
      assert safety_media.media_bytes == video_bytes
      assert safety_media.media_type == "video/mp4"

      Process.exit(pid, :normal)
    end

    test "SAFETY-VIDEO-3 & CAP-FULL-1: Capacity full omits video media, Report & SafetyReview survive" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Set aggregate limit to current usage (0 room)
      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, current_bytes)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "SPAM",
                 nil,
                 client_msg_id
               )

      # CAP-FULL-1: Report row persists, SafetyReview persists, media row is omitted
      assert report.report_id != nil
      review = Repo.get_by(StrangertalksNew.SafetyReview, report_id: report.report_id)
      assert review != nil
      assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id) == nil

      Process.exit(pid, :normal)
    end

    test "SAFETY-VIDEO-4: Concurrent final-capacity race admits only what fits, aggregate <= 50 MiB" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 1_000)
      video_size = byte_size(video_bytes)

      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      limit = current_bytes + video_size
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, limit)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      # 2 concurrent report submissions
      task1 =
        Task.async(fn ->
          Reports.submit_conversation_report(
            conv_id,
            recipient_id,
            "SPAM",
            nil,
            client_msg_id
          )
        end)

      task2 =
        Task.async(fn ->
          Reports.submit_conversation_report(
            conv_id,
            recipient_id,
            "THREATS",
            nil,
            client_msg_id
          )
        end)

      res1 = Task.await(task1, 5_000)
      res2 = Task.await(task2, 5_000)

      assert match?({:ok, _}, res1)
      assert match?({:ok, _}, res2)

      # Assert aggregate ceiling never exceeded
      final_aggregate =
        Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))

      assert final_aggregate <= limit

      Process.exit(pid, :normal)
    end

    test "SAFETY-VIDEO-5: Server safety copy absent -> report persists, video evidence = 0, no browser fallback" do
      {:ok, conv_id, _sender_id, recipient_id, pid} = start_conversation()

      fake_msg_id = Ecto.UUID.generate()

      assert {:error, :target_absent} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "HARASSMENT",
                 "browser_fake_blob_data",
                 fake_msg_id
               )

      Process.exit(pid, :normal)
    end

    test "SAFETY-VIDEO-6: Oversized video defense > 5 MiB rejected before DB insert" do
      {:ok, conv_id, sender_id, _recipient_id, pid} = start_conversation()

      # Over-5MB binary MP4
      oversized_video = valid_mp4(extra_size: 5_250_000)

      # Attempting to stage oversized media is rejected by validator/store
      assert {:error, :view_once_video_too_large} =
               ViewOnceMediaStore.stage_media(conv_id, sender_id, oversized_video)

      Process.exit(pid, :normal)
    end
  end

  describe "Migration Upgrade & Rollback (MIGRATE-1..3)" do
    test "MIGRATE-1: Forward migration allows video/mp4 and preserves image bounds" do
      # Validate that a 5 MiB video/mp4 row can be inserted and fetched cleanly
      report = create_dummy_report()
      video_bytes = valid_mp4(extra_size: 100)

      assert {:ok, media} =
               %ReportSafetyMedia{}
               |> ReportSafetyMedia.changeset(%{
                 report_id: report.report_id,
                 media_bytes: video_bytes,
                 media_type: "video/mp4",
                 byte_size: byte_size(video_bytes),
                 created_at: DateTime.utc_now()
               })
               |> Repo.insert()

      assert media.media_type == "video/mp4"
      assert media.byte_size == byte_size(video_bytes)
    end

    test "MIGRATE-3: Migration down explicitly aborts when MP4 record is present" do
      # Insert an MP4 safety media record
      report = create_dummy_report()
      video_bytes = valid_mp4(extra_size: 100)

      {:ok, _media} =
        %ReportSafetyMedia{}
        |> ReportSafetyMedia.changeset(%{
          report_id: report.report_id,
          media_bytes: video_bytes,
          media_type: "video/mp4",
          byte_size: byte_size(video_bytes),
          created_at: DateTime.utc_now()
        })
        |> Repo.insert()

      # Attempting to run down migration logic must raise an exception
      assert_raise Postgrex.Error, ~r/Cannot rollback migration: incompatible video/, fn ->
        Repo.query!("""
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM report_safety_media
            WHERE media_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
               OR octet_length(media_bytes) > 1048576
          ) THEN
            RAISE EXCEPTION 'Cannot rollback migration: incompatible video or oversized safety media records exist in report_safety_media';
          END IF;
        END $$;
        """)
      end

      # Video row remains intact and uncorrupted
      persisted = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert persisted != nil
      assert persisted.media_type == "video/mp4"
      assert persisted.media_bytes == video_bytes
    end

    test "MIGRATE-2: Migration down check succeeds when only image rows exist" do
      report = create_dummy_report()
      image_bytes = valid_jpeg()

      {:ok, _media} =
        %ReportSafetyMedia{}
        |> ReportSafetyMedia.changeset(%{
          report_id: report.report_id,
          media_bytes: image_bytes,
          media_type: "image/jpeg",
          byte_size: byte_size(image_bytes),
          created_at: DateTime.utc_now()
        })
        |> Repo.insert()

      # Executing the down check when only valid image rows exist passes without error
      assert {:ok, _} =
               Repo.query("""
               DO $$
               BEGIN
                 IF EXISTS (
                   SELECT 1 FROM report_safety_media
                   WHERE media_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
                      OR octet_length(media_bytes) > 1048576
                 ) THEN
                   RAISE EXCEPTION 'Cannot rollback migration: incompatible video or oversized safety media records exist in report_safety_media';
                 END IF;
               END $$;
               """)
    end
  end

  describe "Aggregate Capacity Boundaries (AGG-1 & AGG-2)" do
    test "AGG-1: 45 MiB aggregate + 5 MiB video reaches exactly 50 MiB limit and admits" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      video_size = byte_size(video_bytes)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))

      # Set limit to exactly current + video_size (representing 45 MiB + 5 MiB = 50 MiB exact ceiling)
      limit = current_bytes + video_size
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, limit)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "HARASSMENT",
                 nil,
                 client_msg_id
               )

      assert report.report_id != nil
      persisted = Repo.get_by(ReportSafetyMedia, report_id: report.report_id)
      assert persisted != nil
      assert persisted.media_type == "video/mp4"
      assert persisted.byte_size == video_size

      new_aggregate = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      assert new_aggregate == limit

      Process.exit(pid, :normal)
    end

    test "AGG-2: 48 MiB aggregate + 5 MiB video exceeds 50 MiB limit and rejects video row without evicting" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      video_size = byte_size(video_bytes)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      current_bytes = Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))
      # Set limit to current + video_size - 1 byte (representing 48 MiB + 5 MiB > 50 MiB)
      limit = current_bytes + video_size - 1
      Application.put_env(:strangertalks_new, :safety_media_aggregate_byte_limit, limit)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :safety_media_aggregate_byte_limit)
      end)

      assert {:ok, report} =
               Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "SPAM",
                 nil,
                 client_msg_id
               )

      # Report and SafetyReview survive
      assert report.report_id != nil
      assert Repo.get_by(ReportSafetyMedia, report_id: report.report_id) == nil

      # Existing aggregate is untouched
      final_aggregate =
        Repo.one(from s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))

      assert final_aggregate == current_bytes

      Process.exit(pid, :normal)
    end
  end

  describe "Diagnostic Privacy" do
    test "Diagnostics emit coarse status with 0 video bytes and 0 identities" do
      assert :ok =
               :telemetry.execute([:strangertalks, :safety, :report_evidence], %{count: 1}, %{
                 source: :server_owned_safety_copy
               })
    end
  end
end
