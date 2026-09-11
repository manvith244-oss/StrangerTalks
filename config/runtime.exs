import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

if System.get_env("PHX_SERVER") do
  config :strangertalks_new, StrangertalksNewWeb.Endpoint, server: true
end

config :strangertalks_new, StrangertalksNewWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

hearth_standalone =
  System.get_env("EXPERIMENT_HEARTH_STANDALONE", "false") in ["true", "1"]

config :strangertalks_new, :experiment_hearth_standalone, hearth_standalone

google_continuity_enabled = System.get_env("GOOGLE_CONTINUITY_ENABLED", "false") in ["true", "1"]

google_continuity = [
  enabled: google_continuity_enabled,
  client_id: System.get_env("GOOGLE_OAUTH_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_OAUTH_CLIENT_SECRET"),
  redirect_uri: System.get_env("GOOGLE_OAUTH_REDIRECT_URI"),
  subject_hmac_key: System.get_env("GOOGLE_SUBJECT_HMAC_KEY"),
  refresh_token_encryption_key: System.get_env("GOOGLE_REFRESH_TOKEN_ENCRYPTION_KEY")
]

if google_continuity_enabled do
  Enum.each(
    [:client_id, :client_secret, :redirect_uri, :subject_hmac_key, :refresh_token_encryption_key],
    fn key ->
      if not is_binary(google_continuity[key]) or google_continuity[key] == "" do
        raise "GOOGLE_CONTINUITY_ENABLED requires #{key} configuration"
      end
    end
  )

  case Base.decode64(google_continuity[:refresh_token_encryption_key]) do
    {:ok, key} when byte_size(key) == 32 -> :ok
    _ -> raise "GOOGLE_REFRESH_TOKEN_ENCRYPTION_KEY must be Base64 for exactly 32 bytes"
  end

  case Base.decode64(google_continuity[:subject_hmac_key]) do
    {:ok, key} when byte_size(key) == 32 -> :ok
    _ -> raise "GOOGLE_SUBJECT_HMAC_KEY must be Base64 for exactly 32 bytes"
  end
end

config :strangertalks_new, :google_continuity, google_continuity

if config_env() == :prod do
  turn_oracle_urls =
    System.get_env("TURN_ORACLE_URLS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  turn_oracle_secret = System.get_env("TURN_ORACLE_SHARED_SECRET")
  cloudflare_turn_key_id = System.get_env("CLOUDFLARE_TURN_KEY_ID")
  cloudflare_turn_api_token = System.get_env("CLOUDFLARE_TURN_API_TOKEN")

  turn_provider_credentials = %{}

  turn_provider_credentials =
    if turn_oracle_urls != [] and is_binary(turn_oracle_secret) and turn_oracle_secret != "" do
      Map.put(turn_provider_credentials, :oracle, %{
        strategy: :coturn_rest,
        urls: turn_oracle_urls,
        shared_secret: turn_oracle_secret
      })
    else
      turn_provider_credentials
    end

  turn_provider_credentials =
    if is_binary(cloudflare_turn_key_id) and cloudflare_turn_key_id != "" and
         is_binary(cloudflare_turn_api_token) and cloudflare_turn_api_token != "" do
      Map.put(turn_provider_credentials, :cloudflare, %{
        strategy: :cloudflare_api,
        key_id: cloudflare_turn_key_id,
        api_token: cloudflare_turn_api_token,
        endpoint: "https://rtc.live.cloudflare.com"
      })
    else
      turn_provider_credentials
    end

  config :strangertalks_new, :turn_provider_credentials, turn_provider_credentials
end

if config_env() == :prod and not hearth_standalone do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  database_host =
    case URI.parse(database_url).host do
      host when is_binary(host) and host != "" ->
        host

      _ ->
        raise "DATABASE_URL must include a database hostname for TLS certificate verification"
    end

  database_ca_options =
    case System.get_env("DB_CA_CERT_FILE") do
      nil ->
        case :public_key.cacerts_get() do
          certs when is_list(certs) and certs != [] ->
            [cacerts: certs]

          _ ->
            raise "production database TLS requires trusted system CA certificates"
        end

      "" ->
        raise "DB_CA_CERT_FILE must not be blank when configured"

      path ->
        if File.regular?(path) do
          case File.open(path, [:read]) do
            {:ok, device} ->
              File.close(device)
              [cacertfile: path]

            {:error, _reason} ->
              raise "DB_CA_CERT_FILE must point to a readable regular CA bundle file"
          end
        else
          raise "DB_CA_CERT_FILE must point to a readable regular CA bundle file"
        end
    end

  database_ssl_options =
    [
      verify: :verify_peer,
      server_name_indication: String.to_charlist(database_host)
    ] ++ database_ca_options

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :strangertalks_new, StrangertalksNew.Repo,
    ssl: database_ssl_options,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname for this release.
      """

  log_level =
    case System.get_env("LOG_LEVEL", "info") do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      _invalid -> raise "environment variable LOG_LEVEL has an unsupported value"
    end

  config :logger, level: log_level

  config :strangertalks_new, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :strangertalks_new, StrangertalksNewWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
