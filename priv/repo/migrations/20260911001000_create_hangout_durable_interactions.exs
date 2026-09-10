defmodule StrangertalksNew.Repo.Migrations.CreateHangoutDurableInteractions do
  use Ecto.Migration

  def change do
    create table(:hangout_content_items, primary_key: false) do
      add :content_id, :string, primary_key: true
      add :kind, :string, null: false
      add :language_tag, :string, null: false
      add :source, :string, null: false
      add :safety_status, :string, null: false
      add :publication_status, :string, null: false
      add :body, :text, null: false
      add :options, {:array, :string}, null: false, default: []
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:hangout_room_content, primary_key: false) do
      add :room_content_id, :binary_id, primary_key: true

      add :room_id,
          references(:hangout_rooms, column: :room_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :content_id,
          references(:hangout_content_items,
            column: :content_id,
            type: :string,
            on_delete: :restrict
          ),
          null: false

      add :sequence, :bigint, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :kind, :string, null: false
      add :language_tag, :string, null: false
      add :source, :string, null: false
      add :safety_status, :string, null: false
      add :publication_status, :string, null: false
      add :body, :text, null: false
      add :options, {:array, :string}, null: false, default: []
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:hangout_room_content, [:room_id, :sequence],
             name: :hangout_room_content_room_sequence_index
           )

    create index(:hangout_room_content, [:room_id, :content_id])

    create constraint(:hangout_room_content, :hangout_room_content_sequence_positive_check,
             check: "sequence > 0"
           )

    create table(:hangout_reactions, primary_key: false) do
      add :reaction_id, :binary_id, primary_key: true

      add :room_id,
          references(:hangout_rooms, column: :room_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :room_content_id,
          references(:hangout_room_content,
            column: :room_content_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :membership_id,
          references(:hangout_memberships,
            column: :membership_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :reaction, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:hangout_reactions, [:room_content_id, :membership_id],
             name: :hangout_reactions_content_membership_index
           )

    create index(:hangout_reactions, [:room_id, :room_content_id])

    create table(:hangout_skip_votes, primary_key: false) do
      add :skip_vote_id, :binary_id, primary_key: true

      add :room_id,
          references(:hangout_rooms, column: :room_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :room_content_id,
          references(:hangout_room_content,
            column: :room_content_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :membership_id,
          references(:hangout_memberships,
            column: :membership_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:hangout_skip_votes, [:room_content_id, :membership_id],
             name: :hangout_skip_votes_content_membership_index
           )

    create index(:hangout_skip_votes, [:room_id, :room_content_id])
  end
end
