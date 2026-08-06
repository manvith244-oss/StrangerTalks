defmodule StrangertalksNew.GoogleContinuity.GoogleProvider do
  @moduledoc false
  @behaviour StrangertalksNew.GoogleContinuity.Provider

  @discovery "https://accounts.google.com/.well-known/openid-configuration"
  @scope "openid https://www.googleapis.com/auth/drive.appdata"
  @drive_api "https://www.googleapis.com/drive/v3/files"
  @drive_upload "https://www.googleapis.com/upload/drive/v3/files"
  @sync_name "strangertalks-sync-v1.enc.json"
  @clock_skew_seconds 60

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
         {:ok, %{status: 200, body: %{"keys" => keys}}} <- Req.get(discovery["jwks_uri"]) do
      verify_id_token_with_keys(token, audience, nonce, keys)
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  def verify_id_token_with_keys(token, audience, nonce, keys, now \\ System.system_time(:second)) do
    with %JOSE.JWS{fields: %{"kid" => kid}} <- JOSE.JWT.peek_protected(token),
         key when not is_nil(key) <- Enum.find(keys, &(&1["kid"] == kid)),
         {true, jwt, _jws} <- JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token),
         claims <- jwt.fields,
         true <- claims["iss"] in ["https://accounts.google.com", "accounts.google.com"],
         true <- valid_audience?(claims, audience),
         true <- is_integer(claims["exp"]) and claims["exp"] >= now - @clock_skew_seconds,
         true <- is_integer(claims["iat"]) and claims["iat"] <= now + @clock_skew_seconds,
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
      {:ok, %{status: 400}} -> :already_revoked
      _ -> {:error, :revocation_failed}
    end
  end

  @impl true
  def find_sync_file(access_token) do
    query =
      "name = '#{@sync_name}' and 'appDataFolder' in parents and trashed = false and appProperties has { key='strangertalks_kind' and value='account_sync' }"

    url =
      @drive_api <>
        "?" <>
        URI.encode_query(
          spaces: "appDataFolder",
          q: query,
          fields: "files(id,name,appProperties)"
        )

    case Req.get(url, headers: auth(access_token)) do
      {:ok, %{status: 200, body: %{"files" => []}}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: %{"files" => [file]}}} ->
        {:ok, file}

      {:ok, %{status: 200, body: %{"files" => files}}} when length(files) > 1 ->
        {:error, :ambiguous_sync_files}

      _ ->
        {:error, :drive_unavailable}
    end
  end

  @impl true
  def download_sync_file(access_token, file_id) do
    case Req.get("#{@drive_api}/#{URI.encode_www_form(file_id)}?alt=media",
           headers: auth(access_token)
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :sync_file_not_found}
      _ -> {:error, :drive_unavailable}
    end
  end

  @impl true
  def create_sync_file(access_token, envelope) do
    metadata = %{
      name: @sync_name,
      parents: ["appDataFolder"],
      mimeType: "application/json",
      appProperties: %{strangertalks_kind: "account_sync", schema_version: "1"}
    }

    with {:ok, %{status: status, headers: headers}} when status in 200..299 <-
           Req.post(@drive_upload <> "?uploadType=resumable&fields=id",
             headers:
               auth(access_token) ++
                 [
                   {"content-type", "application/json; charset=UTF-8"},
                   {"x-upload-content-type", "application/json"}
                 ],
             json: metadata
           ),
         upload_url when is_binary(upload_url) <- header(headers, "location"),
         {:ok, %{status: upload_status, body: %{"id" => file_id}}} when upload_status in 200..299 <-
           Req.put(upload_url,
             headers: [{"content-type", "application/json"}],
             body: Jason.encode!(envelope)
           ) do
      {:ok, file_id}
    else
      _ -> {:error, :drive_unavailable}
    end
  end

  @impl true
  def update_sync_file(access_token, file_id, envelope) do
    case Req.patch("#{@drive_upload}/#{URI.encode_www_form(file_id)}?uploadType=media",
           headers: auth(access_token) ++ [{"content-type", "application/json"}],
           body: Jason.encode!(envelope)
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :sync_file_not_found}
      _ -> {:error, :drive_unavailable}
    end
  end

  @impl true
  def delete_sync_file(access_token, file_id) do
    case Req.delete("#{@drive_api}/#{URI.encode_www_form(file_id)}", headers: auth(access_token)) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      _ -> {:error, :drive_unavailable}
    end
  end

  defp valid_audience?(%{"aud" => audiences, "azp" => expected}, expected)
       when is_list(audiences),
       do: expected in audiences

  defp valid_audience?(%{"aud" => audiences}, _expected) when is_list(audiences), do: false
  defp valid_audience?(%{"aud" => audience}, expected), do: audience == expected
  defp auth(token), do: [{"authorization", "Bearer #{token}"}]

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn {key, values} ->
      if String.downcase(key) == name, do: List.first(List.wrap(values))
    end)
  end
end
