defmodule StrangertalksNew.RprProductionMigrationWorkflowContractTest do
  use ExUnit.Case, async: true

  @rehearsal_path ".github/workflows/rpr-production-migration-closure.yml"
  @live_path ".github/workflows/rpr-production-migration-live.yml"
  @backup_path ".github/workflows/postgres-r2-backup.yml"
  @bundled_ca "priv/certs/supabase-prod-ca-2021.crt"
  @migration_tree "d0d1c1a5a781c6dfe504839c2411ef48c7c14a7d"
  @owner_actor "manvith244-oss"

  test "PR rehearsal is incapable of receiving production secrets or mutating production" do
    workflow = File.read!(@rehearsal_path)

    assert workflow =~ "pull_request:"
    assert workflow =~ "EXPECTED_MIGRATIONS_TREE: \"#{@migration_tree}\""
    assert workflow =~ "git rev-parse HEAD:priv/repo/migrations"
    refute workflow =~ "workflow_dispatch:"
    refute workflow =~ "secrets.SUPABASE_DATABASE_URL"
    refute workflow =~ "secrets: inherit"
    refute workflow =~ "migrate-production:"
    refute workflow =~ "APPLY_STRANGERTALKS_PRODUCTION_MIGRATIONS"
  end

  test "live migration is dispatch-only and actor-gated before secret-bearing jobs" do
    workflow = File.read!(@live_path)

    assert workflow =~ "workflow_dispatch:"
    refute workflow =~ "pull_request:"
    assert workflow =~ "github.actor == '#{@owner_actor}'"
    assert workflow =~ "APPLY_STRANGERTALKS_PRODUCTION_MIGRATIONS"
    assert workflow =~ "expected_main_sha"
    assert workflow =~ "needs: backup-before-live-migration"
    assert workflow =~ "EXPECTED_MIGRATIONS_TREE: \"#{@migration_tree}\""
    assert workflow =~ "git rev-parse HEAD:priv/repo/migrations"
    assert workflow =~ "test \"$GITHUB_REF\" = \"refs/heads/main\""
    assert workflow =~ "test \"${{ inputs.expected_main_sha }}\" = \"$GITHUB_SHA\""
    assert workflow =~ @bundled_ca
    assert workflow =~ "PGSSLMODE=verify-full"
    assert workflow =~ "PGSSLROOTCERT"
    assert workflow =~ "sslmode"
    assert workflow =~ "sslrootcert"
    assert workflow =~ "urlsplit"
    assert workflow =~ "parse_qsl"
    refute workflow =~ "SUPABASE_CA_URL"
  end

  test "backup workflow cannot be manually dispatched by an arbitrary repository collaborator" do
    workflow = File.read!(@backup_path)

    assert workflow =~ "workflow_call:"
    assert workflow =~ "schedule:"
    refute workflow =~ "workflow_dispatch:"
    assert workflow =~ "ref: ${{ github.sha }}"
    assert workflow =~ @bundled_ca
    assert workflow =~ "PGSSLMODE=verify-full"
    assert workflow =~ "PGSSLROOTCERT"
    assert workflow =~ "sslmode"
    assert workflow =~ "sslrootcert"
    assert workflow =~ "urlsplit"
    assert workflow =~ "parse_qsl"
  end
end
