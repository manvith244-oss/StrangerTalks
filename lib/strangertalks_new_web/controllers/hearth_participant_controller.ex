defmodule StrangertalksNewWeb.HearthParticipantController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Experiments.Hearth.Runtime
  alias StrangertalksNewWeb.{AbuseSource, Endpoint, HearthChannel, HearthToken}

  def create(conn, _params) do
    with true <- Runtime.standalone?(),
         true <- HearthChannel.enabled?(),
         {:ok, source} <- AbuseSource.from_conn(conn),
         {:ok, fingerprint} <- fingerprint(source) do
      participant_id = Ecto.UUID.generate()

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:created)
      |> json(%{
        participant_id: participant_id,
        token: HearthToken.sign(participant_id, fingerprint)
      })
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not Found")
    end
  end

  defp fingerprint(source) do
    case Endpoint.config(:secret_key_base) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok,
         :crypto.mac(:hmac, :sha256, secret, :erlang.term_to_binary({:hearth_source_v1, source}))}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end
end
