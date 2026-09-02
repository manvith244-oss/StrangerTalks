defmodule StrangertalksNew.GifSearchAuthority do
  @moduledoc false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.Repo

  @active_statuses [:PENDING, :ACTIVE, :PAUSED]

  def capture(conversation_id, participant_id)
      when is_binary(conversation_id) and is_binary(participant_id) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         :ok <- authorize_member(conversation, participant_id),
         :ok <- authorize_active(conversation),
         :ok <- authorize_safety(conversation, participant_id),
         {:ok, runtime_state} <- live_runtime_state(conversation_id) do
      {:ok,
       %{
         conversation_id: conversation_id,
         participant_id: participant_id,
         epoch_id: runtime_state.epoch_id
       }}
    else
      nil -> {:error, :conversation_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :conversation_unavailable}
    end
  end

  def capture(_conversation_id, _participant_id), do: {:error, :invalid_payload}

  def revalidate(%{
        conversation_id: conversation_id,
        participant_id: participant_id,
        epoch_id: epoch_id
      }) do
    with {:ok, current} <- capture(conversation_id, participant_id),
         true <- current.epoch_id == epoch_id do
      :ok
    else
      _ -> {:error, :conversation_stale}
    end
  end

  def revalidate(_), do: {:error, :conversation_stale}

  defp live_runtime_state(conversation_id) do
    case ConversationServer.inspect_state(conversation_id) do
      {:ok, %{lifecycle_status: :ACTIVE, epoch_id: epoch_id} = state} when is_binary(epoch_id) ->
        {:ok, state}

      _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp authorize_member(conversation, participant_id) do
    if participant_id in [conversation.participant_a_id, conversation.participant_b_id],
      do: :ok,
      else: {:error, :not_conversation_member}
  end

  defp authorize_active(conversation) do
    if conversation.conversation_status in @active_statuses,
      do: :ok,
      else: {:error, :conversation_unavailable}
  end

  defp authorize_safety(conversation, participant_id) do
    peer_id =
      cond do
        conversation.participant_a_id == participant_id -> conversation.participant_b_id
        conversation.participant_b_id == participant_id -> conversation.participant_a_id
        true -> nil
      end

    if is_binary(peer_id) and MatchingRules.check_safety_veto?(participant_id, peer_id),
      do: {:error, :conversation_unavailable},
      else: :ok
  end
end
