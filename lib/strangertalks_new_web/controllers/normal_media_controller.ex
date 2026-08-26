defmodule StrangertalksNewWeb.NormalMediaController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Conversations
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaValidator
  alias StrangertalksNewWeb.ParticipantToken

  def create(
        conn,
        %{
          "conversation_id" => conversation_id,
          "client_message_id" => client_message_id,
          "kind" => kind
        }
      ) do
    result =
      with {:ok, participant_id} <- authenticate(conn),
           :ok <- valid_uuid(conversation_id, :invalid_request),
           :ok <- valid_uuid(client_message_id, :invalid_message_id),
           {:ok, _conversation} <- active_conversation(conversation_id, participant_id),
           :ok <- rate_limit(:normal_media_upload, participant_id, 10, 60_000),
           {:ok, binary, conn} <- read_limited_body(conn),
           {:ok, metadata} <- ViewOnceMediaValidator.validate(binary),
           :ok <- validate_kind(kind, metadata.media_type),
           {:ok, media, disposition} <-
             NormalMediaStore.put_media(
               conversation_id,
               participant_id,
               client_message_id,
               binary,
               metadata
             ),
           {:ok, _conversation} <- active_conversation(conversation_id, participant_id) do
        {:ok, conn, media, disposition}
      end

    case result do
      {:ok, conn, media, disposition} ->
        status = if disposition == :created, do: 201, else: 200
        conn |> put_status(status) |> json(Map.put(media, :idempotent, disposition == :duplicate))

      error ->
        if stored?(conversation_id, client_message_id) and terminal_error?(error) do
          _ = NormalMediaStore.delete_media(conversation_id, client_message_id)
        end

        error_response(conn, error)
    end
  end

  def create(conn, _params), do: error_response(conn, {:error, :invalid_request})

  def index(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id, :invalid_request),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id),
         :ok <- rate_limit(:normal_media_list, participant_id, 120, 60_000),
         {:ok, items} <- NormalMediaStore.list_media(conversation_id, participant_id),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id) do
      json(conn, %{items: items})
    else
      error -> error_response(conn, error)
    end
  end

  def show(conn, %{"conversation_id" => conversation_id, "client_message_id" => client_message_id}) do
    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id, :invalid_request),
         :ok <- valid_uuid(client_message_id, :invalid_message_id),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id),
         :ok <- rate_limit(:normal_media_open, participant_id, 120, 60_000),
         {:ok, binary, media_type} <-
           NormalMediaStore.fetch_media(conversation_id, client_message_id),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id) do
      conn
      |> put_resp_header("cache-control", "no-store, private")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_content_type(media_type, nil)
      |> send_resp(200, binary)
    else
      error -> error_response(conn, error)
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

  defp read_limited_body(conn) do
    max_bytes = NormalMediaStore.max_item_bytes()

    with :ok <- validate_content_length(conn, max_bytes) do
      case Plug.Conn.read_body(conn, length: max_bytes + 1, read_length: max_bytes + 1) do
        {:ok, body, conn} when byte_size(body) <= max_bytes -> {:ok, body, conn}
        {:ok, _body, _conn} -> {:error, :normal_media_too_large}
        {:more, _body, _conn} -> {:error, :normal_media_too_large}
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
          {length, ""} when length > max_bytes -> {:error, :normal_media_too_large}
          _ -> {:error, :invalid_body}
        end

      _ ->
        {:error, :invalid_body}
    end
  end

  defp validate_kind("photo", "image/" <> _rest), do: :ok
  defp validate_kind("video", "video/mp4"), do: :ok
  defp validate_kind(_kind, _media_type), do: {:error, :media_kind_mismatch}

  defp valid_uuid(value, error) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, error}
    end
  end

  defp valid_uuid(_value, error), do: {:error, error}

  defp rate_limit(bucket, participant_id, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(bucket, participant_id, limit, window_ms) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp stored?(conversation_id, client_message_id) do
    match?(
      {:ok, _binary, _media_type},
      NormalMediaStore.fetch_media(conversation_id, client_message_id)
    )
  end

  defp terminal_error?({:error, reason}) do
    reason in [
      :conversation_inactive,
      :conversation_not_found,
      :conversation_unavailable,
      :conversation_terminating
    ]
  end

  defp terminal_error?(_error), do: false

  defp error_response(conn, error) do
    reason = unwrap_error(error)

    {status, public_reason} =
      case reason do
        :invalid_token -> {401, :invalid_token}
        :not_conversation_member -> {403, :not_conversation_member}
        :conversation_not_found -> {404, :conversation_not_found}
        :media_unavailable -> {404, :media_unavailable}
        :conversation_inactive -> {410, :conversation_inactive}
        :conversation_unavailable -> {410, :conversation_inactive}
        :conversation_terminating -> {410, :conversation_inactive}
        :normal_media_identity_conflict -> {409, :normal_media_identity_conflict}
        :normal_media_too_large -> {413, :normal_media_too_large}
        :view_once_photo_too_large -> {413, :normal_media_too_large}
        :view_once_video_too_large -> {413, :normal_media_too_large}
        :normal_media_conversation_capacity -> {503, :normal_media_capacity}
        :normal_media_global_capacity -> {503, :normal_media_capacity}
        :normal_media_order_unavailable -> {503, :normal_media_order_unavailable}
        {:rate_limited, _retry_after_ms} -> {429, :rate_limited}
        :unsupported_media_type -> {415, :unsupported_media_type}
        :unsupported_video_codec -> {415, :unsupported_media_type}
        :malformed_image -> {422, :malformed_media}
        :malformed_video -> {422, :malformed_media}
        :image_dimension_too_large -> {422, :media_dimensions_too_large}
        :video_dimension_too_large -> {422, :media_dimensions_too_large}
        :video_duration_too_long -> {422, :video_duration_too_long}
        :media_kind_mismatch -> {422, :media_kind_mismatch}
        :invalid_message_id -> {400, :invalid_message_id}
        :invalid_body -> {400, :invalid_body}
        _ -> {400, :invalid_request}
      end

    conn |> put_status(status) |> json(%{error: Atom.to_string(public_reason)})
  end

  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(other), do: other
end
