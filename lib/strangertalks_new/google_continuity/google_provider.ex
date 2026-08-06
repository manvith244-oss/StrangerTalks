defmodule StrangertalksNew.GoogleContinuity.GoogleProvider do
  @moduledoc false
  @behaviour StrangertalksNew.GoogleContinuity.Provider

  @discovery "https://accounts.google.com/.well-known/openid-configuration"
  @scope "openid https://www.googleapis.com/auth/drive.appdata"

  @impl true
  def authorization_url(state, nonce, mode) do
    config = StrangertalksNew.GoogleContinuity.required_config!()

    query = [
      client_id: config[:client_id],
      redirect_uri: config[:redirect_uri],
      response_type: "code",
      scope: @scope,
      state: state,
      nonce: nonce,
      include_granted_scopes: "true"
    ]

    query =
      if mode == "LINK_CURRENT_GUEST",
        do: query ++ [access_type: "offline", prompt: "consent"],
        else: query

    "https://accounts.google.com/o/oauth2/v2/auth?" <> URI.encode_query(query)
  end

  @impl true
  def exchange_and_verify(code, expected_nonce) do
    config = StrangertalksNew.GoogleContinuity.required_config!()

    with {:ok, %{status: 200, body: tokens}} <-
           Req.post("https://oauth2.googleapis.com/token",
             form: [
               code: code,
               client_id: config[:client_id],
               client_secret: config[:client_secret],
               redirect_uri: config[:redirect_uri],
               grant_type: "authorization_code"
             ]
           ),
         id_token when is_binary(id_token) <- tokens["id_token"],
         {:ok, claims} <- verify_id_token(id_token, config[:client_id], expected_nonce) do
      {:ok,
       %{
         subject: claims["sub"],
         refresh_token: tokens["refresh_token"],
         access_token: tokens["access_token"],
         scopes: String.split(tokens["scope"] || @scope)
       }}
    else
      _ -> {:error, :provider_verification_failed}
    end
  end

  def verify_id_token(token, audience, nonce) do
    with {:ok, %{status: 200, body: discovery}} <- Req.get(@discovery),
         {:ok, %{status: 200, body: %{"keys" => keys}}} <- Req.get(discovery["jwks_uri"]),
         %JOSE.JWS{fields: %{"kid" => kid}} <- JOSE.JWT.peek_protected(token),
         key when not is_nil(key) <- Enum.find(keys, &(&1["kid"] == kid)),
         {true, jwt, _jws} <- JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token),
         claims <- jwt.fields,
         true <- claims["iss"] in ["https://accounts.google.com", "accounts.google.com"],
         true <- valid_audience?(claims["aud"], audience),
         true <- is_integer(claims["exp"]) and claims["exp"] > System.system_time(:second),
         true <- claims["nonce"] == nonce,
         sub when is_binary(sub) and sub != "" <- claims["sub"] do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  @impl true
  def refresh_access_token(refresh_token) do
    config = StrangertalksNew.GoogleContinuity.required_config!()

    case Req.post("https://oauth2.googleapis.com/token",
           form: [
             refresh_token: refresh_token,
             client_id: config[:client_id],
             client_secret: config[:client_secret],
             grant_type: "refresh_token"
           ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      _ -> {:error, :google_reauthorization_required}
    end
  end

  @impl true
  def revoke(refresh_token) do
    case Req.post("https://oauth2.googleapis.com/revoke", form: [token: refresh_token]) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> {:error, :revocation_failed}
    end
  end

  defp valid_audience?(audiences, expected) when is_list(audiences), do: expected in audiences
  defp valid_audience?(audience, expected), do: audience == expected
end
