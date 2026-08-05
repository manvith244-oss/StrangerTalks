defmodule StrangertalksNewWeb.UserSocket do
  use Phoenix.Socket

  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.ParticipantToken

  channel "participant:*", StrangertalksNewWeb.ParticipantChannel
  channel "conversation:*", StrangertalksNewWeb.ConversationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    with {:ok, participant_id} <- ParticipantToken.verify(token),
         participant when not is_nil(participant) <- Participants.get_participant(participant_id) do
      {:ok, assign(socket, :participant_id, participant.participant_id)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "participant_socket:#{socket.assigns.participant_id}"
end
