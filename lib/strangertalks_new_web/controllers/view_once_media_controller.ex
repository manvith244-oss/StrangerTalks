defmodule StrangertalksNewWeb.ViewOnceMediaController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Conversations
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaValidator
  alias StrangertalksNewWeb.ParticipantToken

  def stage(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id, :invalid_request),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id),
         :ok <- rate_limit(:view_once_stage, participant_id, 10, 60_000),
         {:ok, binary, conn} <- read_limited_body(conn),
         {:ok, metadata} <- ViewOnceMediaValidator.validate(binary),
         {:ok, staging_token} <-
           ViewOnceMediaStore.stage_media(conversation_id, participant_id, binary, metadata) do
      json(conn, %{staging_token: staging_token})
    else
      error ->
        StrangertalksNew.Telemetry.failure(
          [:message, :accept, :failed],
          unwrap_error(error),
          %{message_type: :view_once_photo}
        )

        error_response(conn, error)
    end
  end

  def show(
        conn,
        %{"conversation_id" => conversation_id, "client_message_id" => client_message_id} = params
      ) do
    token =
      Map.get(params, "token") || get_req_header(conn, "x-presentation-token") |> List.first()

    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id, :invalid_request),
         :ok <- valid_uuid(client_message_id, :invalid_message_id),
         {:ok, _conversation} <- active_conversation(conversation_id, participant_id),
         true <- is_binary(token) and token != "",
         {:ok, binary, media_type} <-
           ViewOnceMediaStore.consume_presentation_capability(
             conversation_id,
             client_message_id,
             token,
             participant_id,
             nil
           ) do
      conn
      |> put_resp_header("cache-control", "no-store, private")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(media_type, nil)
      |> send_resp(200, binary)
    else
      false ->
        error_response(conn, {:error, :invalid_request})

      error ->
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

  defp read_limited_body(conn) do
    max_bytes = ViewOnceMediaStore.max_item_bytes()

    with :ok <- validate_content_length(conn, max_bytes) do
      case Plug.Conn.read_body(conn, length: max_bytes + 1, read_length: max_bytes + 1) do
        {:ok, body, conn} when byte_size(body) <= max_bytes -> {:ok, body, conn}
        {:ok, _body, _conn} -> {:error, :view_once_photo_too_large}
        {:more, _body, _conn} -> {:error, :view_once_photo_too_large}
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
          {length, ""} when length > max_bytes -> {:error, :view_once_photo_too_large}
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

  defp rate_limit(bucket, participant_id, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(bucket, participant_id, limit, window_ms) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp error_response(conn, error) do
    term = unwrap_error(error)
    {status, payload} = StrangertalksNew.DomainError.to_http_response(term)
    conn |> put_status(status) |> json(payload)
  end

  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(other), do: other
end
