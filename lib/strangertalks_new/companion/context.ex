defmodule StrangertalksNew.Companion.Context do
  @moduledoc """
  Captures and revalidates the minimum authoritative context A01 may use.

  Conversation transcript content is included only after an explicit Companion request and is
  projected from the current ConversationServer runtime. Raw live messages remain ephemeral;
  A01 does not create a PostgreSQL transcript copy.

  Historical readiness, analytics, safety-review notes, private account data, and other
  Conversations are intentionally outside this boundary.
  """

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.{Conversation, ConversationLanguages, Matching, MatchingRules, Repo}

  @active_statuses [:PENDING, :ACTIVE, :PAUSED]
  @modes ~w(start continue recover change_topic rephrase simplify language_help tone_help respond clarify deescalate express_feeling icebreaker story_prompt translate_localize)
  @tones ~w(natural warm funny direct thoughtful light gentle confident)
  @max_request_chars 800
  @max_draft_chars 4_000
  @max_messages 12
  @max_message_chars 900
  @max_context_chars 6_000

  def capture(conversation_id, participant_id, attrs) when is_map(attrs) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         :ok <- authorize_member(conversation, participant_id),
         :ok <- authorize_active(conversation),
         %Matching{} = match <- Repo.get(Matching, conversation.match_id),
         {:ok, language} <- ConversationLanguages.normalize(match.conversation_language),
         :ok <- authorize_safety(conversation, participant_id),
         {:ok, mode} <- normalize_mode(value(attrs, "mode")),
         {:ok, request} <- bounded_optional_text(value(attrs, "request"), @max_request_chars),
         {:ok, draft} <- bounded_optional_text(value(attrs, "draft"), @max_draft_chars),
         {:ok, tone} <- normalize_tone(value(attrs, "tone")),
         true <- meaningful_request?(mode, request, draft),
         {:ok, runtime_state} <- live_runtime_state(conversation_id) do
      messages = recent_messages(runtime_state.recent_messages, participant_id)

      {:ok,
       %{
         request_id: Ecto.UUID.generate(),
         conversation_id: conversation_id,
         participant_id: participant_id,
         peer_id: peer_id(conversation, participant_id),
         language: language,
         door: conversation.door_type && Atom.to_string(conversation.door_type),
         mode: mode,
         tone: tone,
         request: request,
         draft: draft,
         draft_fingerprint: fingerprint(draft),
         messages: messages,
         authority: %{
           conversation_status: conversation.conversation_status,
           match_id: conversation.match_id,
           language: language,
           epoch_id: runtime_state.epoch_id,
           next_sequence: runtime_state.next_sequence,
           transcript_fingerprint: fingerprint_messages(messages)
         }
       }}
    else
      nil -> {:error, :conversation_not_found}
      false -> {:error, :invalid_payload}
      :error -> {:error, :invalid_payload}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_payload}
    end
  end

  def capture(_conversation_id, _participant_id, _attrs), do: {:error, :invalid_payload}

  def revalidate(%{conversation_id: conversation_id, participant_id: participant_id} = context) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         :ok <- authorize_member(conversation, participant_id),
         :ok <- authorize_active(conversation),
         %Matching{} = match <- Repo.get(Matching, conversation.match_id),
         {:ok, language} <- ConversationLanguages.normalize(match.conversation_language),
         true <- language == context.language,
         :ok <- authorize_safety(conversation, participant_id),
         {:ok, runtime_state} <- live_runtime_state(conversation_id),
         true <- runtime_state.epoch_id == context.authority.epoch_id,
         true <- runtime_state.next_sequence == context.authority.next_sequence,
         current_messages <- recent_messages(runtime_state.recent_messages, participant_id),
         true <- fingerprint_messages(current_messages) == context.authority.transcript_fingerprint do
      :ok
    else
      _ -> {:error, :companion_stale}
    end
  end

  def public_context(context) do
    Map.take(context, [:conversation_id, :language, :door, :mode, :tone, :request, :draft, :messages])
  end

  defp live_runtime_state(conversation_id) do
    case ConversationServer.inspect_state(conversation_id) do
      {:ok, %{recent_messages: recent_messages, epoch_id: epoch_id, next_sequence: next_sequence} = state}
      when is_list(recent_messages) and is_binary(epoch_id) and is_integer(next_sequence) ->
        {:ok, state}

      _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp recent_messages(runtime_messages, participant_id) do
    rows =
      runtime_messages
      |> Enum.filter(fn
        %{type: :text, content: content, sender_id: sender_id, sequence: sequence} = message
        when is_binary(content) and is_binary(sender_id) and is_integer(sequence) ->
          Map.get(message, :availability, :available) != :unsent

        _ ->
          false
      end)
      |> Enum.sort_by(& &1.sequence)
      |> Enum.take(-@max_messages)
      |> Enum.map(fn row ->
        %{
          role: if(row.sender_id == participant_id, do: "self", else: "stranger"),
          text: truncate_text(row.content, @max_message_chars),
          sequence: row.sequence
        }
      end)

    {bounded, _used} =
      rows
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn row, {acc, used} ->
        remaining = max(@max_context_chars - used, 0)

        if remaining == 0 do
          {acc, used}
        else
          text = truncate_text(row.text, remaining)
          {[%{row | text: text} | acc], used + String.length(text)}
        end
      end)

    bounded
  end

  defp fingerprint_messages(messages), do: fingerprint(:erlang.term_to_binary(messages))

  defp authorize_member(conversation, participant_id) do
    if member?(conversation, participant_id), do: :ok, else: {:error, :not_conversation_member}
  end

  defp authorize_active(conversation) do
    if conversation.conversation_status in @active_statuses,
      do: :ok,
      else: {:error, :conversation_unavailable}
  end

  defp authorize_safety(conversation, participant_id) do
    if safety_veto?(conversation, participant_id),
      do: {:error, :conversation_unavailable},
      else: :ok
  end

  defp safety_veto?(conversation, participant_id) do
    peer = peer_id(conversation, participant_id)
    is_binary(peer) and MatchingRules.check_safety_veto?(participant_id, peer)
  end

  defp peer_id(conversation, participant_id) do
    cond do
      conversation.participant_a_id == participant_id -> conversation.participant_b_id
      conversation.participant_b_id == participant_id -> conversation.participant_a_id
      true -> nil
    end
  end

  defp member?(conversation, participant_id),
    do: participant_id in [conversation.participant_a_id, conversation.participant_b_id]

  defp normalize_mode(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @modes, do: {:ok, normalized}, else: {:error, :invalid_payload}
  end

  defp normalize_mode(_value), do: {:error, :invalid_payload}

  defp normalize_tone(nil), do: {:ok, "natural"}
  defp normalize_tone(""), do: {:ok, "natural"}

  defp normalize_tone(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @tones, do: {:ok, normalized}, else: {:error, :invalid_payload}
  end

  defp normalize_tone(_value), do: {:error, :invalid_payload}

  defp bounded_optional_text(nil, _limit), do: {:ok, nil}

  defp bounded_optional_text(value, limit) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" -> {:ok, nil}
      String.length(normalized) > limit -> {:error, :invalid_payload}
      true -> {:ok, normalized}
    end
  end

  defp bounded_optional_text(_value, _limit), do: {:error, :invalid_payload}

  defp meaningful_request?(mode, request, draft) do
    mode in ["start", "continue", "recover", "change_topic", "icebreaker", "story_prompt"] or
      is_binary(request) or is_binary(draft)
  end

  defp truncate_text(nil, _limit), do: ""

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit)
  end

  defp fingerprint(nil), do: nil

  defp fingerprint(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))
end
