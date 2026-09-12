defmodule StrangertalksNew.Repo.Migrations.ReassertPublicSchemaRlsInvariant do
  use Ecto.Migration

  @application_tables ~w(
    account_sessions
    account_sync_states
    analytics_records
    boundary_blocks
    composer_grants
    conversations
    google_account_links
    google_oauth_attempts
    hangout_memberships
    hangout_messages
    hangout_reports
    hangout_rooms
    learning_records
    matches
    memories
    message_reactions
    messages
    participant_pairing_reservations
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
    source_rate_limits
  )

  @api_roles ~w(anon authenticated service_role)

  def up do
    Enum.each(@application_tables, fn table ->
      # These are the complete current StrangerTalks application tables. Do not
      # silently skip a missing expected table: migration ordering/schema drift
      # must fail loudly rather than leave an unproven RLS posture.
      execute("ALTER TABLE public.#{table} ENABLE ROW LEVEL SECURITY")
      revoke_table_api_access(table)
    end)
  end

  def down do
    raise "RLS convergence is intentionally irreversible; restore a captured pre-change database state instead of weakening the public-schema security boundary"
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
