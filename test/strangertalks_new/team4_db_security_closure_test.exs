defmodule StrangertalksNew.Team4DbSecurityClosureTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{Participants, Repo}

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
  @table_privileges ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER)

  test "every affected public table present in this composition has RLS enabled" do
    rows = existing_protected_tables()

    assert rows != []

    for [table_name, rls_enabled, rls_forced] <- rows do
      assert rls_enabled, "expected public.#{table_name} to have RLS enabled"
      refute rls_forced, "public.#{table_name} must not FORCE RLS over the direct Phoenix owner path"
    end
  end

  test "Supabase API roles have no table privileges on present product tables" do
    existing_roles =
      Repo.query!("SELECT rolname FROM pg_roles WHERE rolname = ANY($1::text[])", [@api_roles]).rows
      |> List.flatten()

    existing_tables = Enum.map(existing_protected_tables(), &hd/1)

    for role <- existing_roles,
        table <- existing_tables,
        privilege <- @table_privileges do
      [[allowed]] =
        Repo.query!(
          "SELECT has_table_privilege($1, $2, $3)",
          [role, "public.#{table}", privilege]
        ).rows

      refute allowed,
             "expected #{role} to lack #{privilege} on public.#{table}; the product uses direct Postgres, not the Data API"
    end
  end

  test "future public tables created by the migration role do not inherit Data API table grants" do
    current_role = Repo.query!("SELECT current_user").rows |> hd() |> hd()

    acl =
      Repo.query!("""
      SELECT COALESCE(array_to_string(d.defaclacl, ','), '')
      FROM pg_default_acl d
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      WHERE n.nspname = 'public'
        AND d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = $1)
        AND d.defaclobjtype = 'r'
      """, [current_role]).rows
      |> case do
        [[value]] -> value
        [] -> ""
      end

    for role <- @api_roles do
      refute String.contains?(acl, "#{role}=a")
      refute String.contains?(acl, "#{role}=r")
      refute String.contains?(acl, "#{role}=w")
      refute String.contains?(acl, "#{role}=d")
      refute String.contains?(acl, "#{role}=D")
      refute String.contains?(acl, "#{role}=x")
      refute String.contains?(acl, "#{role}=t")
    end
  end

  test "direct Phoenix database authority still performs legitimate participant persistence" do
    now = DateTime.utc_now()

    assert {:ok, participant} =
             Participants.create_participant(%{
               presence_state: :ONLINE,
               created_at: now,
               last_active_at: now
             })

    assert Repo.get!(StrangertalksNew.Participant, participant.participant_id)
  end

  defp existing_protected_tables do
    Repo.query!("""
    SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = ANY($1::text[])
      AND c.relkind IN ('r', 'p')
    ORDER BY c.relname
    """, [@protected_tables]).rows
  end
end
