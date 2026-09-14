defmodule StrangertalksNew.Repo.Migrations.AddReportSourceKind do
  use Ecto.Migration

  @api_roles ~w(anon authenticated service_role)

  def up do
    # Step A & D: Add source_kind column with default 'CONVERSATION'
    alter table(:reports) do
      add :source_kind, :string, default: "CONVERSATION"
    end

    # Step B: Finite source domain constraint
    create constraint(:reports, :reports_source_kind_check,
             check: "source_kind IN ('CONVERSATION', 'HANGOUT')"
           )

    # Step C: Historical backfill: classify all preexisting shared reports as CONVERSATION
    execute("""
    UPDATE public.reports
    SET source_kind = 'CONVERSATION'
    WHERE source_kind IS NULL OR source_kind != 'CONVERSATION'
    """)

    # Step E: Named H-01A authority hard gate: reject any shared HANGOUT write
    create constraint(:reports, :reports_source_authority_check,
             check: "source_kind = 'CONVERSATION'"
           )

    # Step F: Enforce non-null on source_kind after backfill
    alter table(:reports) do
      modify :source_kind, :string, null: false, default: "CONVERSATION"
    end

    # Step H: Self-secure reports: reassert RLS and revoke unintended API privileges
    execute("ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY")

    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.reports FROM #{role}';
        END IF;
      END
      $$;
      """)
    end)
  end

  def down do
    # Step I: Irreversible down to prevent destruction of source truth
    raise "Reversing report source classification is intentionally irreversible; restore a captured pre-change database state instead of destroying source identity truth"
  end
end
