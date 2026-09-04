defmodule StrangertalksNewWeb.UserSocket do
  use Phoenix.Socket

  alias StrangertalksNew.Participants
  alias StrangertalksNew.RateLimiter
  alias StrangertalksNew.SourceRateLimiter
  alias StrangertalksNewWeb.ParticipantToken

  channel "participant:*", StrangertalksNewWeb.ParticipantChannel
  channel "conversation:*", StrangertalksNewWeb.ConversationChannel

  @impl true
  def connect(_params, socket, %{auth_token: token}) when is_binary(token) do
    with {:ok, authority} <- ParticipantToken.verify_authority(token),
         participant when not is_nil(participant) <-
           Participants.get_participant(authority.participant_id),
         {:ok, source_fingerprint} <- authority_source_fingerprint(authority),
         :ok <-
           SourceRateLimiter.allow_fingerprint(
             source_fingerprint,
             :socket_connect_source,
             60,
             60_000
           ),
         :ok <- RateLimiter.bind_source(participant.participant_id, source_fingerprint) do
      {:ok,
       socket
       |> assign(:participant_id, participant.participant_id)
       |> assign(:account_session_id, Map.get(authority, :account_session_id))}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{account_session_id: account_session_id}})
      when is_binary(account_session_id),
      do: "participant_socket:#{account_session_id}"

  def id(socket), do: "participant_socket:#{socket.assigns.participant_id}"

  defp authority_source_fingerprint(%{
         participant_id: _participant_id,
         source_fingerprint: source_fingerprint
       })
       when is_binary(source_fingerprint) and byte_size(source_fingerprint) == 32,
       do: {:ok, source_fingerprint}

  defp authority_source_fingerprint(%{participant_id: participant_id, source_fingerprint: nil}) do
    SourceRateLimiter.fingerprint({:legacy_participant, participant_id})
  end
end
