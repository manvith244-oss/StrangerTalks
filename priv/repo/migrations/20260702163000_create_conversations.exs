defmodule StrangertalksNew.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :conversation_id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("gen_random_uuid()")

      add :match_id, references(:matches, column: :match_id, type: :uuid, on_delete: :delete_all),
        null: false

      add :participant_a_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :nilify_all),
          null: false

      add :participant_b_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :nilify_all),
          null: false

      add :conversation_status, :string, null: false
      add :door_type, :string, null: false
      add :ending_type, :string, null: true
      add :ending_initiator, :uuid, null: true

      add :participation_balance_score, :decimal, precision: 5, scale: 4, null: false
      add :conversation_depth_score, :decimal, precision: 5, scale: 4, null: false
      add :conversation_temperature, :decimal, precision: 5, scale: 4, null: false
      add :bridge_effectiveness_score, :decimal, precision: 5, scale: 4, null: false
      add :conversation_success_score, :decimal, precision: 5, scale: 4, null: false
      add :safety_score, :decimal, precision: 5, scale: 4, null: false

      add :atmosphere_id, :uuid, null: true
      add :icebreaker_id, :uuid, null: true
      add :transition_id, :uuid, null: true
      add :primary_memory_id, :uuid, null: true
      add :relationship_id, :uuid, null: true

      add :message_count, :integer, null: false
      add :voice_note_count, :integer, null: false
      add :average_response_time, :float, null: false
      add :message_exchange_rate, :float, null: false

      add :conversation_completed, :boolean, null: false, default: false
      add :memory_created, :boolean, null: false, default: false
      add :relationship_created, :boolean, null: false, default: false
      add :reconnected_later, :boolean, null: false, default: false
      add :bridge_shown, :boolean, null: false, default: false
      add :bridge_used, :boolean, null: false, default: false
      add :bridge_ignored, :boolean, null: false, default: false
      add :relationship_created_at_end, :boolean, null: false, default: false
      add :safety_flagged, :boolean, null: false, default: false

      add :memory_count, :integer, null: false
      add :report_count, :integer, null: false
      add :block_count, :integer, null: false
      add :learning_processed, :boolean, null: false, default: false
      add :learning_version, :string, null: false
      add :learning_summary, :map, null: true

      add :duration_seconds, :integer, null: false
      add :time_to_first_message_seconds, :integer, null: false
      add :time_to_first_reply_seconds, :integer, null: false
      add :longest_silence_seconds, :integer, null: false

      add :created_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :ended_at, :utc_datetime_usec, null: true
      add :first_message_timestamp, :utc_datetime_usec, null: true
      add :last_message_timestamp, :utc_datetime_usec, null: true
    end

    create constraint(:conversations, :conversation_status_check,
             check: "conversation_status IN ('ACTIVE', 'PAUSED', 'ENDED', 'ABANDONED', 'FAILED')"
           )

    create constraint(:conversations, :door_type_check,
             check: "door_type IN ('JUST_TALK', 'KEEP_IT_LIGHT', 'EXPLORE', 'SOMETHING_REAL')"
           )

    create constraint(:conversations, :ending_type_check,
             check:
               "ending_type IS NULL OR ending_type IN ('NATURAL_END', 'PARTICIPANT_LEFT', 'TIMEOUT', 'DISCONNECT', 'BLOCK', 'SAFETY_ACTION')"
           )

    create unique_index(:conversations, [:match_id])
    create index(:conversations, [:participant_a_id])
    create index(:conversations, [:participant_b_id])
    create index(:conversations, [:conversation_status])
    create index(:conversations, [:created_at])
    create index(:conversations, [:conversation_temperature])
  end
end
