defmodule StrangertalksNew.Repo.Migrations.EnforceDistinctRelationshipParticipantsC3 do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM relationships
        WHERE participant_a_id = participant_b_id
      ) THEN
        RAISE EXCEPTION 'Cannot enforce distinct Relationship participants: self-Relationships exist';
      END IF;
    END $$;
    """)

    create constraint(:relationships, :relationships_distinct_participants_check,
             check: "participant_a_id <> participant_b_id"
           )
  end

  def down do
    drop constraint(:relationships, :relationships_distinct_participants_check)
  end
end
