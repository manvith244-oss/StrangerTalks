import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :strangertalks_new, StrangertalksNew.Repo,
  username: System.get_env("STRANGERTALKS_LOCAL_DB_USER", "strangertalks_local"),
  password: System.get_env("STRANGERTALKS_LOCAL_DB_PASSWORD"),
  hostname: "localhost",
  database: "strangertalks_new_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :strangertalks_new, StrangertalksNewWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "mfafzOU4EbAel4JLxny9QB4VWYDuUr8ZpaIyBpUkWOQEgQi1RcRQKADLWXmTAOgj",
  server: false

# In test we don't send emails
config :strangertalks_new, StrangertalksNew.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Team 10 deterministic test-only GIF provider. Production remains disabled unless
# a real server-side adapter and media-host allowlist are configured.
config :strangertalks_new,
  gif_provider_adapter: StrangertalksNew.TestGifProvider,
  gif_media_hosts: ["media.example.test"],
  gif_provider_timeout_ms: 75

# Live Communication Suite C11 Policy Test Fixture
config :strangertalks_new, :c11_policy,
  quotas_verified: true,
  primary_available: true,
  fallback_available: true,
  max_fallback_reservations: 10,
  credential_ttl_seconds: 300,
  usage_snapshot: %{usage_count: 0, budget_limit: 100}

config :strangertalks_new, :turn_provider_credentials, %{
  oracle: %{
    strategy: :coturn_rest,
    urls: ["turn:127.0.0.1:3478?transport=udp"],
    shared_secret: "team6-test-only-coturn-secret"
  },
  cloudflare: %{
    strategy: :cloudflare_api,
    key_id: "team6-test-key-id",
    api_token: "team6-test-token",
    client: StrangertalksNew.TurnCredentialTestClient
  }
}
