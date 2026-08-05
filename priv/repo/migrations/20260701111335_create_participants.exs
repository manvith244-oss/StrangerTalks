defmodule StrangertalksNew.Repo.Migrations.CreateParticipants do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE presence_state AS ENUM ('OFFLINE', 'ONLINE', 'MATCHING', 'IN_CONVERSATION', 'VIEWING_MEMORIES', 'VIEWING_RELATIONSHIPS')",
      "DROP TYPE presence_state"
    )

    create table(:participants, primary_key: false) do
      add :participant_id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("gen_random_uuid()")

      add :presence_state, :presence_state, null: false, default: "OFFLINE"
      add :last_active_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :created_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end
  end
end
