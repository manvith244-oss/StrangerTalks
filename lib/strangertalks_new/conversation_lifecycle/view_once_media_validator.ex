defmodule StrangertalksNew.ConversationLifecycle.ViewOnceMediaValidator do
  @moduledoc """
  Authoritative, bounded binary validator for View-Once still photos.

  Enforces:
  - Canonical format: JPEG, PNG, WebP only
  - Canonical maximum size: 1 MiB (1,048,576 bytes)
  - Canonical maximum dimensions: 2048 × 2048
  - Metadata-normalized privacy contract: rejects un-normalized camera metadata (Exif, XMP)
  - Scriptable / foreign container rejection: rejects HTML, SVG, GIF, executables, corrupted files
  """

  import Bitwise

  @max_photo_size 1_048_576
  @max_photo_dimension 2048
  @max_dimension 2048

  @max_video_size 5_242_880
  @max_video_duration 15.0
  @max_video_width 1280
  @max_video_height 720

  def max_byte_size, do: @max_video_size
  def max_photo_byte_size, do: @max_photo_size
  def max_video_byte_size, do: @max_video_size
  def max_dimension, do: @max_photo_dimension
  def max_video_width, do: @max_video_width
  def max_video_height, do: @max_video_height
  def max_video_duration, do: @max_video_duration

  @doc """
  Validates a binary media (photo or video) for View-Once acceptance.
  Returns `{:ok, metadata}` where metadata contains:
  - `:media_type` ("image/jpeg", "image/png", "image/webp", or "video/mp4")
  - `:width` (integer)
  - `:height` (integer)
  - `:duration_seconds` (float, for video)
  - `:byte_size` (integer)
  - `:content_hash` (sha256 binary)
  """
  def validate_media(binary), do: validate(binary)

  def validate(binary) when is_binary(binary) do
    size = byte_size(binary)

    cond do
      size == 0 ->
        {:error, :malformed_image}

      scriptable_payload?(binary) ->
        {:error, :malformed_image}

      true ->
        inspect_media(binary, size)
    end
  end

  def validate(_other), do: {:error, :invalid_body}

  def validate_video(binary) when is_binary(binary) do
    size = byte_size(binary)

    cond do
      size == 0 ->
        {:error, :malformed_video}

      size > @max_video_size ->
        {:error, :view_once_video_too_large}

      scriptable_payload?(binary) ->
        {:error, :malformed_video}

      true ->
        case inspect_video(binary, size) do
          {:ok, meta} -> {:ok, meta}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate_video(_other), do: {:error, :invalid_body}

  defp scriptable_payload?(binary) do
    prefix = binary |> binary_part(0, min(1024, byte_size(binary))) |> String.downcase()

    String.contains?(prefix, ["<svg", "<?xml", "<!doctype html", "<html", "<script"]) or
      String.starts_with?(prefix, ["gif87a", "gif89a"])
  end

  defp inspect_media(<<_len::32, "ftyp", _rest::binary>> = binary, size) do
    inspect_video(binary, size)
  end

  defp inspect_media(binary, size) do
    if size > @max_photo_size do
      {:error, :view_once_photo_too_large}
    else
      inspect_image(binary, size)
    end
  end

  defp inspect_video(binary, size) do
    if size > @max_video_size do
      {:error, :view_once_video_too_large}
    else
      case parse_mp4(binary) do
        {:ok, video_info} ->
          {:ok,
           %{
             media_type: "video/mp4",
             width: video_info.width,
             height: video_info.height,
             duration_seconds: video_info.duration_seconds,
             byte_size: size,
             content_hash: :crypto.hash(:sha256, binary)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp inspect_image(<<0xFF, 0xD8, _rest::binary>> = binary, size) do
    case validate_jpeg(binary) do
      {:ok, width, height} ->
        {:ok,
         %{
           media_type: "image/jpeg",
           width: width,
           height: height,
           byte_size: size,
           content_hash: :crypto.hash(:sha256, binary)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_image(
         <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, rest::binary>> = binary,
         size
       ) do
    case validate_png(rest) do
      {:ok, width, height} ->
        {:ok,
         %{
           media_type: "image/png",
           width: width,
           height: height,
           byte_size: size,
           content_hash: :crypto.hash(:sha256, binary)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_image(<<"RIFF", _riff_size::little-32, "WEBP", rest::binary>> = binary, size) do
    case validate_webp(rest) do
      {:ok, width, height} ->
        {:ok,
         %{
           media_type: "image/webp",
           width: width,
           height: height,
           byte_size: size,
           content_hash: :crypto.hash(:sha256, binary)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_image(_binary, _size) do
    {:error, :unsupported_media_type}
  end

  # ============================================================================
  # MP4 VIDEO VALIDATION (H.264 / AAC / Duration <= 15s / Dims <= 1280x720)
  # ============================================================================

  defp parse_mp4(binary) do
    case parse_mp4_boxes(binary, %{ftyp: nil, moov: nil, mdat: false}) do
      {:ok, %{ftyp: ftyp, moov: moov, mdat: true}} when not is_nil(ftyp) and not is_nil(moov) ->
        with :ok <- validate_ftyp(ftyp),
             {:ok, video_info} <- inspect_moov(moov) do
          {:ok, video_info}
        end

      {:ok, %{mdat: false}} ->
        {:error, :malformed_video}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :malformed_video}
    end
  end

  defp parse_mp4_boxes(<<>>, acc), do: {:ok, acc}

  defp parse_mp4_boxes(<<1::32, type::binary-size(4), large_size::64, rest::binary>>, acc)
       when large_size >= 16 and byte_size(rest) >= large_size - 16 do
    payload_len = large_size - 16
    <<payload::binary-size(payload_len), next::binary>> = rest
    acc = record_box(acc, type, payload)
    parse_mp4_boxes(next, acc)
  end

  defp parse_mp4_boxes(<<size::32, type::binary-size(4), rest::binary>>, acc)
       when size >= 8 and byte_size(rest) >= size - 8 do
    payload_len = size - 8
    <<payload::binary-size(payload_len), next::binary>> = rest
    acc = record_box(acc, type, payload)
    parse_mp4_boxes(next, acc)
  end

  defp parse_mp4_boxes(<<size::32, _type::binary-size(4), _rest::binary>>, _acc)
       when size < 8 and size != 0 do
    {:error, :malformed_video}
  end

  defp parse_mp4_boxes(<<_other::binary>>, _acc) do
    {:error, :malformed_video}
  end

  defp record_box(acc, "ftyp", payload), do: Map.put(acc, :ftyp, payload)
  defp record_box(acc, "moov", payload), do: Map.put(acc, :moov, payload)
  defp record_box(acc, "mdat", _payload), do: Map.put(acc, :mdat, true)
  defp record_box(acc, _other, _payload), do: acc

  defp validate_ftyp(<<major_brand::binary-size(4), _minor_ver::32, compatible_brands::binary>>) do
    brands =
      for <<brand::binary-size(4) <- major_brand <> compatible_brands>>, do: brand

    mp4_brands = ["isom", "iso2", "avc1", "mp41", "mp42", "M4V ", "qt  ", "MSNV", "NDSC", "dash"]

    if Enum.any?(brands, &(&1 in mp4_brands)) do
      :ok
    else
      {:error, :unsupported_media_type}
    end
  end

  defp validate_ftyp(_), do: {:error, :malformed_video}

  defp inspect_moov(payload) do
    case parse_sub_boxes(payload) do
      {:ok, sub_boxes} ->
        mvhd = find_box(sub_boxes, "mvhd")
        traks = find_all_boxes(sub_boxes, "trak")

        with {:ok, duration_sec} <- parse_mvhd(mvhd),
             {:ok, video_meta} <- parse_traks(traks) do
          {:ok, Map.put(video_meta, :duration_seconds, duration_sec)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_mvhd(nil), do: {:error, :malformed_video}

  defp parse_mvhd(
         <<0::8, _flags::24, _creation::32, _mod::32, timescale::32, duration::32, _rest::binary>>
       ) do
    if timescale == 0 or duration == 0 do
      {:error, :malformed_video}
    else
      sec = duration / timescale
      if sec > @max_video_duration, do: {:error, :video_duration_too_long}, else: {:ok, sec}
    end
  end

  defp parse_mvhd(
         <<1::8, _flags::24, _creation::64, _mod::64, timescale::32, duration::64, _rest::binary>>
       ) do
    if timescale == 0 or duration == 0 do
      {:error, :malformed_video}
    else
      sec = duration / timescale
      if sec > @max_video_duration, do: {:error, :video_duration_too_long}, else: {:ok, sec}
    end
  end

  defp parse_mvhd(_), do: {:error, :malformed_video}

  defp parse_traks([]), do: {:error, :unsupported_media_type}

  defp parse_traks(traks) do
    Enum.reduce_while(traks, {:ok, nil}, fn trak_payload, {:ok, video_acc} ->
      case parse_trak(trak_payload) do
        {:ok, :video, info} ->
          if video_acc != nil do
            {:halt, {:error, :unsupported_media_type}}
          else
            {:cont, {:ok, info}}
          end

        {:ok, :audio, _info} ->
          {:cont, {:ok, video_acc}}

        {:ok, :other, _info} ->
          {:cont, {:ok, video_acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nil} -> {:error, :unsupported_media_type}
      {:ok, video_meta} -> {:ok, video_meta}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_trak(trak_payload) do
    case parse_sub_boxes(trak_payload) do
      {:ok, trak_boxes} ->
        mdia = find_box(trak_boxes, "mdia")
        if mdia, do: parse_mdia(mdia), else: {:error, :malformed_video}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_mdia(mdia_payload) do
    case parse_sub_boxes(mdia_payload) do
      {:ok, mdia_boxes} ->
        hdlr = find_box(mdia_boxes, "hdlr")
        minf = find_box(mdia_boxes, "minf")

        case hdlr do
          <<_ver_flags::32, _pre_def::32, "vide", _rest::binary>> ->
            parse_video_minf(minf)

          <<_ver_flags::32, _pre_def::32, "soun", _rest::binary>> ->
            parse_audio_minf(minf)

          _other ->
            {:ok, :other, %{}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_video_minf(nil), do: {:error, :malformed_video}

  defp parse_video_minf(minf_payload) do
    case parse_sub_boxes(minf_payload) do
      {:ok, minf_boxes} ->
        stbl = find_box(minf_boxes, "stbl")
        if stbl, do: parse_video_stbl(stbl), else: {:error, :malformed_video}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_video_stbl(stbl_payload) do
    case parse_sub_boxes(stbl_payload) do
      {:ok, stbl_boxes} ->
        stsd = find_box(stbl_boxes, "stsd")
        if stsd, do: parse_video_stsd(stsd), else: {:error, :malformed_video}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_video_stsd(<<_ver_flags::32, entry_count::32, rest::binary>>)
       when entry_count >= 1 do
    case rest do
      <<_entry_len::32, "avc1", _reserved::48, _data_ref::16, _pre_def::16, _reserved2::16,
        _pre_def2::96, width::16, height::16, _rest_entry::binary>> ->
        cond do
          width <= 0 or height <= 0 ->
            {:error, :malformed_video}

          width > @max_video_width or height > @max_video_height ->
            {:error, :video_dimension_too_large}

          true ->
            {:ok, :video, %{width: width, height: height}}
        end

      <<_entry_len::32, other_codec::binary-size(4), _rest_entry::binary>>
      when other_codec in ["hev1", "hvc1", "vp09", "vp08", "av01", "mp4v"] ->
        {:error, :unsupported_video_codec}

      <<_entry_len::32, _other::binary-size(4), _rest_entry::binary>> ->
        {:error, :unsupported_video_codec}

      _ ->
        {:error, :malformed_video}
    end
  end

  defp parse_video_stsd(_), do: {:error, :malformed_video}

  defp parse_audio_minf(nil), do: {:error, :malformed_video}

  defp parse_audio_minf(minf_payload) do
    case parse_sub_boxes(minf_payload) do
      {:ok, minf_boxes} ->
        stbl = find_box(minf_boxes, "stbl")
        if stbl, do: parse_audio_stbl(stbl), else: {:error, :malformed_video}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_audio_stbl(stbl_payload) do
    case parse_sub_boxes(stbl_payload) do
      {:ok, stbl_boxes} ->
        stsd = find_box(stbl_boxes, "stsd")
        if stsd, do: parse_audio_stsd(stsd), else: {:error, :malformed_video}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_audio_stsd(<<_ver_flags::32, entry_count::32, rest::binary>>)
       when entry_count >= 1 do
    case rest do
      <<_entry_len::32, "mp4a", _rest_entry::binary>> ->
        {:ok, :audio, %{codec: "mp4a"}}

      <<_entry_len::32, other_codec::binary-size(4), _rest_entry::binary>>
      when other_codec in ["ac-3", "ec-3", "opus", "samr", "sawb", "dts "] ->
        {:error, :unsupported_audio_codec}

      <<_entry_len::32, _other::binary-size(4), _rest_entry::binary>> ->
        {:error, :unsupported_audio_codec}

      _ ->
        {:error, :malformed_video}
    end
  end

  defp parse_audio_stsd(_), do: {:error, :malformed_video}

  defp parse_sub_boxes(binary), do: parse_sub_boxes(binary, [])

  defp parse_sub_boxes(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_sub_boxes(<<size::32, type::binary-size(4), rest::binary>>, acc)
       when size >= 8 and byte_size(rest) >= size - 8 do
    payload_len = size - 8
    <<payload::binary-size(payload_len), next::binary>> = rest
    parse_sub_boxes(next, [{type, payload} | acc])
  end

  defp parse_sub_boxes(<<1::32, type::binary-size(4), large_size::64, rest::binary>>, acc)
       when large_size >= 16 and byte_size(rest) >= large_size - 16 do
    payload_len = large_size - 16
    <<payload::binary-size(payload_len), next::binary>> = rest
    parse_sub_boxes(next, [{type, payload} | acc])
  end

  defp parse_sub_boxes(_other, _acc), do: {:error, :malformed_video}

  defp find_box(boxes, type) do
    case Enum.find(boxes, fn {t, _} -> t == type end) do
      {^type, payload} -> payload
      nil -> nil
    end
  end

  defp find_all_boxes(boxes, type) do
    for {t, payload} <- boxes, t == type, do: payload
  end

  # ============================================================================
  # JPEG VALIDATION
  # ============================================================================

  defp validate_jpeg(<<0xFF, 0xD8, rest::binary>>) do
    scan_jpeg_segments(rest, nil, false)
  end

  defp scan_jpeg_segments(<<>>, _dims, _seen_eoi), do: {:error, :malformed_image}

  # Fill byte 0xFF
  defp scan_jpeg_segments(<<0xFF, 0xFF, rest::binary>>, dims, seen_eoi) do
    scan_jpeg_segments(<<0xFF, rest::binary>>, dims, seen_eoi)
  end

  # Escaped 0xFF inside entropy data
  defp scan_jpeg_segments(<<0xFF, 0x00, rest::binary>>, dims, seen_eoi) do
    scan_jpeg_segments(rest, dims, seen_eoi)
  end

  # Restart markers RST0..RST7 (0xD0..0xD7) - standalone 2-byte markers
  defp scan_jpeg_segments(<<0xFF, marker, rest::binary>>, dims, seen_eoi)
       when marker in 0xD0..0xD7 do
    scan_jpeg_segments(rest, dims, seen_eoi)
  end

  # EOI marker 0xD9 (End of Image)
  defp scan_jpeg_segments(<<0xFF, 0xD9, _rest::binary>>, {width, height}, _seen_eoi) do
    if width <= @max_dimension and height <= @max_dimension and width > 0 and height > 0 do
      {:ok, width, height}
    else
      {:error, :image_dimension_too_large}
    end
  end

  defp scan_jpeg_segments(<<0xFF, 0xD9, _rest::binary>>, nil, _seen_eoi) do
    {:error, :malformed_image}
  end

  # APP1 marker 0xE1 - Exif / XMP metadata check
  defp scan_jpeg_segments(<<0xFF, 0xE1, len::16, data::binary>>, dims, seen_eoi)
       when len >= 2 and byte_size(data) >= len - 2 do
    payload_len = len - 2
    <<payload::binary-size(payload_len), rest::binary>> = data

    if String.starts_with?(payload, "Exif\0\0") or
         String.contains?(payload, ["http://ns.adobe.com/xap/1.0/", "<x:xmpmeta", "XMP"]) do
      {:error, :metadata_normalization_violation}
    else
      scan_jpeg_segments(rest, dims, seen_eoi)
    end
  end

  # APP2 marker 0xE2 - check for ICC / metadata if required, or skip
  defp scan_jpeg_segments(<<0xFF, 0xE2, len::16, data::binary>>, dims, seen_eoi)
       when len >= 2 and byte_size(data) >= len - 2 do
    payload_len = len - 2
    <<_payload::binary-size(payload_len), rest::binary>> = data
    scan_jpeg_segments(rest, dims, seen_eoi)
  end

  # SOF markers: 0xC0..0xC3, 0xC5..0xC7, 0xC9..0xCB, 0xCD..0xCF
  defp scan_jpeg_segments(<<0xFF, sof, len::16, data::binary>>, _dims, seen_eoi)
       when sof in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF] and
              len >= 8 and byte_size(data) >= len - 2 do
    payload_len = len - 2

    <<_prec::8, height::16, width::16, _num_comp::8, _rest_payload::binary>> =
      binary_part(data, 0, min(payload_len, 7))

    <<_payload::binary-size(payload_len), rest::binary>> = data

    if width > @max_dimension or height > @max_dimension do
      {:error, :image_dimension_too_large}
    else
      scan_jpeg_segments(rest, {width, height}, seen_eoi)
    end
  end

  # SOS marker 0xDA (Start of Scan) - entropy coded data follows until EOI
  defp scan_jpeg_segments(<<0xFF, 0xDA, len::16, data::binary>>, dims, seen_eoi)
       when len >= 2 and byte_size(data) >= len - 2 do
    payload_len = len - 2
    <<_payload::binary-size(payload_len), rest::binary>> = data
    find_jpeg_eoi(rest, dims, seen_eoi)
  end

  # Other markers with length
  defp scan_jpeg_segments(<<0xFF, _marker, len::16, data::binary>>, dims, seen_eoi)
       when len >= 2 and byte_size(data) >= len - 2 do
    payload_len = len - 2
    <<_payload::binary-size(payload_len), rest::binary>> = data
    scan_jpeg_segments(rest, dims, seen_eoi)
  end

  defp scan_jpeg_segments(_other, _dims, _seen_eoi) do
    {:error, :malformed_image}
  end

  defp find_jpeg_eoi(<<>>, _dims, _seen_eoi), do: {:error, :malformed_image}

  defp find_jpeg_eoi(<<0xFF, 0xD9, _rest::binary>>, {width, height}, _seen_eoi) do
    if width <= @max_dimension and height <= @max_dimension and width > 0 and height > 0 do
      {:ok, width, height}
    else
      {:error, :image_dimension_too_large}
    end
  end

  defp find_jpeg_eoi(<<0xFF, 0xD9, _rest::binary>>, nil, _seen_eoi),
    do: {:error, :malformed_image}

  defp find_jpeg_eoi(<<_byte::8, rest::binary>>, dims, seen_eoi) do
    find_jpeg_eoi(rest, dims, seen_eoi)
  end

  # ============================================================================
  # PNG VALIDATION
  # ============================================================================

  defp validate_png(
         <<13::32, "IHDR", width::32, height::32, _bit_depth::8, _color::8, _comp::8, _filter::8,
           _interlace::8, _crc::32, rest::binary>>
       ) do
    cond do
      width > @max_dimension or height > @max_dimension ->
        {:error, :image_dimension_too_large}

      width == 0 or height == 0 ->
        {:error, :malformed_image}

      true ->
        scan_png_chunks(rest, width, height)
    end
  end

  defp validate_png(_other), do: {:error, :malformed_image}

  defp scan_png_chunks(<<>>, _w, _h), do: {:error, :malformed_image}

  defp scan_png_chunks(<<length::32, type::binary-size(4), rest::binary>>, width, height)
       when byte_size(rest) >= length + 4 do
    <<_data::binary-size(length), _crc::32, next_chunks::binary>> = rest

    cond do
      type in ["eXIf", "tEXt", "zTXt", "iTXt"] ->
        {:error, :metadata_normalization_violation}

      type == "IEND" ->
        {:ok, width, height}

      true ->
        scan_png_chunks(next_chunks, width, height)
    end
  end

  defp scan_png_chunks(_other, _w, _h), do: {:error, :malformed_image}

  # ============================================================================
  # WEBP VALIDATION
  # ============================================================================

  # VP8 Lossy
  defp validate_webp(<<"VP8 ", chunk_size::little-32, rest::binary>>)
       when byte_size(rest) >= chunk_size and chunk_size >= 10 do
    case rest do
      <<_frame_tag::24, 0x9D, 0x01, 0x2A, width_raw::little-16, height_raw::little-16, _::binary>> ->
        width = width_raw &&& 0x3FFF
        height = height_raw &&& 0x3FFF

        cond do
          width == 0 or height == 0 ->
            {:error, :malformed_image}

          width > @max_dimension or height > @max_dimension ->
            {:error, :image_dimension_too_large}

          true ->
            {:ok, width, height}
        end

      _other ->
        {:error, :malformed_image}
    end
  end

  # VP8L Lossless
  defp validate_webp(
         <<"VP8L", chunk_size::little-32, 0x2F, b1::8, b2::8, b3::8, b4::8, _rest::binary>>
       )
       when chunk_size >= 5 do
    width = 1 + (b1 ||| (b2 &&& 0x3F) <<< 8)
    height = 1 + (b2 >>> 6 ||| b3 <<< 2 ||| (b4 &&& 0x0F) <<< 10)

    cond do
      width > @max_dimension or height > @max_dimension -> {:error, :image_dimension_too_large}
      width == 0 or height == 0 -> {:error, :malformed_image}
      true -> {:ok, width, height}
    end
  end

  # VP8X Extended
  defp validate_webp(
         <<"VP8X", chunk_size::little-32, flags::8, _reserved::24, canvas_w_minus_1::little-24,
           canvas_h_minus_1::little-24, _rest::binary>>
       )
       when chunk_size >= 10 do
    # Bit 3: EXIF, Bit 2: XMP, Bit 1: Animation
    exif_flag = (flags &&& 0x08) != 0
    xmp_flag = (flags &&& 0x04) != 0
    anim_flag = (flags &&& 0x02) != 0

    width = canvas_w_minus_1 + 1
    height = canvas_h_minus_1 + 1

    cond do
      anim_flag ->
        {:error, :unsupported_media_type}

      exif_flag or xmp_flag ->
        {:error, :metadata_normalization_violation}

      width > @max_dimension or height > @max_dimension ->
        {:error, :image_dimension_too_large}

      width == 0 or height == 0 ->
        {:error, :malformed_image}

      true ->
        {:ok, width, height}
    end
  end

  defp validate_webp(_other), do: {:error, :malformed_image}
end
