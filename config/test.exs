import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
repo_pool =
  if System.get_env("STRANGERTALKS_PERSISTENT_TEST_SERVER") == "1" do
    DBConnection.ConnectionPool
  else
    Ecto.Adapters.SQL.Sandbox
  end

config :strangertalks_new, StrangertalksNew.Repo,
  username: System.get_env("STRANGERTALKS_LOCAL_DB_USER", "strangertalks_local"),
  password: System.get_env("STRANGERTALKS_LOCAL_DB_PASSWORD"),
  hostname: "localhost",
  database: "strangertalks_new_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: repo_pool,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
test_port = String.to_integer(System.get_env("PORT", "4002"))

config :strangertalks_new, StrangertalksNewWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: test_port
  ],
  # Keep WebSocket CSRF origin validation enabled. The isolated browser harness
  # uses 127.0.0.1 while the default endpoint URL is localhost; permit only the
  # two local loopback origins on this test port, never arbitrary origins.
  check_origin: ["http://127.0.0.1:#{test_port}", "http://localhost:#{test_port}"],
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

# Only the disposable real-browser Phoenix server multiplexes many synthetic
# browser contexts through 127.0.0.1. Keep bounded source admission enabled,
# but budget for the test matrix instead of exhausting the production 6/min IP
# quota. All ordinary mix tests retain ParticipantIssuance's production defaults.
if System.get_env("STRANGERTALKS_PERSISTENT_TEST_SERVER") == "1" do
  config :strangertalks_new, :participant_issuance_policies, [
    {:participant_issuance_burst, 200, 60_000},
    {:participant_recent_identity_slots, 500, 15 * 60_000},
    {:participant_identity_rotation, 1_000, 60 * 60_000}
  ]
end

# Existing Hangouts tests explicitly exercise enabled mode in a disposable test DB.
# Production public Hangouts admission remains default-off without the approved flag.
config :strangertalks_new, :hangouts_public_beta_enabled, true
