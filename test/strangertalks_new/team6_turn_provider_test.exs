defmodule StrangertalksNew.Team6TurnProviderTest do
  use ExUnit.Case, async: false
  alias StrangertalksNew.C11Policy

  test "available provider without legitimate credential config fails closed" do
    state =
      C11Policy.init_state(
        quotas_verified: true,
        primary_available: true,
        fallback_available: false,
        credential_ttl_seconds: 300,
        provider_credentials: %{}
      )

    assert {:error, :provider_not_configured, _} =
             C11Policy.admit_and_reserve(state, "conversation", "attempt")
  end

  test "configured Coturn REST credentials are opaque and relay-only" do
    assert {:ok, creds} =
             C11Policy.authorize_credentials(
               :oracle,
               "raw-conversation",
               "raw-participant",
               "attempt-a",
               300
             )

    assert creds.ice_transport_policy == "relay"

    assert Enum.all?(creds.ice_servers, fn server ->
             Enum.all?(
               List.wrap(server.urls),
               &(String.starts_with?(&1, "turn:") or String.starts_with?(&1, "turns:"))
             )
           end)

    refute inspect(creds) =~ "raw-conversation"
    refute inspect(creds) =~ "raw-participant"
  end

  test "Cloudflare response is stripped to TURN/TURNS entries" do
    assert {:ok, creds} = C11Policy.authorize_credentials(:cloudflare, "c", "p", "attempt-b", 300)
    urls = Enum.flat_map(creds.ice_servers, &List.wrap(&1.urls))
    assert urls != []

    assert Enum.all?(
             urls,
             &(String.starts_with?(&1, "turn:") or String.starts_with?(&1, "turns:"))
           )

    refute Enum.any?(urls, &String.starts_with?(&1, "stun:"))
  end

  test "placeholder production secrets and relay hostname are absent" do
    source = File.read!("lib/strangertalks_new/c11_policy.ex")
    refute source =~ "coturn_ephemeral_key"
    refute source =~ "cf_ephemeral_secret"
    refute source =~ "relay.strangertalks.internal"
  end

  test "malformed provider configuration fails closed" do
    state =
      C11Policy.init_state(
        quotas_verified: true,
        primary_available: true,
        fallback_available: false,
        credential_ttl_seconds: 300,
        provider_credentials: %{
          oracle: %{
            strategy: :coturn_rest,
            urls: ["stun:invalid.example:3478"],
            shared_secret: ""
          }
        }
      )

    assert {:error, :provider_not_configured, _} =
             C11Policy.admit_and_reserve(state, "conversation", "attempt-malformed")
  end

  test "provider secret configuration is server-only" do
    app = File.read!("priv/static/assets/app.js")
    live = File.read!("priv/static/assets/live_call.mjs")
    browser_source = app <> live
    refute browser_source =~ "TURN_ORACLE_SHARED_SECRET"
    refute browser_source =~ "CLOUDFLARE_TURN_API_TOKEN"
    refute browser_source =~ "team6-test-token"
    refute browser_source =~ "team6-test-only-coturn-secret"
  end
end
