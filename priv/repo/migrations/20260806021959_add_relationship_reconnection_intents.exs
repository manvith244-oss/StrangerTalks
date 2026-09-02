defmodule StrangertalksNew.Repo.Migrations.AddRelationshipReconnectionIntents do
  use Ecto.Migration

  def up do
    create table(:relationship_reconnection_intents, primary_key: false) do
      add :reconnect_intent_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :relationship_id,
          references(:relationships,
            type: :uuid,
            column: :relationship_id,
            on_delete: :delete_all
          ),
          null: false

      add :participant_id,
          references(:participants, type: :uuid, column: :participant_id, on_delete: :delete_all),
          null: false

      add :door_type, :string, null: false
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
    end

    create constraint(
             :relationship_reconnection_intents,
             :relationship_reconnection_intents_door_check,
             check: "door_type IN ('JUST_TALK','KEEP_IT_LIGHT','EXPLORE','SOMETHING_REAL')"
           )

    create constraint(
             :relationship_reconnection_intents,
             :relationship_reconnection_intents_status_check,
             check: "status IN ('ACTIVE','CONSUMED','CANCELLED','EXPIRED')"
           )

    create unique_index(:relationship_reconnection_intents, [:relationship_id, :participant_id],
             where: "status = 'ACTIVE'",
             name: :relationship_reconnection_intents_one_active_index
           )

    create index(:relationship_reconnection_intents, [:relationship_id, :status, :expires_at],
             name: :relationship_reconnection_intents_matching_index
           )

    drop constraint(:matches, :match_strategy_check)

    alter table(:matches) do
      modify :compatibility_score, :decimal,
        precision: 5,
        scale: 4,
        null: true,
        from: {:decimal, precision: 5, scale: 4, null: false}
    end

    create constraint(:matches, :match_strategy_check,
             check:
               "match_strategy IN ('COMPATIBILITY','OPPORTUNITY','SCARCITY','MANUAL_OVERRIDE','RELATIONSHIP_RECONNECT_V1')"
           )

    create constraint(:matches, :matches_compatibility_by_strategy_check,
             check:
               "(match_strategy = 'RELATIONSHIP_RECONNECT_V1' AND compatibility_score IS NULL) OR (match_strategy <> 'RELATIONSHIP_RECONNECT_V1' AND compatibility_score IS NOT NULL)"
           )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM matches WHERE match_strategy = 'RELATIONSHIP_RECONNECT_V1'
      ) THEN
        RAISE EXCEPTION 'cannot roll back bond reconnection migration while reconnect Match rows exist';
      END IF;
    END
    $$
    """)

    drop constraint(:matches, :matches_compatibility_by_strategy_check)
    drop constraint(:matches, :match_strategy_check)

    alter table(:matches) do
      modify :compatibility_score, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        from: {:decimal, precision: 5, scale: 4, null: true}
    end

    create constraint(:matches, :match_strategy_check,
             check:
               "match_strategy IN ('COMPATIBILITY','OPPORTUNITY','SCARCITY','MANUAL_OVERRIDE')"
           )

    drop table(:relationship_reconnection_intents)
  end
end
