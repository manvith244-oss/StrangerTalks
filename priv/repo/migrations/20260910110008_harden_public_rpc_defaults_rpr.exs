defmodule StrangertalksNew.Repo.Migrations.HardenPublicRpcDefaultsRpr do
  use Ecto.Migration

  @api_roles ~w(anon authenticated service_role)

  def up do
    execute("REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC")
    execute("ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC")

    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM #{role}';
          EXECUTE 'ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM #{role}';
          EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM #{role}';
        END IF;
      END
      $$;
      """)
    end)
  end

  def down do
    raise "RPR public RPC authority closure is intentionally irreversible; restore a captured pre-change database state instead of reopening Data API function execution"
  end
end
