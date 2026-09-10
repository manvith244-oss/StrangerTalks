defmodule StrangertalksNew.Repo.Migrations.ClosePublicSchemaDataApiBoundaryRpr do
  use Ecto.Migration

  @api_roles ~w(anon authenticated service_role)

  # Phoenix connects directly as the database owner; Supabase Data API roles must not traverse public.
  def up do
    execute("REVOKE ALL PRIVILEGES ON SCHEMA public FROM PUBLIC")

    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE ALL PRIVILEGES ON SCHEMA public FROM #{role}';
        END IF;
      END
      $$;
      """)
    end)
  end

  def down do
    raise "RPR public-schema Data API boundary is intentionally irreversible; restore a captured pre-change database state instead of reopening schema access"
  end
end
