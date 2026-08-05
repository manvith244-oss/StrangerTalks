defmodule StrangertalksNewWeb.ParticipantChannel do
  use Phoenix.Channel

  alias StrangertalksNew.Participants

  def join("participant:lobby", _params, socket) do
    {:ok, socket}
  end

  def handle_in("create", _params, socket) do
    case Participants.create_participant(%{
           last_active_at: DateTime.utc_now(),
           created_at: DateTime.utc_now()
         }) do
      {:ok, participant} ->
        {:reply, {:ok, %{participant_id: participant.participant_id}}, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "could not create participant"}}, socket}
    end
  end

  def handle_in("get", %{"participant_id" => id}, socket) do
    case Participants.get_participant(id) do
      nil ->
        {:reply, {:error, %{reason: "not found"}}, socket}

      participant ->
        {:reply,
         {:ok,
          %{
            participant_id: participant.participant_id,
            presence_state: participant.presence_state
          }}, socket}
    end
  end
end
