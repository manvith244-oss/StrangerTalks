defmodule StrangertalksNewWeb.ParticipantController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.ParticipantIssuance
  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.AbuseSource
  alias StrangertalksNewWeb.ParticipantToken

  def create(conn, _params) do
    with {:ok, source} <- AbuseSource.from_conn(conn) do
      attrs = %{
        last_active_at: DateTime.utc_now(),
        created_at: DateTime.utc_now()
      }

      case issuance_context().create(source, attrs, participants_context()) do
        {:ok, participant, source_fingerprint} ->
          conn
          |> put_status(:created)
          |> json(%{
            participant_id: participant.participant_id,
            token: ParticipantToken.sign(participant.participant_id, source_fingerprint)
          })

        {:error, {:rate_limited, _bucket, retry_after_ms}} ->
          conn
          |> put_resp_header(
            "retry-after",
            Integer.to_string(max(1, div(retry_after_ms + 999, 1_000)))
          )
          |> put_status(:too_many_requests)
          |> json(%{error: %{reason: "participant_issuance_rate_limited"}})

        {:error, :enforcement_unavailable} ->
          enforcement_unavailable(conn)

        {:error, {:participant_creation_failed, _reason}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{reason: "participant_creation_failed"}})
      end
    else
      {:error, :source_unavailable} -> enforcement_unavailable(conn)
    end
  end

  defp enforcement_unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: %{reason: "participant_issuance_unavailable"}})
  end

  defp participants_context do
    Application.get_env(:strangertalks_new, :participants_context, Participants)
  end

  defp issuance_context do
    Application.get_env(:strangertalks_new, :participant_issuance_context, ParticipantIssuance)
  end
end
