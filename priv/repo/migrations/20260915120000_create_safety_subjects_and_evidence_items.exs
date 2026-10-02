defmodule StrangertalksNew.Repo.Migrations.CreateSafetySubjectsAndEvidenceItems do
  use Ecto.Migration

  @api_roles ~w(anon authenticated service_role)

  def up do
    # 1. Create safety_subjects table
    create table(:safety_subjects, primary_key: false) do
      add :subject_id, :binary_id, primary_key: true

      add :report_id,
          references(:reports,
            column: :report_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :subject_role, :string, null: false

      add :source_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nilify_all
          ),
          null: true

      add :source_temporary_identity_slot, :integer, null: true
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:safety_subjects, [:report_id])
    create index(:safety_subjects, [:source_participant_id])

    create constraint(:safety_subjects, :safety_subjects_role_check,
             check: "subject_role IN ('REPORTER', 'REPORTED', 'EVIDENCE_AUTHOR')"
           )

    # 2. Create report_evidence_items table
    create table(:report_evidence_items, primary_key: false) do
      add :evidence_item_id, :binary_id, primary_key: true

      add :report_id,
          references(:reports,
            column: :report_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :subject_id,
          references(:safety_subjects,
            column: :subject_id,
            type: :binary_id,
            on_delete: :nilify_all
          ),
          null: true

      add :source_kind, :string, null: false
      add :evidence_role, :string, null: false
      add :source_item_id, :string, null: true
      add :source_sequence, :integer, null: true
      add :source_timestamp, :utc_datetime_usec, null: true
      add :content_snapshot, :text, null: true
      add :media_type, :string, null: true
      add :media_bytes, :binary, null: true
      add :byte_size, :integer, null: true
      add :captured_at, :utc_datetime_usec, null: false
    end

    create index(:report_evidence_items, [:report_id])
    create index(:report_evidence_items, [:subject_id])

    create constraint(:report_evidence_items, :report_evidence_items_source_kind_check,
             check: "source_kind IN ('CONVERSATION', 'HANGOUT')"
           )

    create constraint(:report_evidence_items, :report_evidence_items_evidence_role_check,
             check: "evidence_role IN ('SELECTED', 'CONTEXT_EXPANSION')"
           )

    create constraint(:report_evidence_items, :report_evidence_items_byte_size_check,
             check: "byte_size IS NULL OR byte_size >= 0"
           )

    # 3. Add retention metadata columns to reports table
    alter table(:reports) do
      add :retention_policy_version, :string, default: "v1"
      add :rich_evidence_expires_at, :utc_datetime_usec, null: true
      add :reporter_unlink_at, :utc_datetime_usec, null: true
      add :minimal_record_expires_at, :utc_datetime_usec, null: true
    end

    # 4. Historical backfill for pre-existing reports
    execute("""
    UPDATE public.reports
    SET retention_policy_version = 'v1',
        rich_evidence_expires_at = created_at + interval '90 days',
        reporter_unlink_at = created_at + interval '180 days',
        minimal_record_expires_at = created_at + interval '365 days'
    WHERE rich_evidence_expires_at IS NULL OR retention_policy_version IS NULL;
    """)

    # 5. Enforce non-null on retention_policy_version after backfill
    alter table(:reports) do
      modify :retention_policy_version, :string, null: false, default: "v1"
    end

    # 6. Retention chronology constraint
    create constraint(:reports, :reports_retention_chronology_check,
             check:
               "rich_evidence_expires_at IS NULL OR minimal_record_expires_at IS NULL OR rich_evidence_expires_at <= minimal_record_expires_at"
           )

    # 7. Self-securing RLS on new public tables
    execute("ALTER TABLE public.safety_subjects ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE public.report_evidence_items ENABLE ROW LEVEL SECURITY")

    # 8. Revoke all privileges from untrusted Data API roles
    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.safety_subjects FROM #{role}';
          EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.report_evidence_items FROM #{role}';
        END IF;
      END
      $$;
      """)
    end)
  end

  def down do
    raise "Reversing H-01B Safety foundation migration is intentionally irreversible to prevent destruction of Safety evidence; restore a captured pre-change database state instead"
  end
end
