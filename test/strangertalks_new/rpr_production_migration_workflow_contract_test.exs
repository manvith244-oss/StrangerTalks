defmodule StrangertalksNew.RprProductionMigrationWorkflowContractTest do
  use ExUnit.Case, async: true

  @runner_path ".github/workflows/rpr-production-migration-closure.yml"
  @backup_path ".github/workflows/postgres-r2-backup.yml"
  @bundled_ca "priv/certs/supabase-prod-ca-2021.crt"

  test "production migration runner stays owner-gated, backup-gated, and pinned to the reviewed migration frontier" do
    workflow = File.read!(@runner_path)

    assert workflow =~ "APPLY_STRANGERTALKS_PRODUCTION_MIGRATIONS"
    assert workflow =~ "expected_main_sha"
    assert workflow =~ "needs: backup-before-live-migration"
    assert workflow =~ "EXPECTED_PRODUCTION_HEAD: \"20260821191324\""
    assert workflow =~ "EXPECTED_REPOSITORY_HEAD: \"20260910192317\""
    assert workflow =~ "test \"$GITHUB_REF\" = \"refs/heads/main\""
    assert workflow =~ "test \"${{ inputs.expected_main_sha }}\" = \"$GITHUB_SHA\""
    assert workflow =~ @bundled_ca
    assert workflow =~ "PGSSLMODE=verify-full"
    assert workflow =~ "PGSSLROOTCERT"

    refute workflow =~ "SUPABASE_CA_URL"
    refute workflow =~ "release/prep-2026-08-22"
  end

  test "backup and restore proof checks out the triggering canonical commit and uses the pinned bundled CA" do
    workflow = File.read!(@backup_path)

    assert workflow =~ "ref: ${{ github.sha }}"
    assert workflow =~ "test \"$(git rev-parse HEAD)\" = \"$GITHUB_SHA\""
    assert workflow =~ @bundled_ca
    assert workflow =~ "807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA"
    assert workflow =~ "PGSSLMODE=verify-full"
    assert workflow =~ "PGSSLROOTCERT"
    assert workflow =~ "ops/postgres_backup.sh"
    assert workflow =~ "ops/postgres_restore.sh"

    refute workflow =~ "release/prep-2026-08-22"
    refute workflow =~ "SUPABASE_CA_URL"
  end
end
