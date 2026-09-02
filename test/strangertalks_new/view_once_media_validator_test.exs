defmodule StrangertalksNew.ViewOnceMediaValidatorTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaValidator

  # JPEG with valid SOF0 (100x100), no Exif, EOI at end
  defp valid_jpeg(width \\ 100, height \\ 100) do
    sof0_payload = <<8, height::16, width::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  # JPEG with APP1 (Exif marker)
  defp exif_jpeg do
    exif_payload = <<"Exif", 0, 0, 1, 2, 3, 4>>
    exif_len = byte_size(exif_payload) + 2
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xE1, exif_len::16, exif_payload::binary, 0xFF, 0xC0, sof0_len::16,
      sof0_payload::binary, 0xFF, 0xD9>>
  end

  # PNG generator
  defp valid_png(width, height) do
    ihdr_data = <<width::32, height::32, 8, 2, 0, 0, 0>>
    ihdr_crc = :erlang.crc32("IHDR" <> ihdr_data)
    ihdr_chunk = <<13::32, "IHDR", ihdr_data::binary, ihdr_crc::32>>

    iend_crc = :erlang.crc32("IEND")
    iend_chunk = <<0::32, "IEND", iend_crc::32>>

    <<137, 80, 78, 71, 13, 10, 26, 10, ihdr_chunk::binary, iend_chunk::binary>>
  end

  # PNG with text metadata chunk
  defp text_chunk_png do
    ihdr_data = <<100::32, 100::32, 8, 2, 0, 0, 0>>
    ihdr_crc = :erlang.crc32("IHDR" <> ihdr_data)
    ihdr_chunk = <<13::32, "IHDR", ihdr_data::binary, ihdr_crc::32>>

    text_data = <<"Author", 0, "Stranger">>
    text_crc = :erlang.crc32("tEXt" <> text_data)
    text_chunk = <<byte_size(text_data)::32, "tEXt", text_data::binary, text_crc::32>>

    iend_crc = :erlang.crc32("IEND")
    iend_chunk = <<0::32, "IEND", iend_crc::32>>

    <<137, 80, 78, 71, 13, 10, 26, 10, ihdr_chunk::binary, text_chunk::binary,
      iend_chunk::binary>>
  end

  # WebP generator (VP8 lossy)
  defp valid_webp_vp8(width, height) do
    vp8_payload =
      <<0, 0, 0, 0x9D, 0x01, 0x2A, width::16-little, height::16-little, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0>>

    vp8_size = byte_size(vp8_payload)
    riff_payload = <<"WEBP", "VP8 ", vp8_size::32-little, vp8_payload::binary>>
    riff_size = byte_size(riff_payload)

    <<"RIFF", riff_size::32-little, riff_payload::binary>>
  end

  # MP4 Box builder
  defp box(type, payload) do
    size = byte_size(payload) + 8
    <<size::32, type::binary-size(4), payload::binary>>
  end

  defp valid_mp4(opts) do
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    duration_sec = Keyword.get(opts, :duration, 10.0)
    timescale = Keyword.get(opts, :timescale, 1000)
    video_codec = Keyword.get(opts, :video_codec, "avc1")
    audio_codec = Keyword.get(opts, :audio_codec, nil)
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

    # Video track
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
        video_codec,
        <<0::48, 1::16, 0::128, width::16, height::16, 0x00480000::32, 0x00480000::32, 0::32,
          1::16, 0::256, 0x0018::16, 0xFFFF::16>>
      )

    stsd_v = box("stsd", <<0, 0::24, 1::32, stsd_entry_v::binary>>)
    stbl_v = box("stbl", stsd_v)
    minf_v = box("minf", stbl_v)
    mdia_v = box("mdia", mdhd_v <> hdlr_v <> minf_v)
    trak_v = box("trak", tkhd_v <> mdia_v)

    audio_trak =
      if audio_codec do
        tkhd_a =
          box(
            "tkhd",
            <<0, 1::24, 0::32, 0::32, 2::32, 0::32, duration_units::32, 0::64, 0::16, 0::16,
              0::16, 0::16, 0x00010000::32, 0::32, 0::32, 0::32, 0x00010000::32, 0::32, 0::32,
              0::32, 0x40000000::32, 0::32, 0::32>>
          )

        mdhd_a =
          box("mdhd", <<0, 0::24, 0::32, 0::32, timescale::32, duration_units::32, 0::16, 0::16>>)

        hdlr_a = box("hdlr", <<0, 0::24, 0::32, "soun", 0::96, "SoundHandler", 0>>)

        stsd_entry_a =
          box(audio_codec, <<0::48, 1::16, 0::64, 2::16, 16::16, 0::32, 44100::16, 0::16>>)

        stsd_a = box("stsd", <<0, 0::24, 1::32, stsd_entry_a::binary>>)
        stbl_a = box("stbl", stsd_a)
        minf_a = box("minf", stbl_a)
        mdia_a = box("mdia", mdhd_a <> hdlr_a <> minf_a)
        box("trak", tkhd_a <> mdia_a)
      else
        <<>>
      end

    moov = box("moov", mvhd <> trak_v <> audio_trak)
    mdat = box("mdat", :crypto.strong_rand_bytes(extra_size))

    ftyp <> moov <> mdat
  end

  describe "validate_media/1" do
    test "accepts valid normalized JPEG within dimensions" do
      jpeg = valid_jpeg(800, 600)
      assert {:ok, metadata} = ViewOnceMediaValidator.validate_media(jpeg)
      assert metadata.media_type == "image/jpeg"
      assert metadata.width == 800
      assert metadata.height == 600
      assert metadata.byte_size == byte_size(jpeg)
      assert is_binary(metadata.content_hash)
    end

    test "rejects JPEG exceeding 2048x2048 dimension" do
      oversized = valid_jpeg(2049, 1000)

      assert {:error, :image_dimension_too_large} =
               ViewOnceMediaValidator.validate_media(oversized)
    end

    test "rejects JPEG with Exif APP1 metadata marker" do
      assert {:error, :metadata_normalization_violation} =
               ViewOnceMediaValidator.validate_media(exif_jpeg())
    end

    test "rejects JPEG with missing EOI marker" do
      truncated = binary_part(valid_jpeg(), 0, byte_size(valid_jpeg()) - 2)
      assert {:error, :malformed_image} = ViewOnceMediaValidator.validate_media(truncated)
    end

    test "accepts valid normalized PNG within dimensions" do
      png = valid_png(400, 300)
      assert {:ok, metadata} = ViewOnceMediaValidator.validate_media(png)
      assert metadata.media_type == "image/png"
      assert metadata.width == 400
      assert metadata.height == 300
    end

    test "rejects PNG exceeding 2048x2048 dimension" do
      oversized = valid_png(3000, 100)

      assert {:error, :image_dimension_too_large} =
               ViewOnceMediaValidator.validate_media(oversized)
    end

    test "rejects PNG containing metadata chunks (e.g. tEXt)" do
      assert {:error, :metadata_normalization_violation} =
               ViewOnceMediaValidator.validate_media(text_chunk_png())
    end

    test "accepts valid normalized WebP within dimensions" do
      webp = valid_webp_vp8(500, 500)
      assert {:ok, metadata} = ViewOnceMediaValidator.validate_media(webp)
      assert metadata.media_type == "image/webp"
      assert metadata.width == 500
      assert metadata.height == 500
    end

    test "rejects photo payload exceeding 1 MiB" do
      large_bin = :crypto.strong_rand_bytes(1_048_577)

      assert {:error, reason} = ViewOnceMediaValidator.validate_media(large_bin)
      assert reason in [:view_once_photo_too_large, :unsupported_media_type, :malformed_image]
    end

    test "rejects SVG, HTML, and scriptable content" do
      svg = "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"
      assert {:error, :malformed_image} = ViewOnceMediaValidator.validate_media(svg)

      html = "<html><body><script>alert(1)</script></body></html>"
      assert {:error, :malformed_image} = ViewOnceMediaValidator.validate_media(html)
    end

    test "rejects arbitrary malformed binaries" do
      assert {:error, reason} = ViewOnceMediaValidator.validate_media("not an image")
      assert reason in [:malformed_image, :unsupported_media_type]

      assert {:error, :malformed_image} = ViewOnceMediaValidator.validate_media("")
    end

    test "accepts valid H.264 MP4 video within 1280x720, <=15s, <=5 MiB" do
      mp4 = valid_mp4(width: 1280, height: 720, duration: 10.0, audio_codec: "mp4a")
      assert {:ok, metadata} = ViewOnceMediaValidator.validate_media(mp4)
      assert metadata.media_type == "video/mp4"
      assert metadata.width == 1280
      assert metadata.height == 720
      assert metadata.duration_seconds == 10.0
      assert metadata.byte_size == byte_size(mp4)
      assert is_binary(metadata.content_hash)
    end

    test "rejects video exceeding 1280x720 dimension" do
      oversized = valid_mp4(width: 1920, height: 1080)

      assert {:error, :video_dimension_too_large} =
               ViewOnceMediaValidator.validate_media(oversized)
    end

    test "rejects video exceeding 15.0s duration" do
      overlong = valid_mp4(duration: 15.5)
      assert {:error, :video_duration_too_long} = ViewOnceMediaValidator.validate_media(overlong)
    end

    test "rejects unsupported video codec (e.g. HEVC hev1 or vp09)" do
      hevc = valid_mp4(video_codec: "hev1")
      assert {:error, :unsupported_video_codec} = ViewOnceMediaValidator.validate_media(hevc)
    end

    test "rejects unsupported audio codec (e.g. ac-3)" do
      bad_audio = valid_mp4(audio_codec: "ac-3")
      assert {:error, :unsupported_audio_codec} = ViewOnceMediaValidator.validate_media(bad_audio)
    end

    test "rejects video exceeding 5 MiB" do
      # 5 MiB is 5_242_880 bytes
      oversized_video = valid_mp4(extra_size: 5_242_880 + 1000)

      assert {:error, :view_once_video_too_large} =
               ViewOnceMediaValidator.validate_media(oversized_video)
    end
  end
end
