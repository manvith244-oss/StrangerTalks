defmodule StrangertalksNew.Repo.Migrations.AllowPendingMatchmakingPersistence do
  use Ecto.Migration

  def up do
    alter table(:matches) do
      modify :opportunity_score, :decimal, precision: 5, scale: 4, null: true
      modify :scarcity_adjustment, :decimal, precision: 5, scale: 4, null: true
      modify :conversation_temperature, :decimal, precision: 5, scale: 4, null: true
      modify :mutual_participation_score, :decimal, precision: 5, scale: 4, null: true
      modify :conversation_health_score, :decimal, precision: 5, scale: 4, null: true
      modify :match_quality_score, :decimal, precision: 5, scale: 4, null: true
      modify :learning_version, :string, null: true
      add :compatibility_version, :string, null: true
    end

    drop constraint(:conversations, :conversation_status_check)

    create constraint(:conversations, :conversation_status_check,
             check:
               "conversation_status IN ('PENDING', 'ACTIVE', 'PAUSED', 'ENDED', 'ABANDONED', 'FAILED')"
           )

    alter table(:conversations) do
      modify :average_response_time, :float, null: true
      modify :participation_balance_score, :decimal, precision: 5, scale: 4, null: true
      modify :message_exchange_rate, :float, null: true
      modify :conversation_depth_score, :decimal, precision: 5, scale: 4, null: true
      modify :conversation_temperature, :decimal, precision: 5, scale: 4, null: true
      modify :bridge_effectiveness_score, :decimal, precision: 5, scale: 4, null: true
      modify :conversation_success_score, :decimal, precision: 5, scale: 4, null: true
      modify :safety_score, :decimal, precision: 5, scale: 4, null: true
      modify :time_to_first_message_seconds, :integer, null: true
      modify :time_to_first_reply_seconds, :integer, null: true
      modify :longest_silence_seconds, :integer, null: true
      modify :learning_version, :string, null: true
    end

    alter table(:relationships) do
      modify :learning_version, :string, null: true
    end
  end

  def down do
    alter table(:relationships) do
      modify :learning_version, :string, null: false
    end

    alter table(:conversations) do
      modify :average_response_time, :float, null: false
      modify :participation_balance_score, :decimal, precision: 5, scale: 4, null: false
      modify :message_exchange_rate, :float, null: false
      modify :conversation_depth_score, :decimal, precision: 5, scale: 4, null: false
      modify :conversation_temperature, :decimal, precision: 5, scale: 4, null: false
      modify :bridge_effectiveness_score, :decimal, precision: 5, scale: 4, null: false
      modify :conversation_success_score, :decimal, precision: 5, scale: 4, null: false
      modify :safety_score, :decimal, precision: 5, scale: 4, null: false
      modify :time_to_first_message_seconds, :integer, null: false
      modify :time_to_first_reply_seconds, :integer, null: false
      modify :longest_silence_seconds, :integer, null: false
      modify :learning_version, :string, null: false
    end

    drop constraint(:conversations, :conversation_status_check)

    create constraint(:conversations, :conversation_status_check,
             check: "conversation_status IN ('ACTIVE', 'PAUSED', 'ENDED', 'ABANDONED', 'FAILED')"
           )

    alter table(:matches) do
      remove :compatibility_version
      modify :opportunity_score, :decimal, precision: 5, scale: 4, null: false
      modify :scarcity_adjustment, :decimal, precision: 5, scale: 4, null: false
      modify :conversation_temperature, :decimal, precision: 5, scale: 4, null: false
      modify :mutual_participation_score, :decimal, precision: 5, scale: 4, null: false
      modify :conversation_health_score, :decimal, precision: 5, scale: 4, null: false
      modify :match_quality_score, :decimal, precision: 5, scale: 4, null: false
      modify :learning_version, :string, null: false
    end
  end
end
