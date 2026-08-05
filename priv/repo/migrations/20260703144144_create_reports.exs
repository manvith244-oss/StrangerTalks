defmodule StrangertalksNew.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :report_id, :binary_id, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec, null: true

      add :reporting_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :reported_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :reported_message_id,
          references(:messages, column: :message_id, type: :binary_id, on_delete: :nothing),
          null: true

      add :report_category, :string, null: false
      add :report_status, :string, null: false
      add :resolution_outcome, :string, null: true
      add :reporter_context, :string, null: true
    end

    create constraint(:reports, :self_reporting_prohibited,
             check: "reporting_participant_id != reported_participant_id"
           )

    create constraint(:reports, :report_category_check,
             check:
               "report_category IN ('SPAM', 'HARASSMENT', 'SEXUAL_MISCONDUCT', 'MALICIOUS_LINKS', 'THREATS')"
           )

    create constraint(:reports, :report_status_check,
             check: "report_status IN ('SUBMITTED', 'UNDER_REVIEW', 'RESOLVED', 'DISMISSED')"
           )

    create constraint(:reports, :resolution_outcome_check,
             check:
               "resolution_outcome IS NULL OR resolution_outcome IN ('NO_ACTION', 'WARNING', 'COOLDOWN', 'PERMANENT_BAN')"
           )

    create index(:reports, [:reporting_participant_id])
    create index(:reports, [:reported_participant_id])
    create index(:reports, [:conversation_id])
    create index(:reports, [:report_status, :created_at])
  end
end
