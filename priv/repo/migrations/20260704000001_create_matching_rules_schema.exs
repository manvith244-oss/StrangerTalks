# filepath: priv/repo/migrations/20260704000001_create_matching_rules_schema.exs
defmodule StrangertalksNew.Repo.Migrations.CreateMatchingRulesSchema do
  use Ecto.Migration

  def change do
    # 1. Alter table safely without duplicating "presence_state"
    alter table(:participants) do
      # Add only the missing core column
      add :current_door, :string, size: 50, null: true, default: nil

      # Add the new analytics tracking fields from the Matching Rules spec
      add :bootstrap_sessions_completed, :integer, null: false, default: 0
      add :is_bootstrap_frozen, :boolean, null: false, default: false
      add :frozen_reentry_count, :integer, null: false, default: 0
      add :last_freeze_at, :utc_datetime_usec, null: true, default: nil
    end

    # Enforce Check Constraints for Participants (Section 11)
    create constraint(:participants, :chk_door_type,
             check: "current_door IN ('JUST_TALK', 'KEEP_IT_LIGHT', 'EXPLORE', 'SOMETHING_REAL')"
           )

    create constraint(:participants, :chk_presence_state,
             check:
               "presence_state IN ('ONLINE', 'MATCHING', 'IN_CONVERSATION', 'VIEWING_MEMORIES', 'VIEWING_RELATIONSHIPS', 'OFFLINE')"
           )

    # 2. Create QueueState (Persisted Telemetry Mapping Schema)
    create table(:queue_states, primary_key: false) do
      add :queue_state_id, :uuid, primary_key: true, null: false

      add :participant_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :delete_all),
          null: false

      add :readiness_snapshot_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :intent_vibe_vector, :map, null: false
      add :wait_duration_seconds, :integer, null: false, default: 0
      add :matched_strategy_applied, :string, size: 50, null: false
    end

    # Enforce Check Constraints for QueueState (Section 11)
    create constraint(:queue_states, :chk_match_strategy,
             check:
               "matched_strategy_applied IN ('BOOTSTRAP', 'COMPATIBILITY', 'OPPORTUNITY', 'SCARCITY', 'MANUAL_OVERRIDE')"
           )

    # 3. Create BoundaryBlocks Table
    create table(:boundary_blocks, primary_key: false) do
      add :blocker_user_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :blocked_user_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :created_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :timestamp, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :source_surface, :string, size: 50, null: false
      add :active_status, :boolean, null: false, default: true
    end

    # 4. Mandatory Sub-Millisecond Performance Indices (Section 11)
    create index(:participants, [:presence_state],
             name: :idx_participants_presence,
             where: "presence_state = 'MATCHING'"
           )

    # CANONICAL FIX: Standard keyword list mapping array without outer nested structures
    create index(:queue_states, [desc: :readiness_snapshot_at], name: :idx_queue_state_telemetry)

    create index(:boundary_blocks, [:blocker_user_id, :active_status],
             name: :idx_boundary_blocks_lookup
           )
  end
end
