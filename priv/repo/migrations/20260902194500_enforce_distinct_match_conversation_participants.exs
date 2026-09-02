defmodule StrangertalksNew.Repo.Migrations.EnforceDistinctMatchConversationParticipants do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM matches
        WHERE participant_a_id = participant_b_id
      ) THEN
        RAISE EXCEPTION 'Cannot enforce distinct Match participants: self-Matches exist';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM conversations
        WHERE participant_a_id = participant_b_id
      ) THEN
        RAISE EXCEPTION 'Cannot enforce distinct Conversation participants: self-Conversations exist';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM conversations AS c
        JOIN matches AS m ON m.match_id = c.match_id
        WHERE c.participant_a_id IS DISTINCT FROM m.participant_a_id
           OR c.participant_b_id IS DISTINCT FROM m.participant_b_id
      ) THEN
        RAISE EXCEPTION 'Cannot enforce Match/Conversation participant consistency: mismatched durable rows exist';
      END IF;
    END $$;
    """)

    create constraint(:matches, :matches_distinct_participants_check,
             check: "participant_a_id <> participant_b_id"
           )

    create constraint(:conversations, :conversations_distinct_participants_check,
             check: "participant_a_id <> participant_b_id"
           )

    create unique_index(:matches, [:match_id, :participant_a_id, :participant_b_id],
             name: :matches_match_participants_unique_index
           )

    execute("""
    ALTER TABLE conversations
      ADD CONSTRAINT conversations_match_participants_fkey
      FOREIGN KEY (match_id, participant_a_id, participant_b_id)
      REFERENCES matches (match_id, participant_a_id, participant_b_id)
      ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE conversations
      DROP CONSTRAINT conversations_match_participants_fkey
    """)

    drop index(:matches, [:match_id, :participant_a_id, :participant_b_id],
           name: :matches_match_participants_unique_index
         )

    drop constraint(:conversations, :conversations_distinct_participants_check)
    drop constraint(:matches, :matches_distinct_participants_check)
  end
end
