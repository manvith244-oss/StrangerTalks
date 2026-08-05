defmodule StrangertalksNew.Repo.Migrations.CreateMessageReactions do
  use Ecto.Migration

  def change do
    create table(:message_reactions, primary_key: false) do
      # Custom UUID primary key named after the domain
      add :message_reaction_id, :binary_id, primary_key: true

      # Manual timestamps using :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false

      # Explicit foreign keys pointing to custom domain primary keys
      # Deleting a message removes its reactions -> on_delete: :delete_all
      add :message_id,
          references(:messages, column: :message_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :emoji_unicode, :string, null: false
      add :lifecycle_action, :string, null: false
    end

    # CHECK constraint for lifecycle_action enum
    create constraint(:message_reactions, :lifecycle_action_check,
             check: "lifecycle_action IN ('ATTACH', 'DETACH')"
           )

    # Unique composite index to enforce one reaction per participant per message
    create unique_index(:message_reactions, [:message_id, :participant_id],
             name: :message_reactions_message_id_participant_id_index
           )

    # Performance optimization indexes
    create index(:message_reactions, [:message_id])
    create index(:message_reactions, [:participant_id])
    create index(:message_reactions, [:created_at])
  end
end
