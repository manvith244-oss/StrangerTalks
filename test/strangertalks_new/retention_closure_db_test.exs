defmodule StrangertalksNew.RetentionClosureDbTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Accounts.{GoogleAccountLink, PrivateAccount}

  alias StrangertalksNew.{
    AnalyticsRecord,
    Relationship,
    RelationshipConsent,
    RelationshipReconnectionIntent,
    SafetyEvent
  }

  alias StrangertalksNew.{
    MatchingRules,
    Repo,
    Relationships,
    RetentionCleanup,
    SafetyEvents
  }

  @now ~U[2026-08-26 12:00:00Z]

  test "terminal reconnect intents older than 24h delete, active unexpired survives, and retry is idempotent" do
    {relationship, _conversation, participant, _peer} = relationship_fixture()

    cancelled =
      reconnect_intent_fixture(relationship, participant, %{
        status: :CANCELLED,
        created_at: hours_ago(30),
        updated_at: hours_ago(25),
        expires_at: hours_ago(24),
        cancelled_at: hours_ago(25)
      })

    expired =
      reconnect_intent_fixture(relationship, participant, %{
        status: :EXPIRED,
        created_at: hours_ago(30),
        updated_at: hours_ago(25),
        expires_at: hours_ago(25)
      })

    active =
      reconnect_intent_fixture(relationship, participant, %{
        status: :ACTIVE,
        created_at: @now,
        updated_at: @now,
        expires_at: DateTime.add(@now, 2, :hour)
      })

    first = RetentionCleanup.run(@now)
    assert {:ok, count} = first.reconnect_intents
    assert count >= 2
    refute Repo.get(RelationshipReconnectionIntent, cancelled.reconnect_intent_id)
    refute Repo.get(RelationshipReconnectionIntent, expired.reconnect_intent_id)
    assert Repo.get(RelationshipReconnectionIntent, active.reconnect_intent_id)

    second = RetentionCleanup.run(@now)
    assert {:ok, _} = second.reconnect_intents
    assert Repo.get(RelationshipReconnectionIntent, active.reconnect_intent_id)
  end

  test "server analytics rolls off after 90 days while current aggregate-only analytics survives" do
    old = analytics_fixture(days_ago(91))
    current = analytics_fixture(days_ago(89))

    fields = AnalyticsRecord.__schema__(:fields)
    refute :participant_id in fields
    refute :message_id in fields
    refute :message_content in fields
    refute :conversation_content in fields
    refute old.contains_personal_data
    refute current.contains_personal_data

    result = RetentionCleanup.run(@now)
    assert {:ok, count} = result.analytics
    assert count >= 1
    refute Repo.get(AnalyticsRecord, old.analytics_record_id)
    assert Repo.get(AnalyticsRecord, current.analytics_record_id)
  end

  test "revoked Google metadata deletes only after 30 days and only after token material is gone" do
    clean_account = private_account_fixture(participant_fixture())
    active_account = private_account_fixture(participant_fixture())
    secret_account = private_account_fixture(participant_fixture())

    clean =
      google_link_fixture(clean_account, %{
        revoked_at: days_ago(31),
        updated_at: days_ago(31)
      })

    active = google_link_fixture(active_account, %{revoked_at: nil})

    secret =
      google_link_fixture(secret_account, %{
        revoked_at: days_ago(31),
        updated_at: days_ago(31),
        encrypted_refresh_token: <<1, 2, 3>>,
        refresh_token_iv: :binary.copy(<<4>>, 12),
        refresh_token_tag: :binary.copy(<<5>>, 16),
        token_key_version: 1
      })

    result = RetentionCleanup.run(@now)
    assert {:ok, count} = result.revoked_google_links
    assert count >= 1
    refute Repo.get(GoogleAccountLink, clean.google_account_link_id)
    assert Repo.get(GoogleAccountLink, active.google_account_link_id)

    retained_secret = Repo.get!(GoogleAccountLink, secret.google_account_link_id)
    assert retained_secret.encrypted_refresh_token == <<1, 2, 3>>
    assert retained_secret.revoked_at
  end

  test "180-day safety cleanup deletes spent narrative but preserves continuing enforcement in minimized form" do
    spent =
      safety_event_fixture(%{
        event_status: :RESOLVED,
        action_type: :NONE,
        action_taken: false,
        report_description: "spent rich report narrative",
        safety_summary: %{"private" => "spent detail"},
        contains_sensitive_data: true
      })

    continuing =
      safety_event_fixture(%{
        event_status: :RESOLVED,
        action_type: :MATCH_RESTRICTION,
        action_taken: true,
        report_description: "rich detail must expire",
        safety_summary: %{"private" => "continuing detail"},
        contains_sensitive_data: true
      })

    result = RetentionCleanup.run(@now)
    assert {:ok, _} = result.safety_events
    refute Repo.get(SafetyEvent, spent.safety_event_id)

    minimized = Repo.get!(SafetyEvent, continuing.safety_event_id)
    assert minimized.event_status == :RESOLVED
    assert minimized.action_type == :MATCH_RESTRICTION
    assert minimized.action_taken
    assert is_nil(minimized.report_description)
    assert minimized.safety_summary == %{}
    refute minimized.contains_sensitive_data
  end

  test "terminal RelationshipConsent older than 30d deletes while active/current consent survives" do
    {terminal_conversation, terminal_a, _terminal_b, _terminal_match} =
      conversation_fixture(:ENDED, days_ago(31))

    terminal_old = relationship_consent_fixture(terminal_conversation, terminal_a, days_ago(31))

    {active_conversation, active_a, _active_b, _active_match} =
      conversation_fixture(:ACTIVE, nil)

    active_old = relationship_consent_fixture(active_conversation, active_a, days_ago(31))

    {recent_terminal_conversation, recent_a, _recent_b, _recent_match} =
      conversation_fixture(:ENDED, days_ago(1))

    recent_terminal =
      relationship_consent_fixture(recent_terminal_conversation, recent_a, days_ago(1))

    result = RetentionCleanup.run(@now)
    assert {:ok, count} = result.relationship_consents
    assert count >= 1
    refute Repo.get(RelationshipConsent, terminal_old.relationship_consent_id)
    assert Repo.get(RelationshipConsent, active_old.relationship_consent_id)
    assert Repo.get(RelationshipConsent, recent_terminal.relationship_consent_id)
  end

  test "closed Relationship rich data minimizes at 30d without removing no-rematch authority" do
    {relationship, _conversation, participant_a, participant_b} =
      relationship_fixture(%{
        relationship_status: :CLOSED,
        closed_at: days_ago(30),
        closure_reason: :PARTICIPANT_CLOSED,
        allow_reconnection: false,
        reconnection_eligible: false,
        relationship_name: "private relationship name",
        participant_custom_name: "private custom name",
        most_common_atmosphere: "private atmosphere",
        learning_version: "rich-learning-v1",
        learning_processed: true,
        reconnection_priority: Decimal.new("0.7500"),
        relationship_strength_score: Decimal.new("0.8500"),
        continuation_probability: Decimal.new("0.9000"),
        relationship_temperature: Decimal.new("0.6500"),
        atmosphere_history: %{"history" => ["private"]},
        relationship_summary: %{"summary" => "private relationship summary"},
        private_note_count: 3
      })

    assert MatchingRules.check_safety_veto?(participant_a.participant_id, participant_b.participant_id)

    result = RetentionCleanup.run(@now)
    assert {:ok, count} = result.closed_relationships
    assert count >= 1

    minimized = Repo.get!(Relationship, relationship.relationship_id)
    assert minimized.relationship_status == :CLOSED
    assert is_nil(minimized.relationship_name)
    assert is_nil(minimized.participant_custom_name)
    assert is_nil(minimized.most_common_atmosphere)
    assert minimized.learning_version == "retention-minimized"
    refute minimized.learning_processed
    assert Decimal.equal?(minimized.reconnection_priority, Decimal.new("0.0000"))
    assert Decimal.equal?(minimized.relationship_strength_score, Decimal.new("0.0000"))
    assert Decimal.equal?(minimized.continuation_probability, Decimal.new("0.0000"))
    assert Decimal.equal?(minimized.relationship_temperature, Decimal.new("0.0000"))
    assert minimized.atmosphere_history == %{}
    assert minimized.relationship_summary == %{}
    assert minimized.private_note_count == 0

    assert MatchingRules.check_safety_veto?(participant_a.participant_id, participant_b.participant_id)

    retry = RetentionCleanup.run(@now)
    assert {:ok, 0} = retry.closed_relationships
    assert Repo.get(Relationship, relationship.relationship_id)
    assert MatchingRules.check_safety_veto?(participant_a.participant_id, participant_b.participant_id)
  end

  test "real category failure is isolated, operational failure is raised, and retry is safe" do
    row_a = analytics_fixture(@now)
    row_b = analytics_fixture(@now)
    row_c = analytics_fixture(@now)

    first =
      RetentionCleanup.run_tasks([
        {:a, fn -> delete_analytics(row_a.analytics_record_id) end},
        {:b, fn -> raise "forced Team 7 partial-category failure" end},
        {:c, fn -> delete_analytics(row_c.analytics_record_id) end}
      ])

    assert first.a == {:ok, 1}
    assert match?({:error, {:exception, %RuntimeError{}}}, first.b)
    assert first.c == {:ok, 1}
    refute Repo.get(AnalyticsRecord, row_a.analytics_record_id)
    assert Repo.get(AnalyticsRecord, row_b.analytics_record_id)
    refute Repo.get(AnalyticsRecord, row_c.analytics_record_id)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Strangertalks.Retention.handle_result!(first)
    end

    retry =
      RetentionCleanup.run_tasks([
        {:a, fn -> delete_analytics(row_a.analytics_record_id) end},
        {:b, fn -> delete_analytics(row_b.analytics_record_id) end},
        {:c, fn -> delete_analytics(row_c.analytics_record_id) end}
      ])

    assert retry.a == {:ok, 0}
    assert retry.b == {:ok, 1}
    assert retry.c == {:ok, 0}
    refute Repo.get(AnalyticsRecord, row_b.analytics_record_id)
    assert :ok = Mix.Tasks.Strangertalks.Retention.handle_result!(retry)
  end

  defp reconnect_intent_fixture(relationship, participant, attrs) do
    base = %{
      relationship_id: relationship.relationship_id,
      participant_id: participant.participant_id,
      door_type: :JUST_TALK,
      status: :ACTIVE,
      created_at: @now,
      updated_at: @now,
      expires_at: DateTime.add(@now, 2, :hour)
    }

    %RelationshipReconnectionIntent{}
    |> RelationshipReconnectionIntent.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp analytics_fixture(created_at) do
    id = Ecto.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO analytics_records (
        analytics_record_id,
        created_at,
        analytics_period,
        analytics_date,
        source_type
      ) VALUES ($1, $2, 'DAILY', $3, 'SYSTEM')
      """,
      [id, created_at, DateTime.to_date(created_at)]
    )

    Repo.get!(AnalyticsRecord, id)
  end

  defp delete_analytics(id) do
    {count, _} = Repo.delete_all(from(record in AnalyticsRecord, where: record.analytics_record_id == ^id))
    {:ok, count}
  end

  defp google_link_fixture(account, attrs) do
    base = %{
      account_id: account.account_id,
      provider_subject_hash: :crypto.hash(:sha256, Ecto.UUID.generate()),
      encrypted_refresh_token: nil,
      refresh_token_iv: nil,
      refresh_token_tag: nil,
      token_key_version: nil,
      granted_scopes: ["openid"],
      connected_at: @now,
      refreshed_at: nil,
      revoked_at: nil,
      created_at: @now,
      updated_at: @now
    }

    %GoogleAccountLink{}
    |> Ecto.Changeset.change(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp private_account_fixture(participant) do
    %PrivateAccount{}
    |> Ecto.Changeset.change(%{
      participant_id: participant.participant_id,
      created_at: @now,
      updated_at: @now,
      last_signed_in_at: @now
    })
    |> Repo.insert!()
  end

  defp safety_event_fixture(attrs) do
    base = %{
      event_status: :RESOLVED,
      event_type: :REPORT,
      severity_level: :LOW,
      action_type: :NONE,
      related_event_count: 0,
      participant_report_count: 0,
      participant_block_count: 0,
      report_description: "rich narrative",
      safety_summary: %{"private" => "detail"},
      contains_sensitive_data: true,
      created_at: days_ago(181),
      updated_at: days_ago(181),
      review_completed_at: days_ago(181)
    }

    {:ok, event} = SafetyEvents.create_safety_event(Map.merge(base, attrs))
    event
  end

  defp relationship_consent_fixture(conversation, participant, created_at) do
    %RelationshipConsent{}
    |> RelationshipConsent.changeset(%{
      conversation_id: conversation.conversation_id,
      participant_id: participant.participant_id,
      created_at: created_at
    })
    |> Repo.insert!()
  end

  defp relationship_fixture(overrides \\ %{}) do
    {conversation, participant_a, participant_b, matching} = conversation_fixture(:ACTIVE, nil)

    base = %{
      created_at: @now,
      updated_at: @now,
      first_conversation_at: @now,
      relationship_status: :ACTIVE,
      origin_door_type: :JUST_TALK,
      participant_a_id: participant_a.participant_id,
      participant_b_id: participant_b.participant_id,
      origin_conversation_id: conversation.conversation_id,
      origin_match_id: matching.match_id,
      participant_a_accepted: true,
      participant_b_accepted: true,
      allow_reconnection: true,
      reconnection_eligible: true,
      participant_a_closed: false,
      participant_b_closed: false,
      participant_a_blocked: false,
      participant_b_blocked: false,
      learning_processed: false,
      learning_version: "v1",
      conversation_count: 1,
      memory_count: 0,
      reconnection_count: 0,
      shared_memory_count: 0,
      private_note_count: 0,
      reconnection_priority: Decimal.new("0.7500"),
      relationship_strength_score: Decimal.new("0.8500"),
      continuation_probability: Decimal.new("0.9000"),
      relationship_temperature: Decimal.new("0.6500"),
      atmosphere_history: %{"history" => []},
      relationship_summary: %{"summary" => "initial"}
    }

    {:ok, relationship} = Relationships.create_relationship(Map.merge(base, overrides))
    {relationship, conversation, participant_a, participant_b}
  end

  defp conversation_fixture(status, ended_at) do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: @now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: @now,
        match_found_time: @now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: @now,
        ended_at: ended_at,
        match_id: matching.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: status,
        ending_type: if(ended_at, do: :NORMAL, else: nil),
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    {conversation, participant_a, participant_b, matching}
  end

  defp participant_fixture do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: @now,
        last_active_at: @now
      })

    participant
  end

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400, :second)
  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3_600, :second)
end