defmodule StrangertalksNew.Repo.Migrations.CreateLivingThreadPilot do
  use Ecto.Migration

  def change do
    create table(:living_threads, primary_key: false) do
      add :thread_id, :binary_id, primary_key: true

      add :starter_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :carrier_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nilify_all
          )

      add :status, :string, null: false, default: "WAITING_FOR_B"
      add :starter_body, :text, null: false
      add :continuation_body, :text
      add :opened_at, :utc_datetime_usec, null: false
      add :continuation_deadline_at, :utc_datetime_usec, null: false
      add :continued_at, :utc_datetime_usec
      add :resolves_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :time_remaining_at_continuation_seconds, :integer
    end

    create unique_index(:living_threads, [:starter_participant_id],
             name: :living_threads_one_per_starter_index
           )

    create unique_index(:living_threads, [:carrier_participant_id],
             where: "carrier_participant_id IS NOT NULL",
             name: :living_threads_one_per_carrier_index
           )

    create index(:living_threads, [:status, :continuation_deadline_at],
             name: :living_threads_waiting_deadline_index
           )

    create constraint(:living_threads, :living_threads_status_check,
             check:
               "status IN ('WAITING_FOR_B','CONTINUED','LIQUIDITY_FAILURE','RESOLVED')"
           )

    create constraint(:living_threads, :living_threads_no_self_carry_check,
             check:
               "carrier_participant_id IS NULL OR starter_participant_id <> carrier_participant_id"
           )

    create constraint(:living_threads, :living_threads_deadline_order_check,
             check:
               "continuation_deadline_at > opened_at AND resolves_at > continuation_deadline_at"
           )

    create constraint(:living_threads, :living_threads_body_size_check,
             check:
               "octet_length(starter_body) > 0 AND octet_length(starter_body) <= 1000 AND (continuation_body IS NULL OR (octet_length(continuation_body) > 0 AND octet_length(continuation_body) <= 1000))"
           )

    create constraint(:living_threads, :living_threads_continuation_integrity_check,
             check:
               "((carrier_participant_id IS NULL AND continuation_body IS NULL AND continued_at IS NULL AND time_remaining_at_continuation_seconds IS NULL) OR (carrier_participant_id IS NOT NULL AND continuation_body IS NOT NULL AND continued_at IS NOT NULL AND time_remaining_at_continuation_seconds IS NOT NULL AND time_remaining_at_continuation_seconds >= 0))"
           )

    create table(:living_thread_experiment_assignments, primary_key: false) do
      add :assignment_id, :binary_id, primary_key: true

      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :role, :string, null: false
      add :assigned_at, :utc_datetime_usec, null: false

      add :observed_thread_id,
          references(:living_threads,
            column: :thread_id,
            type: :binary_id,
            on_delete: :nilify_all
          )
    end

    create unique_index(:living_thread_experiment_assignments, [:participant_id],
             name: :living_thread_assignments_participant_index
           )

    create unique_index(:living_thread_experiment_assignments, [:observed_thread_id],
             where: "observed_thread_id IS NOT NULL",
             name: :living_thread_assignments_observed_thread_index
           )

    create constraint(
             :living_thread_experiment_assignments,
             :living_thread_assignments_role_check,
             check: "role IN ('CONSEQUENCE_A','SPECTATOR_A','CARRIER_B')"
           )

    create table(:living_thread_pilot_events, primary_key: false) do
      add :event_id, :binary_id, primary_key: true

      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :thread_id,
          references(:living_threads,
            column: :thread_id,
            type: :binary_id,
            on_delete: :delete_all
          )

      add :event_type, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :deduplication_key, :string
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create unique_index(:living_thread_pilot_events, [:deduplication_key],
             where: "deduplication_key IS NOT NULL",
             name: :living_thread_pilot_events_deduplication_index
           )

    create index(:living_thread_pilot_events, [:participant_id, :occurred_at],
             name: :living_thread_pilot_events_participant_time_index
           )

    create constraint(:living_thread_pilot_events, :living_thread_pilot_event_type_check,
             check:
               "event_type IN ('THREAD_SEEN','THREAD_CONTRIBUTED','THREAD_REOPENED','THREAD_RESOLVED','NEW_THREAD_JOINED','KNOWN_PERSON_DEBRIEF')"
           )
  end
end
