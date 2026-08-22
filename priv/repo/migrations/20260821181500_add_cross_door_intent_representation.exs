defmodule StrangertalksNew.Repo.Migrations.AddCrossDoorIntentRepresentation do
  use Ecto.Migration

  def up do
    alter table(:matches) do
      add :participant_a_door_type, :string
      add :participant_b_door_type, :string
      modify :door_type, :string, null: true
    end

    alter table(:conversations) do
      modify :door_type, :string, null: true
    end

    alter table(:relationships) do
      add :origin_participant_a_door_type, :string
      add :origin_participant_b_door_type, :string
      modify :origin_door_type, :string, null: true
    end

    # Historical rows predate cross-Door matching, so the common Door is
    # truthful for both participant slots.
    execute "UPDATE matches SET participant_a_door_type = door_type, participant_b_door_type = door_type"

    execute "UPDATE relationships SET origin_participant_a_door_type = origin_door_type, origin_participant_b_door_type = origin_door_type"

    alter table(:matches) do
      modify :participant_a_door_type, :string, null: false
      modify :participant_b_door_type, :string, null: false
    end

    alter table(:relationships) do
      modify :origin_participant_a_door_type, :string, null: false
      modify :origin_participant_b_door_type, :string, null: false
    end

    create constraint(:matches, :participant_a_door_type_check,
             check:
               "participant_a_door_type IN ('JUST_TALK','KEEP_IT_LIGHT','EXPLORE','SOMETHING_REAL')"
           )

    create constraint(:matches, :participant_b_door_type_check,
             check:
               "participant_b_door_type IN ('JUST_TALK','KEEP_IT_LIGHT','EXPLORE','SOMETHING_REAL')"
           )

    create constraint(:relationships, :origin_participant_a_door_type_check,
             check:
               "origin_participant_a_door_type IN ('JUST_TALK','KEEP_IT_LIGHT','EXPLORE','SOMETHING_REAL')"
           )

    create constraint(:relationships, :origin_participant_b_door_type_check,
             check:
               "origin_participant_b_door_type IN ('JUST_TALK','KEEP_IT_LIGHT','EXPLORE','SOMETHING_REAL')"
           )
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM matches
        WHERE participant_a_door_type <> participant_b_door_type
      ) OR EXISTS (
        SELECT 1
        FROM relationships
        WHERE origin_participant_a_door_type <> origin_participant_b_door_type
      ) THEN
        RAISE EXCEPTION
          'cannot rollback cross-door intent representation while cross-door records exist';
      END IF;
    END
    $$
    """

    execute "UPDATE matches SET door_type = participant_a_door_type WHERE door_type IS NULL"

    execute "UPDATE conversations AS c SET door_type = m.participant_a_door_type FROM matches AS m WHERE c.match_id = m.match_id AND c.door_type IS NULL"

    execute "UPDATE relationships SET origin_door_type = origin_participant_a_door_type WHERE origin_door_type IS NULL"

    drop constraint(:relationships, :origin_participant_b_door_type_check)
    drop constraint(:relationships, :origin_participant_a_door_type_check)
    drop constraint(:matches, :participant_b_door_type_check)
    drop constraint(:matches, :participant_a_door_type_check)

    alter table(:relationships) do
      modify :origin_door_type, :string, null: false
      remove :origin_participant_b_door_type
      remove :origin_participant_a_door_type
    end

    alter table(:conversations) do
      modify :door_type, :string, null: false
    end

    alter table(:matches) do
      modify :door_type, :string, null: false
      remove :participant_b_door_type
      remove :participant_a_door_type
    end
  end
end
