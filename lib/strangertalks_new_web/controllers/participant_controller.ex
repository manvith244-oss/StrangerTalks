defmodule StrangertalksNewWeb.ParticipantController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.ParticipantToken

  def create(conn, _params) do
    case participants_context().create_participant(%{
           last_active_at: DateTime.utc_now(),
           created_at: DateTime.utc_now()
         }) do
      {:ok, participant} ->
        conn
        |> put_status(:created)
        |> json(%{
          participant_id: participant.participant_id,
          token: ParticipantToken.sign(participant.participant_id)
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{reason: "participant_creation_failed"}})
    end
  end

  defp participants_context do
    Application.get_env(:strangertalks_new, :participants_context, Participants)
  end
end
