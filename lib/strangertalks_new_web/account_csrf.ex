defmodule StrangertalksNewWeb.AccountCSRF do
  @moduledoc false

  import Plug.Conn

  @header "x-strangertalks-csrf"
  @domain "strangertalks-account-csrf-v1"

  def token(session) do
    payload = session.session_token_hash <> @domain <> session.account_session_id
    Base.url_encode64(:crypto.mac(:hmac, :sha256, secret(), payload), padding: false)
  end

  def continuity_id(session) do
    Base.url_encode64(
      :crypto.mac(:hmac, :sha256, secret(), "strangertalks-continuity-v1" <> session.account_id),
      padding: false
    )
  end

  def verify(conn, session) do
    with [provided] <- get_req_header(conn, @header),
         true <- same_origin?(conn),
         true <- not cross_site?(conn),
         expected <- token(session),
         true <- byte_size(provided) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(provided, expected) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp same_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin == configured_origin()
      _ -> false
    end
  end

  defp cross_site?(conn), do: get_req_header(conn, "sec-fetch-site") == ["cross-site"]

  defp configured_origin do
    uri = StrangertalksNewWeb.Endpoint.url() |> URI.parse()
    URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})
  end

  defp secret do
    StrangertalksNewWeb.Endpoint.config(:secret_key_base)
    |> Plug.Crypto.KeyGenerator.generate("account-csrf", length: 32)
  end
end
