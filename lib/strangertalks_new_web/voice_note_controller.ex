defmodule StrangertalksNewWeb.VoiceNoteController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Conversations
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.VoiceNoteStore
  alias StrangertalksNewWeb.ParticipantToken

  @media_types ["audio/webm", "audio/ogg", "audio/mp4"]

  def create(conn, %{"conversation_id" => conversation_id, "voice_note_id" => voice_note_id}) do
    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id, :invalid_request),
         :ok <- valid_uuid(voice_note_id, :invalid_voice_note_id),
         {:ok, conversation} <- active_conversation(conversation_id, participant_id),
         :ok <- rate_limit(:voice_upload, participant_id, 6, 60_000),
         :ok <- ConversationServer.admit_voice_note(conversation_id),
         :ok <- VoiceNoteStore.begin_upload(participant_id) do
      try do
        upload(conn, conversation, participant_id, voice_note_id)
      after
        VoiceNoteStore.finish_upload(participant_id)
      end
    else
      error ->
        StrangertalksNew.Telemetry.failure(
          [:message, :accept, :failed],
          unwrap_error(error),
          %{message_type: :voice_note}
        )

        error_response(conn, error)
    end
  end

  def show(conn, %{"conversation_id" => conversation_id, "voice_note_id" => voice_note_id}) do
    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id, :invalid_request),
         :ok <- valid_uuid(voice_note_id, :invalid_voice_note_id),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id),
         :ok <- rate_limit(:voice_retrieval, participant_id, 30, 60_000),
         {:ok, note} <- VoiceNoteStore.fetch(conversation_id, voice_note_id, participant_id) do
      conn
      |> put_resp_header("cache-control", "no-store, private")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(note.media_type)
      |> send_resp(200, note.binary)
    else
      error -> error_response(conn, error)
    end
  end

  defp upload(conn, conversation, participant_id, voice_note_id) do
    with {:ok, media_type} <- approved_media_type(conn),
         {:ok, duration_ms} <- declared_duration(conn),
         {:ok, binary, conn} <- read_limited_body(conn),
         :ok <- validate_signature(media_type, binary),
         {:ok, _pid} <- ConversationServer.ensure_started(conversation.conversation_id),
         attrs = %{
           voice_note_id: voice_note_id,
           media_type: media_type,
           duration_ms: duration_ms,
           byte_size: byte_size(binary),
           content_hash: :crypto.hash(:sha256, binary)
         },
         {:ok, result} <-
           ConversationServer.append_voice_note(
             conversation.conversation_id,
             participant_id,
             attrs,
             binary
           ) do
      json(
        conn,
        Map.take(result, [:voice_note_id, :status, :duration_ms, :byte_size, :media_type])
      )
    else
      error ->
        StrangertalksNew.Telemetry.failure(
          [:message, :accept, :failed],
          unwrap_error(error),
          %{message_type: :voice_note}
        )

        error_response(conn, error)
    end
  end

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, participant_id} <- ParticipantToken.verify(token) do
      {:ok, participant_id}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp active_conversation(conversation_id, participant_id) do
    case Conversations.get_conversation(conversation_id) do
      nil ->
        {:error, :conversation_not_found}

      conversation
      when participant_id not in [conversation.participant_a_id, conversation.participant_b_id] ->
        {:error, :not_conversation_member}

      conversation when conversation.conversation_status not in [:PENDING, :ACTIVE, :PAUSED] ->
        {:error, :conversation_inactive}

      conversation ->
        {:ok, conversation}
    end
  end

  defp approved_media_type(conn) do
    media_type =
      conn
      |> get_req_header("content-type")
      |> List.first()
      |> to_string()
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    if media_type in @media_types, do: {:ok, media_type}, else: {:error, :unsupported_media_type}
  end

  defp declared_duration(conn) do
    with [raw] <- get_req_header(conn, "x-voice-duration-ms"),
         {duration, ""} <- Integer.parse(raw),
         true <- duration in 1..60_000 do
      {:ok, duration}
    else
      _ -> {:error, :invalid_voice_duration}
    end
  end

  defp read_limited_body(conn) do
    max_bytes = VoiceNoteStore.max_note_bytes()

    with :ok <- validate_content_length(conn, max_bytes) do
      case Plug.Conn.read_body(conn, length: max_bytes + 1, read_length: max_bytes + 1) do
        {:ok, body, conn} when byte_size(body) <= max_bytes -> {:ok, body, conn}
        {:ok, _body, _conn} -> {:error, :voice_note_too_large}
        {:more, _body, _conn} -> {:error, :voice_note_too_large}
        {:error, _reason} -> {:error, :invalid_body}
      end
    end
  end

  defp validate_content_length(conn, max_bytes) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 and length <= max_bytes -> :ok
          {length, ""} when length > max_bytes -> {:error, :voice_note_too_large}
          _ -> {:error, :invalid_body}
        end

      _ ->
        {:error, :invalid_body}
    end
  end

  defp valid_uuid(value, error) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, error}
    end
  end

  defp valid_uuid(_value, error), do: {:error, error}

  defp validate_signature("audio/webm", <<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: :ok
  defp validate_signature("audio/ogg", <<"OggS", _::binary>>), do: :ok
  defp validate_signature("audio/mp4", <<_size::32, "ftyp", _::binary>>), do: :ok
  defp validate_signature(_media_type, _binary), do: {:error, :media_signature_mismatch}

  defp error_response(conn, error) do
    term = unwrap_error(error)

    {status, payload} = StrangertalksNew.DomainError.to_http_response(term)
    conn |> put_status(status) |> json(payload)
  end

  defp rate_limit(bucket, participant_id, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(bucket, participant_id, limit, window_ms) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(other), do: other
end
