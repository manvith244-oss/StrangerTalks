defmodule StrangertalksNew.Repo.Migrations.HardenPublicRpcDefaultsRpr do
  use Ecto.Migration

  @api_roles ~w(anon authenticated service_role)

  def up do
    execute("REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC")

    execute("""
    DO $$
    BEGIN
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC',
        current_user
      );
    END
    $$;
    """)

    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM #{role}';

          EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE EXECUTE ON FUNCTIONS FROM #{role}',
            current_user
          );
        END IF;
      END
      $$;
      """)
    end)
  end

  def down do
    raise "RPR public RPC default closure is intentionally irreversible; restore a captured pre-change database state instead of reopening Data API function execution"
  end
end
