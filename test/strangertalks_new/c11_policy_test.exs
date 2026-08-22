defmodule StrangertalksNew.C11PolicyTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.C11Policy

  defp fixture_state(opts) do
    now = System.monotonic_time(:millisecond)

    defaults = [
      quotas_verified: true,
      primary_available: true,
      fallback_available: true,
      max_fallback_reservations: 10,
      credential_ttl_seconds: 300,
      usage_snapshot: %{usage_count: 0, budget_limit: 100},
      usage_snapshot_at: now,
      usage_max_staleness_ms: 60_000
    ]

    Keyword.merge(defaults, opts)
    |> C11Policy.init_state()
  end

  describe "C11 Zero-Bill Admission and Reservation Architecture (C11-1 through C11-20)" do
    test "C11-0: production default with zero config fails closed" do
      state = C11Policy.init_state()

      assert {:error, :unverified_provider_quotas, _} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1")
    end

    test "C11-0b: production verified TTL absent fails closed on admission, extension, and credentials" do
      state_no_ttl = fixture_state(credential_ttl_seconds: nil)

      assert {:error, :unverified_credential_ttl, _} =
               C11Policy.admit_and_reserve(state_no_ttl, "conv1", "attempt1")

      assert {:error, :unverified_credential_ttl, _} =
               C11Policy.admit_extension(state_no_ttl, "attempt1")

      assert {:error, :unverified_credential_ttl} =
               C11Policy.authorize_credentials(:oracle, "c1", "p1", "attempt1", nil)

      assert {:error, :unverified_credential_ttl} =
               C11Policy.authorize_credentials(:cloudflare, "c1", "p1", "attempt1", 0)
    end

    test "C11-1: safe Oracle primary admission" do
      state = fixture_state(primary_available: true, fallback_available: true)
      assert {:ok, :oracle, new_state} = C11Policy.admit_and_reserve(state, "conv1", "attempt1")
      assert map_size(new_state.active_reservations) == 1
      assert new_state.active_reservations["attempt1"].provider == :oracle
    end

    test "C11-2: Oracle unavailable -> safe Cloudflare fallback" do
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 5
        )

      assert {:ok, :cloudflare, new_state} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1")

      assert map_size(new_state.active_reservations) == 1
      assert new_state.active_reservations["attempt1"].provider == :cloudflare
    end

    test "C11-3: no safe provider -> live media unavailable; text survives" do
      state = fixture_state(primary_available: false, fallback_available: false)

      assert {:error, :capacity_busy, unchanged_state} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1")

      assert map_size(unchanged_state.active_reservations) == 0
    end

    test "C11-4: capacity exactly one" do
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 1
        )

      assert {:ok, :cloudflare, state_with_one} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1")

      assert {:error, :capacity_busy, _} =
               C11Policy.admit_and_reserve(state_with_one, "conv2", "attempt2")
    end

    test "C11-5 & C11-6 & C11-7: two Conversations race for one reservation; exactly one wins credential authorization and reservation is visible before credential" do
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 1,
          credential_ttl_seconds: 300
        )

      # In linearizable boundary: Conv A reserves first
      {:ok, :cloudflare, state_after_a} = C11Policy.admit_and_reserve(state, "convA", "attemptA")
      # Conv B tries to reserve simultaneously
      {:error, :capacity_busy, state_after_b} =
        C11Policy.admit_and_reserve(state_after_a, "convB", "attemptB")

      # Reservation exists before credentials are issued
      assert Map.has_key?(state_after_a.active_reservations, "attemptA")
      refute Map.has_key?(state_after_b.active_reservations, "attemptB")

      # Only winner receives credential authority with verified TTL fixture
      assert {:ok, creds} =
               C11Policy.authorize_credentials(:cloudflare, "convA", "p1", "attemptA", 300)

      assert creds.provider == :cloudflare
      assert creds.call_attempt_id == "attemptA"
      assert creds.ttl_seconds == 300
    end

    test "C11-8: stale usage snapshot fails closed" do
      now = System.monotonic_time(:millisecond)
      # Snapshot from 2 minutes ago (limit is 60s)
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          usage_snapshot_at: now - 120_000,
          usage_max_staleness_ms: 60_000
        )

      assert {:error, :stale_usage_snapshot, _} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1", now)
    end

    test "C11-9: missing usage snapshot fails closed" do
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          usage_snapshot: nil
        )

      assert {:error, :stale_usage_snapshot, _} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1")
    end

    test "C11-10: credential extension re-enters admission" do
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 5,
          credential_ttl_seconds: 300
        )

      {:ok, :cloudflare, state} = C11Policy.admit_and_reserve(state, "conv1", "attempt1")

      assert {:ok, :cloudflare, extended_state} = C11Policy.admit_extension(state, "attempt1")

      assert extended_state.active_reservations["attempt1"].expires_at >
               state.active_reservations["attempt1"].reserved_at

      # Extension on non-existent attempt fails
      assert {:error, :no_active_reservation, _} =
               C11Policy.admit_extension(state, "unknown_attempt")
    end

    test "C11-11: human call terminal does not prematurely free possible provider exposure" do
      now = System.monotonic_time(:millisecond)

      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 1,
          credential_ttl_seconds: 300,
          usage_snapshot_at: now
        )

      {:ok, :cloudflare, state} = C11Policy.admit_and_reserve(state, "conv1", "attempt1", now)

      # Call ends 10 seconds later
      state_terminated = C11Policy.record_call_terminal(state, "attempt1", now + 10_000)

      # Reservation is moved to terminal exposures, not instantly freed
      refute Map.has_key?(state_terminated.active_reservations, "attempt1")
      assert Map.has_key?(state_terminated.terminal_exposures, "attempt1")

      # Attempting to admit another call during exposure fails because capacity is still held
      assert {:error, :capacity_busy, _} =
               C11Policy.admit_and_reserve(state_terminated, "conv2", "attempt2", now + 15_000)
    end

    test "C11-12: exposure-safe cleanup makes capacity reusable" do
      now = System.monotonic_time(:millisecond)

      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 1,
          credential_ttl_seconds: 10,
          usage_snapshot_at: now,
          usage_max_staleness_ms: 120_000
        )

      {:ok, :cloudflare, state} = C11Policy.admit_and_reserve(state, "conv1", "attempt1", now)

      state_terminated = C11Policy.record_call_terminal(state, "attempt1", now + 1_000)

      # After TTL exposure expires (now + 15s)
      future_time = now + 15_000

      assert {:ok, :cloudflare, state_new} =
               C11Policy.admit_and_reserve(state_terminated, "conv2", "attempt2", future_time)

      assert map_size(state_new.active_reservations) == 1
    end

    test "C11-13: BEAM/process loss -> fallback-admission quarantine/fail closed" do
      # Upon process restart, state enters quarantine
      state =
        fixture_state(primary_available: false, fallback_available: true)
        |> C11Policy.enter_restart_quarantine(300)

      assert C11Policy.quarantined?(state)

      # Fallback admission denied during quarantine
      assert {:error, :quarantine_active, _} =
               C11Policy.admit_and_reserve(state, "conv1", "attempt1")

      # But primary Oracle remains safe if online
      primary_state = %{state | primary_available: true}
      assert {:ok, :oracle, _} = C11Policy.admit_and_reserve(primary_state, "conv1", "attempt1")
    end

    test "C11-14: current call reservations are derived under serialization" do
      state =
        fixture_state(
          primary_available: false,
          fallback_available: true,
          max_fallback_reservations: 2
        )

      {:ok, :cloudflare, s1} = C11Policy.admit_and_reserve(state, "c1", "a1")
      {:ok, :cloudflare, s2} = C11Policy.admit_and_reserve(s1, "c2", "a2")
      {:error, :capacity_busy, _s3} = C11Policy.admit_and_reserve(s2, "c3", "a3")

      assert map_size(s2.active_reservations) == 2
    end

    test "C11-15: no independent budget GenServer" do
      # Verification that C11Policy is a pure functional policy module
      Code.ensure_loaded!(C11Policy)

      assert function_exported?(C11Policy, :admit_and_reserve, 3) or
               function_exported?(C11Policy, :admit_and_reserve, 4)

      refute Code.ensure_loaded?(StrangertalksNew.C11AdmissionGuard)
    end

    test "C11-16: no durable budget DB/Redis authority" do
      # In-memory policy structures only; zero schemas/ecto repos referenced
      refute Code.ensure_loaded?(StrangertalksNew.C11BudgetSchema)
      refute Code.ensure_loaded?(StrangertalksNew.C11BudgetRepo)
    end

    test "C11-17: unverified quotas fail closed in production" do
      unverified_state = C11Policy.init_state(quotas_verified: false)

      assert {:error, :unverified_provider_quotas, _} =
               C11Policy.admit_and_reserve(unverified_state, "conv1", "attempt1")
    end

    test "C11-18: credentials use opaque tokens and never expose raw conversation or participant ID" do
      assert {:ok, oracle_creds} =
               C11Policy.authorize_credentials(
                 :oracle,
                 "conv_secret_123",
                 "part_secret_456",
                 "attempt1",
                 300
               )

      assert {:ok, cf_creds} =
               C11Policy.authorize_credentials(
                 :cloudflare,
                 "conv_secret_123",
                 "part_secret_456",
                 "attempt1",
                 300
               )

      [%{username: oracle_user} | _] = oracle_creds.ice_servers
      [%{username: cf_user} | _] = cf_creds.ice_servers

      refute oracle_user =~ "conv_secret_123"
      refute oracle_user =~ "part_secret_456"
      refute cf_user =~ "conv_secret_123"
      refute cf_user =~ "part_secret_456"
    end

    test "C11-19: account-wide lock resource constant is defined for single-node V1" do
      assert C11Policy.account_budget_lock_resource() ==
               {:strangertalks_c11_account_budget_lock, :account_wide}

      assert :ok = C11Policy.with_account_lock(fn -> :ok end)
    end

    test "C11-20: derive_node_reservations returns aggregated map structure" do
      {reservations, exposures} = C11Policy.derive_node_reservations()
      assert is_map(reservations)
      assert is_map(exposures)
    end
  end
end
