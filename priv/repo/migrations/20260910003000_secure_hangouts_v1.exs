defmodule StrangertalksNew.Repo.Migrations.SecureHangoutsV1 do
  use Ecto.Migration

  @hangout_tables ~w(
    hangout_memberships
    hangout_messages
    hangout_reports
    hangout_rooms
  )

  @api_roles ~w(anon authenticated service_role)

  def up do
    Enum.each(@hangout_tables, fn table ->
      execute("ALTER TABLE public.#{table} ENABLE ROW LEVEL SECURITY")
      revoke_table_api_access(table)
    end)
  end

  def down do
    raise "Hangouts V1 security closure is intentionally irreversible; restore a captured pre-change database state instead of reopening Data API access"
  end

  defp revoke_table_api_access(table) do
    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.#{table} FROM #{role}';
        END IF;
      END
      $$;
      """)
    end)
  end
end
