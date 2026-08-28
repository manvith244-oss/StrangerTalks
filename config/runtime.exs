import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/strangertalks_new start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :strangertalks_new, StrangertalksNewWeb.Endpoint, server: true
end

config :strangertalks_new, StrangertalksNewWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

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

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :strangertalks_new, StrangertalksNew.Repo,
    ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
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
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :strangertalks_new, StrangertalksNewWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :strangertalks_new, StrangertalksNewWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :strangertalks_new, StrangertalksNew.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
