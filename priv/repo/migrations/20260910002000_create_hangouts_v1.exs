defmodule StrangertalksNew.Repo.Migrations.CreateHangoutsV1 do
  use Ecto.Migration

  def change do
    create table(:hangout_rooms, primary_key: false) do
      add :room_id, :binary_id, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
      add :activated_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :status, :string, null: false, default: "FORMING"
      add :language_tag, :string, null: false
      add :experiment_arm, :string, null: false, default: "GROUP_WITH_CONTENT"
      add :minimum_size, :integer, null: false, default: 3
      add :target_size, :integer, null: false, default: 4
      add :max_size, :integer, null: false, default: 6
      add :message_sequence, :bigint, null: false, default: 0
      add :content_sequence, :bigint, null: false, default: 0
      add :current_content_started_at, :utc_datetime_usec
    end

    create constraint(:hangout_rooms, :hangout_rooms_capacity_order_check,
             check:
               "minimum_size >= 2 AND minimum_size <= target_size AND target_size <= max_size AND max_size <= 12"
           )

    create constraint(:hangout_rooms, :hangout_rooms_sequence_nonnegative_check,
             check: "message_sequence >= 0 AND content_sequence >= 0"
           )

    create table(:hangout_memberships, primary_key: false) do
      add :membership_id, :binary_id, primary_key: true

      add :room_id,
          references(:hangout_rooms, column: :room_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :status, :string, null: false, default: "ACTIVE"
      add :temporary_identity_slot, :integer, null: false
      add :temporary_identity_label, :string, null: false
      add :temporary_identity_emoji, :string, null: false
      add :joined_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec, null: false
      add :disconnect_count, :integer, null: false, default: 0
    end

    create unique_index(:hangout_memberships, [:room_id, :participant_id],
             name: :hangout_memberships_room_participant_index
           )

    create unique_index(:hangout_memberships, [:room_id, :temporary_identity_slot],
             name: :hangout_memberships_room_identity_slot_index
           )

    create unique_index(:hangout_memberships, [:participant_id],
             where: "status IN ('ACTIVE', 'DISCONNECTED')",
             name: :hangout_memberships_one_active_room_per_participant_index
           )

    create constraint(:hangout_memberships, :hangout_memberships_identity_slot_nonnegative_check,
             check: "temporary_identity_slot >= 0 AND disconnect_count >= 0"
           )

    create table(:hangout_messages, primary_key: false) do
      add :message_id, :binary_id, primary_key: true

      add :room_id,
          references(:hangout_rooms, column: :room_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :membership_id,
          references(:hangout_memberships,
            column: :membership_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :sequence, :bigint, null: false
      add :client_message_id, :string, null: false
      add :body, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:hangout_messages, [:room_id, :sequence],
             name: :hangout_messages_room_sequence_index
           )

    create unique_index(:hangout_messages, [:membership_id, :client_message_id],
             name: :hangout_messages_membership_client_message_index
           )

    create constraint(:hangout_messages, :hangout_messages_sequence_positive_check,
             check: "sequence > 0"
           )

    create constraint(:hangout_messages, :hangout_messages_body_size_check,
             check: "octet_length(body) > 0 AND octet_length(body) <= 16384"
           )

    create table(:hangout_reports, primary_key: false) do
      add :report_id, :binary_id, primary_key: true

      add :room_id,
          references(:hangout_rooms, column: :room_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :reporting_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :reported_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nilify_all
          )

      add :category, :string, null: false
      add :status, :string, null: false, default: "SUBMITTED"
      add :evidence, :text
      add :deduplication_key, :string
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
    end

    create unique_index(:hangout_reports, [:deduplication_key],
             where: "deduplication_key IS NOT NULL"
           )

    create constraint(:hangout_reports, :hangout_reports_no_self_report_check,
             check:
               "reported_participant_id IS NULL OR reporting_participant_id <> reported_participant_id"
           )

    create constraint(:hangout_reports, :hangout_reports_evidence_size_check,
             check: "evidence IS NULL OR octet_length(evidence) <= 4096"
           )
  end
end
