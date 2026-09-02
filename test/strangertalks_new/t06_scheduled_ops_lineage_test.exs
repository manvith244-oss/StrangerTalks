defmodule StrangertalksNew.T06ScheduledOpsLineageTest do
  use ExUnit.Case, async: true

  @retention_workflow ".github/workflows/retention-maintenance.yml"
  @backup_workflow ".github/workflows/postgres-r2-backup.yml"

  test "retention has one explicit operations-owned scheduled path to the canonical Mix task" do
    assert File.exists?(@retention_workflow),
           "expected #{@retention_workflow} to define the production retention schedule"

    workflow = File.read!(@retention_workflow)

    assert workflow =~ "schedule:"
    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "mix strangertalks.retention"
    assert workflow =~ "STRANGERTALKS_RETENTION_ENABLED"
    assert workflow =~ "SUPABASE_DATABASE_URL"
    assert workflow =~ "concurrency:"
    assert workflow =~ "cancel-in-progress: false"
    assert workflow =~ "EXPECTED_SHA"
    assert workflow =~ "ref: ${{ env.EXPECTED_SHA }}"
    assert workflow =~ "git rev-parse HEAD"

    refute workflow =~ "RetentionPolicy"
    refute workflow =~ "retention_days"
    refute workflow =~ "RETENTION_DAYS"
  end

  test "backup workflow executes operational scripts from its exact workflow source SHA" do
    workflow = File.read!(@backup_workflow)

    refute workflow =~ "release/prep-2026-08-22"
    assert workflow =~ "WORKFLOW_SOURCE_SHA"
    assert workflow =~ "CHECKED_OUT_OPS_SHA"
    assert workflow =~ "ref: ${{ github.sha }}"
    assert workflow =~ "test \"$checked_out_sha\" = \"$GITHUB_SHA\""
    assert workflow =~ "ops/postgres_backup.sh"
    assert workflow =~ "ops/postgres_restore.sh"
  end

  test "backup lineage change preserves the existing R2 round-trip and scratch restore proof" do
    workflow = File.read!(@backup_workflow)

    for required <- [
          "read_only_dump",
          "sha256sum",
          "aws s3 cp",
          "phase2_r2_roundtrip_integrity=true",
          "phase2_restore_from_r2_completed=true",
          "phase2_table_sets_match=true",
          "phase2_row_counts_match=true",
          "phase2_schema_match=true",
          "PHASE2_RESTORE_PROOF=PASS"
        ] do
      assert workflow =~ required, "backup workflow lost required proof marker #{required}"
    end
  end
end
