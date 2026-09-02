defmodule StrangertalksNew.Repo.Migrations.CreateParticipantPairingReservations do
  use Ecto.Migration

  def change do
    create table(:participant_pairing_reservations, primary_key: false) do
      add :match_id,
          references(:matches,
            column: :match_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          primary_key: true,
          null: false

      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          primary_key: true,
          null: false

      add :acquired_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
    end

    create constraint(
             :participant_pairing_reservations,
             :participant_pairing_reservations_released_after_acquired_check,
             check: "released_at IS NULL OR released_at >= acquired_at"
           )

    create unique_index(
             :participant_pairing_reservations,
             [:participant_id],
             where: "released_at IS NULL",
             name: :participant_pairing_reservations_active_participant_index
           )
  end
end
