defmodule StrangertalksNew.T06ScheduledOpsLineageTest do
  use ExUnit.Case, async: true

  @retention_workflow ".github/workflows/retention-maintenance.yml"
  @retention_runner "ops/run_retention.sh"
  @precommit_runner "ops/run_precommit_isolated.sh"
  @backup_workflow ".github/workflows/postgres-r2-backup.yml"
  @team1_workflow ".github/workflows/team1-core-authority.yml"
  @candidate_diff_checker "ops/check_candidate_diff.sh"
  @self_relationship_preflight "ops/preflight_distinct_relationship_participants.sh"
  @t06_gate ".github/workflows/t06-ops-001.yml"

  test "retention has one explicit operations-owned scheduled path to the canonical Mix task" do
    assert File.exists?(@retention_workflow),
           "expected #{@retention_workflow} to define the production retention schedule"

    assert File.exists?(@retention_runner),
           "expected #{@retention_runner} to provide the executable retention boundary"

    workflow = File.read!(@retention_workflow)
    runner = File.read!(@retention_runner)

    assert workflow =~ "schedule:"
    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "bash ops/run_retention.sh"
    assert workflow =~ "STRANGERTALKS_RETENTION_ENABLED"
    assert workflow =~ "SUPABASE_DATABASE_URL"
    assert workflow =~ "concurrency:"
    assert workflow =~ "cancel-in-progress: false"
    assert workflow =~ "EXPECTED_SHA"
    assert workflow =~ "ref: ${{ env.EXPECTED_SHA }}"
    assert workflow =~ "git rev-parse HEAD"

    assert runner =~ "DATABASE_URL"
    assert runner =~ "mix strangertalks.retention"
    assert runner =~ "RETENTION_RESULT=PASS"

    refute workflow =~ "RetentionPolicy"
    refute workflow =~ "retention_days"
    refute workflow =~ "RETENTION_DAYS"
    refute runner =~ "RetentionPolicy"
    refute runner =~ "RETENTION_DAYS"
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

  test "Team 1 compares the exact candidate against its actual canonical base, never a frozen historical SHA" do
    assert File.exists?(@candidate_diff_checker)
    workflow = File.read!(@team1_workflow)

    refute workflow =~ "TEAM1_START_SHA"
    refute workflow =~ "e938cdd6e806cc5d05837a9c97755477be95bb27"
    assert workflow =~ "pull_request:\n    branches:\n      - main"
    assert workflow =~ "EXPECTED_TEAM1_COMMIT"
    assert workflow =~ "github.event.pull_request.head.sha || github.sha"
    assert workflow =~ "github.event.pull_request.base.sha"
    assert workflow =~ "git merge-base HEAD origin/main"
    assert workflow =~ "CANDIDATE_BASE_SHA"
    assert workflow =~ "bash ops/check_candidate_diff.sh \"$CANDIDATE_BASE_SHA\" HEAD"

    checker = File.read!(@candidate_diff_checker)
    assert checker =~ "git diff --check \"$base_sha...$candidate_sha\""
    assert checker =~ "git diff --check"
  end

  test "Team 1 diff failure does not suppress clean-tree proof and both failures remain visible" do
    workflow = File.read!(@team1_workflow)

    assert workflow =~ "id: diffcheck"
    assert workflow =~ "id: clean"
    assert workflow =~ "continue-on-error: true"
    assert workflow =~ "if: always()"
    assert workflow =~ "DIFF_EXIT"
    assert workflow =~ "CLEAN_EXIT"
    assert workflow =~ "Fail Team 1 gate if required verification failed"
  end

  test "maintained mutating precommit runs in an exact-SHA worktree without dirtying the proof checkout" do
    assert File.exists?(@precommit_runner)
    runner = File.read!(@precommit_runner)
    team1 = File.read!(@team1_workflow)
    t06 = File.read!(@t06_gate)

    assert runner =~ "EXPECTED_SHA"
    assert runner =~ "worktree add --detach"
    assert runner =~ "mix precommit"
    assert runner =~ "ISOLATED_PRECOMMIT_TESTED_SHA="
    assert runner =~ "ISOLATED_PRECOMMIT_RESULT=PASS"
    assert runner =~ "status --porcelain"

    assert team1 =~ "EXPECTED_SHA=\"$EXPECTED_TEAM1_COMMIT\" bash ops/run_precommit_isolated.sh"
    assert t06 =~ "bash ops/run_precommit_isolated.sh"
  end

  test "self-relationship production preflight is count-only inside an explicit read-only transaction" do
    assert File.exists?(@self_relationship_preflight)
    script = File.read!(@self_relationship_preflight)
    gate = File.read!(@t06_gate)

    assert script =~ "BEGIN TRANSACTION READ ONLY"
    assert script =~ "current_setting('transaction_read_only')"
    assert script =~ "ROLLBACK"
    assert script =~ "SELECT count(*)::bigint"
    assert script =~ "participant_a_id = participant_b_id"
    assert script =~ "READ_ONLY_GUARD=transaction_read_only:on"
    assert script =~ "AUTHORITATIVE_DB_VERIFIED=supabase"
    assert script =~ "SELF_RELATIONSHIP_COUNT="
    assert script =~ "MIGRATION_OPERATIONAL_ELIGIBILITY=ELIGIBLE"
    assert script =~ "OWNER_CONSTRUCTION_COMMAND_DATA_REMEDIATION_DECISION_REQUIRED"
    refute script =~ "SELECT *"
    refute script =~ "DELETE FROM"
    refute script =~ "UPDATE relationships"

    assert gate =~ "SUPABASE_DATABASE_URL"
    assert gate =~ "preflight_distinct_relationship_participants.sh"
    assert gate =~ "SELF_RELATIONSHIP_COUNT"
  end
end
