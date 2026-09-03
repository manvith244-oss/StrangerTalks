defmodule StrangertalksNew.Repo.Migrations.SecureSupabasePublicSchema do
  use Ecto.Migration

  @protected_tables ~w(
    account_sessions
    account_sync_states
    analytics_records
    boundary_blocks
    composer_grants
    conversations
    google_account_links
    google_oauth_attempts
    learning_records
    matches
    memories
    message_reactions
    messages
    participants
    private_accounts
    queue_states
    reflections
    relationship_consents
    relationship_reconnection_intents
    relationships
    report_safety_media
    reports
    safety_events
    safety_reviews
    schema_migrations
  )

  @api_roles ~w(anon authenticated service_role)

  def up do
    Enum.each(@protected_tables, fn table ->
      execute("ALTER TABLE IF EXISTS public.#{table} ENABLE ROW LEVEL SECURITY")
      revoke_table_api_access(table)
    end)

    revoke_future_api_defaults()
  end

  def down do
    raise "T04 Supabase public-schema security closure is intentionally irreversible; restore a captured pre-change database state instead of reopening Data API access"
  end

  defp revoke_table_api_access(table) do
    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF to_regclass('public.#{table}') IS NOT NULL
           AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.#{table} FROM #{role}';
        END IF;
      END
      $$;
      """)
    end)
  end

  defp revoke_future_api_defaults do
    Enum.each(@api_roles, fn role ->
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
          EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES FROM #{role}',
            current_user
          );

          EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM #{role}',
            current_user
          );
        END IF;
      END
      $$;
      """)
    end)
  end
end
