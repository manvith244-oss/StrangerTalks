defmodule StrangertalksNewWeb.ConversationChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias StrangertalksNew.Conversations
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.Reports
  alias StrangertalksNew.Relationships

  @max_sequence 2_147_483_647

  @impl true
  def join("conversation:" <> conversation_id, params, socket) do
    participant_id = socket.assigns.participant_id

    with {:ok, client_epoch_id, last_seen_sequence} <- sync_coordinates(params),
         {:ok, _uuid} <- Ecto.UUID.cast(conversation_id),
         conversation when not is_nil(conversation) <-
           Conversations.get_conversation(conversation_id),
         true <- participant_id in [conversation.participant_a_id, conversation.participant_b_id],
         true <- conversation.conversation_status in [:PENDING, :ACTIVE, :PAUSED],
         {:ok, _pid} <- ConversationServer.ensure_started(conversation_id),
         {:ok, sync_payload} <-
           ConversationServer.sync_and_register_channel(
             conversation_id,
             participant_id,
             self(),
             client_epoch_id,
             last_seen_sequence
           ) do
      {:ok, Map.put(sync_payload, :conversation_id, conversation_id), socket}
    else
      :error -> conversation_join_error(:conversation_not_found)
      nil -> conversation_join_error(:conversation_not_found)
      false -> conversation_join_error(:not_conversation_member)
      {:error, reason} -> conversation_join_error(reason)
    end
  end

  @impl true
  def handle_in("message:send", %{"staging_token" => staging_token} = params, socket) do
    type = Map.get(params, "type")

    presentation_limit =
      case Map.get(params, "presentation_limit") || Map.get(params, "limit") do
        2 -> 2
        "2" -> 2
        _ -> 1
      end

    msg_kind = if type == "view_once_video", do: :view_once_video, else: :view_once_photo

    with :ok <- rate_limit(socket, :message_send, 20, 10_000),
         true <-
           allowed_keys?(params, [
             "staging_token",
             "client_message_id",
             "message_id",
             "presentation_limit",
             "limit",
             "type"
           ]),
         {:ok, client_message_id} <- extract_message_id(params),
         {:ok, _uuid} <- Ecto.UUID.cast(client_message_id),
         true <- is_binary(staging_token) and staging_token != "",
         {:ok, result} <-
           (if type == "view_once_video" do
              ConversationServer.append_view_once_video(
                conversation_id(socket),
                socket.assigns.participant_id,
                client_message_id,
                staging_token,
                presentation_limit
              )
            else
              ConversationServer.append_view_once_photo(
                conversation_id(socket),
                socket.assigns.participant_id,
                client_message_id,
                staging_token,
                presentation_limit
              )
            end) do
      {:reply, {:ok, Map.put_new(result, :client_message_id, client_message_id)}, socket}
    else
      false -> message_accept_error(socket, :invalid_payload, msg_kind)
      :error -> message_accept_error(socket, :invalid_message_id, msg_kind)
      {:error, reason} -> message_accept_error(socket, reason, msg_kind)
    end
  end

  def handle_in("message:send", %{"expressive_id" => expressive_id} = params, socket) do
    with :ok <- rate_limit(socket, :message_send, 20, 10_000),
         true <- allowed_keys?(params, ["expressive_id", "client_message_id", "message_id"]),
         {:ok, client_message_id} <- extract_message_id(params),
         {:ok, _uuid} <- Ecto.UUID.cast(client_message_id),
         true <- is_binary(expressive_id),
         {:ok, result} <-
           ConversationServer.append_expressive_message(
             conversation_id(socket),
             socket.assigns.participant_id,
             client_message_id,
             expressive_id
           ) do
      {:reply, {:ok, Map.put_new(result, :client_message_id, client_message_id)}, socket}
    else
      false -> message_accept_error(socket, :invalid_payload, :expressive)
      :error -> message_accept_error(socket, :invalid_message_id, :expressive)
      {:error, reason} -> message_accept_error(socket, reason, :expressive)
    end
  end

  def handle_in("message:send", params, socket) when is_map(params) do
    content = Map.get(params, "content")
    reply_to_client_message_id = Map.get(params, "reply_to_client_message_id")

    with true <-
           allowed_keys?(params, [
             "content",
             "client_message_id",
             "message_id",
             "reply_to_client_message_id"
           ]),
         {:ok, client_message_id} <- extract_message_id(params),
         :ok <- validate_message_content(content),
         {:ok, _uuid} <- Ecto.UUID.cast(client_message_id),
         {:ok, validated_reply_id} <- validate_reply_target_id(reply_to_client_message_id),
         :ok <- rate_limit(socket, :message_send, 20, 10_000),
         {:ok, result} <-
           ConversationServer.append_message(
             conversation_id(socket),
             socket.assigns.participant_id,
             client_message_id,
             content,
             validated_reply_id
           ) do
      {:reply, {:ok, Map.put_new(result, :client_message_id, client_message_id)}, socket}
    else
      false ->
        message_accept_error(socket, :invalid_payload, :text)

      {:error, :message_too_large} ->
        message_accept_error(socket, :message_too_large, :text)

      {:error, :invalid_payload} ->
        message_accept_error(socket, :invalid_payload, :text)

      {:error, :invalid_message_id} ->
        message_accept_error(socket, :invalid_message_id, :text)

      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        message_accept_error(socket, reason, :text)

      :error ->
        message_accept_error(socket, :invalid_message_id, :text)

      {:error, reason} ->
        message_accept_error(socket, reason, :text)
    end
  end

  def handle_in("message:send", _params, socket) do
    message_accept_error(socket, :invalid_payload, :text)
  end

  def handle_in("message:edit", params, socket) when is_map(params) do
    with :ok <-
           rate_limit_shared(
             socket,
             :message_edit,
             {socket.assigns.participant_id, conversation_id(socket)},
             20,
             10_000
           ),
         true <-
           allowed_keys?(params, [
             "target_client_message_id",
             "expected_content_revision",
             "content"
           ]),
         {:ok, target_client_message_id} <-
           validate_target_message_id(Map.get(params, "target_client_message_id")),
         {:ok, expected_content_revision} <-
           validate_expected_revision(Map.get(params, "expected_content_revision")),
         true <- is_binary(Map.get(params, "content")),
         {:ok, result} <-
           ConversationServer.edit_message(
             conversation_id(socket),
             socket.assigns.participant_id,
             target_client_message_id,
             expected_content_revision,
             Map.get(params, "content")
           ) do
      {:reply, {:ok, result}, socket}
    else
      {:error, :target_absent} ->
        {:reply,
         {:ok,
          %{
            status: "absent_from_authority",
            target_client_message_id: Map.get(params, "target_client_message_id")
          }}, socket}

      {:error, :invalid_revision} ->
        message_edit_error(socket, :invalid_payload)

      {:error, reason} ->
        message_edit_error(socket, reason)

      false ->
        message_edit_error(socket, :invalid_payload)
    end
  end

  def handle_in("message:edit", _params, socket) do
    case rate_limit_shared(
           socket,
           :message_edit,
           {socket.assigns.participant_id, conversation_id(socket)},
           20,
           10_000
         ) do
      :ok -> message_edit_error(socket, :invalid_payload)
      {:error, reason} -> message_edit_error(socket, reason)
    end
  end

  def handle_in("message:unsend", params, socket) when is_map(params) do
    with :ok <-
           rate_limit_shared(
             socket,
             :message_unsend,
             {socket.assigns.participant_id, conversation_id(socket)},
             20,
             10_000
           ),
         true <-
           allowed_keys?(params, [
             "target_client_message_id",
             "expected_content_revision"
           ]),
         {:ok, target_client_message_id} <-
           validate_target_message_id(Map.get(params, "target_client_message_id")),
         {:ok, expected_content_revision} <-
           validate_expected_revision(Map.get(params, "expected_content_revision")),
         {:ok, result} <-
           ConversationServer.unsend_message(
             conversation_id(socket),
             socket.assigns.participant_id,
             target_client_message_id,
             expected_content_revision
           ) do
      {:reply, {:ok, result}, socket}
    else
      {:error, :target_absent} ->
        {:reply,
         {:ok,
          %{
            status: "absent_from_authority",
            target_client_message_id: Map.get(params, "target_client_message_id")
          }}, socket}

      {:error, :invalid_revision} ->
        message_unsend_error(socket, :invalid_payload)

      {:error, reason} ->
        message_unsend_error(socket, reason)

      false ->
        message_unsend_error(socket, :invalid_payload)
    end
  end

  def handle_in("message:unsend", _params, socket) do
    case rate_limit_shared(
           socket,
           :message_unsend,
           {socket.assigns.participant_id, conversation_id(socket)},
           20,
           10_000
         ) do
      :ok -> message_unsend_error(socket, :invalid_payload)
      {:error, reason} -> message_unsend_error(socket, reason)
    end
  end

  def handle_in("message:reply_target", params, socket) when is_map(params) do
    reply_to_client_message_id = Map.get(params, "reply_to_client_message_id")

    with true <- allowed_keys?(params, ["reply_to_client_message_id"]),
         {:ok, target_id} <- validate_reply_target_id(reply_to_client_message_id),
         true <- not is_nil(target_id),
         :ok <- rate_limit(socket, :reply_target, 30, 10_000),
         {:ok, result} <-
           ConversationServer.lookup_reply_target(
             conversation_id(socket),
             socket.assigns.participant_id,
             target_id
           ) do
      {:reply, {:ok, result}, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :invalid_message_id} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_message_id)},
         socket}

      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        StrangertalksNew.Telemetry.failure([:reply_target, :check_failed], reason)
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} when reason in [:conversation_busy, :conversation_unavailable] ->
        StrangertalksNew.Telemetry.failure([:reply_target, :check_failed], reason)
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("message:reply_target", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)}, socket}
  end

  def handle_in("message:react", params, socket) when is_map(params) do
    target_id = Map.get(params, "target_client_message_id")
    desired_reaction = Map.get(params, "desired_reaction")
    expected_revision = Map.get(params, "expected_reaction_revision")

    with true <-
           allowed_keys?(params, [
             "target_client_message_id",
             "desired_reaction",
             "expected_reaction_revision"
           ]),
         {:ok, validated_target_id} <- validate_target_message_id(target_id),
         {:ok, validated_reaction} <- validate_desired_reaction(desired_reaction),
         {:ok, validated_revision} <- validate_expected_revision(expected_revision),
         :ok <-
           rate_limit_shared(
             socket,
             :reaction_mutation,
             {socket.assigns.participant_id, conversation_id(socket)},
             20,
             10_000
           ),
         {:ok, result} <-
           ConversationServer.mutate_reaction(
             conversation_id(socket),
             socket.assigns.participant_id,
             validated_target_id,
             validated_reaction,
             validated_revision
           ) do
      {:reply, {:ok, result}, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :invalid_message_id} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_message_id)},
         socket}

      {:error, :invalid_payload} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :invalid_revision} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :target_absent} ->
        {:reply,
         {:ok,
          %{
            status: "target_absent",
            target_client_message_id: Map.get(params, "target_client_message_id")
          }}, socket}

      {:error, :invalid_request} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)},
         socket}

      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        StrangertalksNew.Telemetry.failure([:reaction_mutation, :check_failed], reason)
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} when reason in [:conversation_busy, :conversation_unavailable] ->
        StrangertalksNew.Telemetry.failure([:reaction_mutation, :check_failed], reason)
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("message:react", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)}, socket}
  end

  def handle_in("message:pin", params, socket) when is_map(params) do
    target_id = Map.get(params, "target_client_message_id")
    pinned = Map.get(params, "pinned")
    expected_revision = Map.get(params, "expected_pin_revision")

    with true <-
           allowed_keys?(params, [
             "target_client_message_id",
             "pinned",
             "expected_pin_revision"
           ]),
         {:ok, validated_target_id} <- validate_target_message_id(target_id),
         {:ok, validated_pinned} <- validate_boolean(pinned),
         {:ok, validated_revision} <- validate_expected_revision(expected_revision),
         :ok <-
           rate_limit_shared(
             socket,
             :pin_mutation,
             {socket.assigns.participant_id, conversation_id(socket)},
             20,
             10_000
           ),
         {:ok, result} <-
           ConversationServer.mutate_pin(
             conversation_id(socket),
             socket.assigns.participant_id,
             validated_target_id,
             validated_pinned,
             validated_revision
           ) do
      {:reply, {:ok, result}, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :invalid_message_id} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_message_id)},
         socket}

      {:error, :invalid_payload} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :invalid_revision} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :target_absent} ->
        {:reply,
         {:ok,
          %{
            status: "target_absent",
            target_client_message_id: Map.get(params, "target_client_message_id")
          }}, socket}

      {:error, :pin_limit_reached} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:pin_limit_reached)},
         socket}

      {:error, :invalid_request} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)},
         socket}

      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} when reason in [:conversation_busy, :conversation_unavailable] ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("message:pin", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)}, socket}
  end

  def handle_in(
        "delivery:progress",
        %{"epoch_id" => epoch_id, "highest_contiguous_sequence" => sequence} = params,
        socket
      ) do
    with true <- allowed_keys?(params, ["epoch_id", "highest_contiguous_sequence"]),
         true <- is_binary(epoch_id),
         {:ok, highest_contiguous_sequence} <- sequence_cursor(sequence),
         :ok <- rate_limit(socket, :message_ack, 120, 10_000),
         {:ok, result} <-
           ConversationServer.report_delivery_progress(
             conversation_id(socket),
             socket.assigns.participant_id,
             self(),
             epoch_id,
             highest_contiguous_sequence
           ) do
      {:reply, {:ok, result}, socket}
    else
      false -> message_ack_error(socket, :invalid_payload, :text)
      {:error, :invalid_sequence} -> message_ack_error(socket, :invalid_payload, :text)
      {:error, reason} -> message_ack_error(socket, reason, :text)
    end
  end

  def handle_in("delivery:progress", _params, socket),
    do: message_ack_error(socket, :invalid_payload, :text)

  def handle_in(
        "content:applied",
        %{
          "epoch_id" => epoch_id,
          "target_client_message_id" => target_client_message_id,
          "content_revision" => content_revision
        } = params,
        socket
      ) do
    with true <-
           allowed_keys?(params, [
             "epoch_id",
             "target_client_message_id",
             "content_revision"
           ]),
         true <- is_binary(epoch_id),
         {:ok, target_client_message_id} <- validate_target_message_id(target_client_message_id),
         {:ok, content_revision} <- validate_expected_revision(content_revision),
         :ok <- rate_limit(socket, :message_ack, 120, 10_000),
         {:ok, result} <-
           ConversationServer.report_content_revision_applied(
             conversation_id(socket),
             socket.assigns.participant_id,
             self(),
             epoch_id,
             target_client_message_id,
             content_revision
           ) do
      {:reply, {:ok, result}, socket}
    else
      false ->
        message_ack_error(socket, :invalid_payload, :content_revision)

      {:error, :invalid_revision} ->
        message_ack_error(socket, :invalid_payload, :content_revision)

      {:error, reason} ->
        message_ack_error(socket, reason, :content_revision)
    end
  end

  def handle_in("content:applied", _params, socket),
    do: message_ack_error(socket, :invalid_payload, :content_revision)

  def handle_in(
        "session:visibility",
        %{"visibility" => visibility} = params,
        socket
      ) do
    with true <- allowed_keys?(params, ["visibility"]),
         {:ok, vis_atom} <- parse_visibility(visibility),
         :ok <- rate_limit(socket, :presence_visibility, 30, 10_000),
         {:ok, _result} <-
           ConversationServer.update_session_visibility(
             conversation_id(socket),
             socket.assigns.participant_id,
             self(),
             vis_atom
           ) do
      {:reply, :ok, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, {:rate_limited, _retry_after_ms} = reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("session:visibility", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)}, socket}
  end

  def handle_in("presence:visibility", params, socket) do
    handle_in("session:visibility", params, socket)
  end

  def handle_in("message:ack", _params, socket),
    do: message_ack_error(socket, :invalid_request, :text)

  def handle_in("sync:reconcile", params, socket) when is_map(params) do
    with true <- allowed_keys?(params, ["last_applied_sequence"]),
         {:ok, last_seen_sequence} <- sequence_cursor(Map.get(params, "last_applied_sequence")),
         :ok <- rate_limit(socket, :timeline_sync, 6, 30_000),
         {:ok, sync_payload} <-
           ConversationServer.get_messages_after(
             conversation_id(socket),
             socket.assigns.participant_id,
             last_seen_sequence
           ) do
      {:reply, {:ok, sync_payload}, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, :invalid_sequence} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, reason} ->
        StrangertalksNew.Telemetry.failure([:timeline, :sync, :failed], reason)
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("voice_note:ack", %{"voice_note_id" => voice_note_id} = params, socket)
      when is_binary(voice_note_id) do
    with true <- allowed_keys?(params, ["voice_note_id"]),
         {:ok, _uuid} <- Ecto.UUID.cast(voice_note_id),
         :ok <- rate_limit(socket, :message_ack, 120, 10_000),
         {:ok, result} <-
           ConversationServer.acknowledge_voice_note(
             conversation_id(socket),
             socket.assigns.participant_id,
             voice_note_id
           ) do
      {:reply, {:ok, result}, socket}
    else
      :error -> message_ack_error(socket, :invalid_voice_note_id, :voice_note)
      {:error, reason} -> message_ack_error(socket, reason, :voice_note)
    end
  end

  def handle_in("voice_note:ack", _params, socket),
    do: message_ack_error(socket, :invalid_payload, :voice_note)

  def handle_in("view_once:open", params, socket) when is_map(params) do
    attempt_id = Map.get(params, "attempt_id")

    with :ok <-
           rate_limit_shared(
             socket,
             :view_once_open,
             {socket.assigns.participant_id, conversation_id(socket)},
             20,
             10_000
           ),
         true <-
           allowed_keys?(params, [
             "target_client_message_id",
             "client_message_id",
             "attempt_id"
           ]),
         {:ok, target_client_message_id} <-
           validate_target_message_id(
             Map.get(params, "target_client_message_id") || Map.get(params, "client_message_id")
           ),
         {:ok, result} <-
           ConversationServer.open_view_once_photo(
             conversation_id(socket),
             socket.assigns.participant_id,
             target_client_message_id,
             attempt_id
           ) do
      {:reply, {:ok, result}, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      :error ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_message_id)},
         socket}

      {:error, :target_absent} ->
        {:reply,
         {:ok,
          %{
            status: "absent_from_authority",
            target_client_message_id:
              Map.get(params, "target_client_message_id") || Map.get(params, "client_message_id")
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("view_once:open", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)}, socket}
  end

  def handle_in("conversation:end", params, socket) when params == %{} do
    case ConversationServer.complete_conversation(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("conversation:end", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
       socket}

  def handle_in(
        "conversation:report",
        %{"category" => category} = params,
        socket
      )
      when is_binary(category) do
    evidence = Map.get(params, "evidence")
    target_client_message_id = Map.get(params, "target_client_message_id")

    with true <- allowed_keys?(params, ["category", "evidence", "target_client_message_id"]),
         true <- is_nil(evidence) or is_binary(evidence),
         {:ok, validated_target_id} <- validate_reply_target_id(target_client_message_id),
         :ok <- rate_limit(socket, :report, 10, 3_600_000),
         {:ok, report} <-
           Reports.submit_conversation_report(
             conversation_id(socket),
             socket.assigns.participant_id,
             category,
             evidence,
             validated_target_id
           ) do
      {:reply, {:ok, %{report_id: report.report_id, status: "submitted"}}, socket}
    else
      false ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
         socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("conversation:report", _params, socket) do
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)}, socket}
  end

  def handle_in("conversation:block", params, socket) when params == %{} do
    case MatchingRules.block_conversation_participant(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, _block} ->
        {:reply, {:ok, %{status: "blocked"}}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("conversation:block", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
       socket}

  def handle_in("relationship:consent", params, socket) when params == %{} do
    case Relationships.consent_to_relationship(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("relationship:consent", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
       socket}

  def handle_in("typing:start", params, socket) when params == %{} do
    with :ok <- rate_limit(socket, :typing, 12, 5_000),
         :ok <-
           ConversationServer.start_typing(conversation_id(socket), socket.assigns.participant_id) do
      {:reply, :ok, socket}
    else
      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("typing:start", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
       socket}

  def handle_in("typing:stop", params, socket) when params == %{} do
    with :ok <- rate_limit(socket, :typing, 12, 5_000),
         :ok <-
           ConversationServer.stop_typing(conversation_id(socket), socket.assigns.participant_id) do
      {:reply, :ok, socket}
    else
      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("typing:stop", _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_payload)},
       socket}

  # Live Communication Suite (Feature 1Q)
  def handle_in("call:initiate", params, socket) do
    call_type = Map.get(params, "call_type", "voice")

    case ConversationServer.initiate_call(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           call_type
         ) do
      {:ok, call_state} ->
        {:reply, {:ok, call_state}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:accept", %{"call_attempt_id" => attempt_id}, socket) do
    case ConversationServer.accept_call(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id
         ) do
      {:ok, call_state} ->
        {:reply, {:ok, call_state}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:decline", %{"call_attempt_id" => attempt_id}, socket) do
    case ConversationServer.decline_call(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id
         ) do
      :ok ->
        {:reply, {:ok, %{status: "declined"}}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:cancel", %{"call_attempt_id" => attempt_id}, socket) do
    case ConversationServer.cancel_call(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id
         ) do
      :ok ->
        {:reply, {:ok, %{status: "canceled"}}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:end", %{"call_attempt_id" => attempt_id}, socket) do
    case ConversationServer.end_call(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id
         ) do
      :ok ->
        {:reply, {:ok, %{status: "ended"}}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:mute", %{"call_attempt_id" => attempt_id, "muted" => muted}, socket) do
    case ConversationServer.set_call_mute(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           muted == true
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:effect",
        %{"call_attempt_id" => attempt_id, "effect_active" => active},
        socket
      ) do
    case ConversationServer.set_call_effect(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           active == true
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:signal",
        %{"call_attempt_id" => attempt_id, "media_generation" => gen, "signal" => signal},
        socket
      ) do
    case ConversationServer.signal_call(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           gen,
           signal
         ) do
      :ok ->
        {:reply, {:ok, %{status: "delivered"}}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:media_request",
        %{"call_attempt_id" => attempt_id, "request_type" => req_type} = params,
        socket
      ) do
    proposal = Map.get(params, "proposal", %{})

    case ConversationServer.request_call_media(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           req_type,
           proposal
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:media_response",
        %{"call_attempt_id" => attempt_id, "media_request_id" => req_id, "decision" => decision},
        socket
      ) do
    case ConversationServer.respond_call_media(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           req_id,
           decision
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:request_credentials", %{"call_attempt_id" => attempt_id}, socket) do
    case ConversationServer.request_call_credentials(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id
         ) do
      {:ok, creds} ->
        {:reply, {:ok, creds}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:return_to_voice",
        %{"call_attempt_id" => attempt_id},
        socket
      ) do
    case ConversationServer.return_to_voice(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:reaction",
        %{
          "call_attempt_id" => attempt_id,
          "reaction_event_id" => reaction_event_id,
          "reaction" => reaction
        },
        socket
      ) do
    case ConversationServer.send_call_reaction(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           reaction_event_id,
           reaction
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(
        "call:reveal_ready",
        %{
          "call_attempt_id" => attempt_id,
          "media_request_id" => media_request_id,
          "ready" => ready
        },
        socket
      ) do
    case ConversationServer.set_reveal_ready(
           conversation_id(socket),
           socket.assigns.participant_id,
           self(),
           socket.assigns[:session_id] || socket.assigns.participant_id,
           attempt_id,
           media_request_id,
           ready
         ) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in("call:get_state", _params, socket) do
    case ConversationServer.get_call_state(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, call_state} ->
        {:reply, {:ok, %{call_state: call_state}}, socket}

      {:error, reason} ->
        {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do:
      {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(:invalid_request)},
       socket}

  @impl true
  def handle_info({:call_incoming, payload}, socket) do
    push(socket, "call:incoming", payload)
    {:noreply, socket}
  end

  def handle_info({:call_initiated, payload}, socket) do
    push(socket, "call:initiated", payload)
    {:noreply, socket}
  end

  def handle_info({:call_accepted, payload}, socket) do
    push(socket, "call:accepted", payload)
    {:noreply, socket}
  end

  def handle_info({:call_ended, payload}, socket) do
    push(socket, "call:ended", payload)
    {:noreply, socket}
  end

  def handle_info({:call_mute_changed, payload}, socket) do
    push(socket, "call:mute_changed", payload)
    {:noreply, socket}
  end

  def handle_info({:call_effect_changed, payload}, socket) do
    push(socket, "call:effect_changed", payload)
    {:noreply, socket}
  end

  def handle_info({:call_signal, payload}, socket) do
    push(socket, "call:signal", payload)
    {:noreply, socket}
  end

  def handle_info({:call_media_requested, payload}, socket) do
    push(socket, "call:media_requested", payload)
    {:noreply, socket}
  end

  def handle_info({:call_media_updated, payload}, socket) do
    push(socket, "call:media_updated", payload)
    {:noreply, socket}
  end

  def handle_info({:call_media_declined, payload}, socket) do
    push(socket, "call:media_declined", payload)
    {:noreply, socket}
  end

  def handle_info({:call_reveal_ready, payload}, socket) do
    push(socket, "call:reveal_ready", payload)
    {:noreply, socket}
  end

  def handle_info({:call_reveal_committed, payload}, socket) do
    push(socket, "call:reveal_committed", payload)
    {:noreply, socket}
  end

  def handle_info({:call_reaction, payload}, socket) do
    push(socket, "call:reaction", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_message, payload}, socket) do
    push(socket, "message:new", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_message_status, payload}, socket) do
    push(socket, "message:status", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_message_edited, payload}, socket) do
    push(socket, "message:edited", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_message_unsent, payload}, socket) do
    push(socket, "message:unsent", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_message_content_status, payload}, socket) do
    push(socket, "message:content_status", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_voice_note, payload}, socket) do
    push(socket, "voice_note:new", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_voice_note_status, payload}, socket) do
    push(socket, "voice_note:status", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_completed, payload}, socket) do
    push(socket, "conversation:ended", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_presence, payload}, socket) do
    push(socket, "conversation:presence", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_reaction, payload}, socket) do
    push(socket, "message:reaction", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_pins, payload}, socket) do
    push(socket, "conversation:pins", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_icebreaker, payload}, socket) do
    push(socket, "conversation:icebreaker", payload)
    {:noreply, socket}
  end

  def handle_info({:typing_status, payload}, socket) do
    push(socket, "typing:status", payload)
    {:noreply, socket}
  end

  def handle_info({:view_once_viewed, payload}, socket) do
    push(socket, "view_once:viewed", payload)
    {:noreply, socket}
  end

  def handle_info({:view_once_unavailable, payload}, socket) do
    push(socket, "view_once:unavailable", payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    ConversationServer.unregister_channel(
      conversation_id(socket),
      socket.assigns.participant_id,
      self()
    )

    :ok
  end

  defp conversation_id(socket), do: String.replace_prefix(socket.topic, "conversation:", "")

  defp conversation_join_error(reason) do
    StrangertalksNew.Telemetry.failure([:conversation, :join, :failed], reason)
    {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}
  end

  defp message_accept_error(socket, reason, message_type) do
    StrangertalksNew.Telemetry.failure(
      [:message, :accept, :failed],
      reason,
      %{message_type: message_type}
    )

    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
  end

  defp message_ack_error(socket, reason, message_type) do
    StrangertalksNew.Telemetry.failure(
      [:message, :ack, :failed],
      reason,
      %{message_type: message_type}
    )

    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
  end

  defp message_edit_error(socket, reason) do
    StrangertalksNew.Telemetry.failure([:message_edit, :failed], reason)
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
  end

  defp message_unsend_error(socket, reason) do
    StrangertalksNew.Telemetry.failure([:message_unsend, :failed], reason)
    {:reply, {:error, StrangertalksNew.DomainError.to_channel_payload(reason)}, socket}
  end

  defp extract_message_id(params) when is_map(params) do
    case {Map.get(params, "client_message_id"), Map.get(params, "message_id")} do
      {nil, nil} -> {:error, :invalid_payload}
      {id, nil} when is_binary(id) -> {:ok, id}
      {nil, id} when is_binary(id) -> {:ok, id}
      {id1, id2} when is_binary(id1) and id1 == id2 -> {:ok, id1}
      {id1, id2} when is_binary(id1) and is_binary(id2) -> {:error, :message_id_conflict}
      _ -> {:error, :invalid_payload}
    end
  end

  defp sync_coordinates(params) when is_map(params) do
    with true <- allowed_keys?(params, ["epoch_id", "last_applied_sequence"]),
         {:ok, epoch_id} <- epoch_id(Map.get(params, "epoch_id")),
         {:ok, sequence} <- sequence_cursor(Map.get(params, "last_applied_sequence", 0)) do
      {:ok, epoch_id, sequence}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp sync_coordinates(_params), do: {:error, :invalid_payload}

  defp epoch_id(nil), do: {:ok, nil}
  defp epoch_id(""), do: {:ok, nil}

  defp epoch_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> {:ok, value}
      :error -> {:error, :invalid_epoch_id}
    end
  end

  defp epoch_id(_value), do: {:error, :invalid_epoch_id}

  defp sequence_cursor(value)
       when is_integer(value) and value >= 0 and value <= @max_sequence,
       do: {:ok, value}

  defp sequence_cursor(_value), do: {:error, :invalid_sequence}

  defp validate_message_content(content) when is_binary(content) do
    cond do
      not String.valid?(content) -> {:error, :invalid_payload}
      byte_size(content) > ConversationServer.max_message_bytes() -> {:error, :message_too_large}
      true -> :ok
    end
  end

  defp validate_message_content(_content), do: {:error, :invalid_payload}

  defp allowed_keys?(params, allowed),
    do: Enum.all?(Map.keys(params), &(&1 in allowed))

  defp validate_reply_target_id(nil), do: {:ok, nil}

  defp validate_reply_target_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> {:ok, id}
      :error -> {:error, :invalid_message_id}
    end
  end

  defp validate_reply_target_id(_), do: {:error, :invalid_payload}

  defp validate_target_message_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> {:ok, id}
      :error -> {:error, :invalid_message_id}
    end
  end

  defp validate_target_message_id(_), do: {:error, :invalid_payload}

  defp validate_boolean(b) when is_boolean(b), do: {:ok, b}
  defp validate_boolean(_), do: {:error, :invalid_payload}

  defp validate_desired_reaction(nil), do: {:ok, nil}

  defp validate_desired_reaction(emoji) when is_binary(emoji) do
    case StrangertalksNew.EmojiValidator.canonical_reaction(emoji) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, :invalid_reaction} -> {:error, :invalid_payload}
    end
  end

  defp validate_desired_reaction(_), do: {:error, :invalid_payload}

  defp validate_expected_revision(rev)
       when is_integer(rev) and rev >= 0 and rev <= @max_sequence,
       do: {:ok, rev}

  defp validate_expected_revision(_), do: {:error, :invalid_revision}

  defp rate_limit(socket, bucket, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(
           bucket,
           socket.assigns.participant_id,
           limit,
           window_ms
         ) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp rate_limit_shared(_socket, bucket, actor_key, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(
           bucket,
           actor_key,
           limit,
           window_ms
         ) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp parse_visibility("visible"), do: {:ok, :visible}
  defp parse_visibility("hidden"), do: {:ok, :hidden}
  defp parse_visibility(_), do: {:error, :invalid_payload}
end
