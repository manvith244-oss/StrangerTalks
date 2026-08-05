defmodule StrangertalksNewWeb.ConversationChannel do
  use Phoenix.Channel

  alias StrangertalksNew.Conversations
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.Reports
  alias StrangertalksNew.Relationships

  @impl true
  def join("conversation:" <> conversation_id, _params, socket) do
    participant_id = socket.assigns.participant_id

    with {:ok, _uuid} <- Ecto.UUID.cast(conversation_id),
         conversation when not is_nil(conversation) <-
           Conversations.get_conversation(conversation_id),
         true <- participant_id in [conversation.participant_a_id, conversation.participant_b_id],
         true <- conversation.conversation_status in [:PENDING, :ACTIVE],
         {:ok, _pid} <- ConversationServer.ensure_started(conversation_id),
         :ok <- ConversationServer.register_channel(conversation_id, participant_id, self()) do
      {:ok, %{status: "joined", conversation_id: conversation_id}, socket}
    else
      :error -> {:error, %{reason: "conversation_not_found"}}
      nil -> {:error, %{reason: "conversation_not_found"}}
      false -> {:error, %{reason: "not_conversation_member"}}
      {:error, _reason} -> {:error, %{reason: "conversation_unavailable"}}
    end
  end

  @impl true
  def handle_in(
        "message:send",
        %{"message_id" => message_id, "content" => content},
        socket
      )
      when is_binary(message_id) and is_binary(content) do
    with {:ok, _uuid} <- Ecto.UUID.cast(message_id),
         {:ok, result} <-
           ConversationServer.append_message(
             conversation_id(socket),
             socket.assigns.participant_id,
             message_id,
             content
           ) do
      {:reply, {:ok, result}, socket}
    else
      :error -> {:reply, {:error, %{reason: "invalid_message_id"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: client_reason(reason)}}, socket}
    end
  end

  def handle_in("message:send", _params, socket) do
    {:reply, {:error, %{reason: "invalid_message_payload"}}, socket}
  end

  def handle_in("message:ack", %{"message_id" => message_id}, socket)
      when is_binary(message_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(message_id),
         {:ok, result} <-
           ConversationServer.acknowledge_message(
             conversation_id(socket),
             socket.assigns.participant_id,
             message_id
           ) do
      {:reply, {:ok, result}, socket}
    else
      :error -> {:reply, {:error, %{reason: "invalid_message_id"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: client_reason(reason)}}, socket}
    end
  end

  def handle_in("message:ack", _params, socket) do
    {:reply, {:error, %{reason: "invalid_message_payload"}}, socket}
  end

  def handle_in("conversation:end", _params, socket) do
    case ConversationServer.complete_conversation(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, result} -> {:reply, {:ok, result}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: client_reason(reason)}}, socket}
    end
  end

  def handle_in(
        "conversation:report",
        %{"category" => category} = params,
        socket
      )
      when is_binary(category) do
    evidence = Map.get(params, "evidence")

    case Reports.submit_conversation_report(
           conversation_id(socket),
           socket.assigns.participant_id,
           category,
           evidence
         ) do
      {:ok, report} ->
        {:reply, {:ok, %{report_id: report.report_id, status: "submitted"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: client_reason(reason)}}, socket}
    end
  end

  def handle_in("conversation:report", _params, socket) do
    {:reply, {:error, %{reason: "invalid_report_payload"}}, socket}
  end

  def handle_in("conversation:block", _params, socket) do
    case MatchingRules.block_conversation_participant(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, _block} -> {:reply, {:ok, %{status: "blocked"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: client_reason(reason)}}, socket}
    end
  end

  def handle_in("relationship:consent", _params, socket) do
    case Relationships.consent_to_relationship(
           conversation_id(socket),
           socket.assigns.participant_id
         ) do
      {:ok, result} -> {:reply, {:ok, result}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: client_reason(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:conversation_message, payload}, socket) do
    push(socket, "message:new", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_message_status, payload}, socket) do
    push(socket, "message:status", payload)
    {:noreply, socket}
  end

  def handle_info({:conversation_completed, payload}, socket) do
    push(socket, "conversation:ended", payload)
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

  defp client_reason(:message_too_large), do: "message_too_large"
  defp client_reason(:buffer_overflow_imminent), do: "message_buffer_full"
  defp client_reason(:message_id_conflict), do: "message_id_conflict"
  defp client_reason(:sender_cannot_acknowledge), do: "sender_cannot_acknowledge"
  defp client_reason(:not_message_recipient), do: "not_message_recipient"
  defp client_reason(:unknown_message), do: "unknown_message"
  defp client_reason(:conversation_terminating), do: "conversation_terminating"
  defp client_reason(:not_conversation_member), do: "not_conversation_member"
  defp client_reason(:conversation_inactive), do: "conversation_inactive"
  defp client_reason(:invalid_report_category), do: "invalid_report_category"
  defp client_reason(:invalid_report_payload), do: "invalid_report_payload"
  defp client_reason(_reason), do: "conversation_unavailable"
end
