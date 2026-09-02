defmodule StrangertalksNew.RetentionPolicyTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.RetentionPolicy

  test "Command-approved V1 durations are centralized and exact" do
    assert RetentionPolicy.ordinary_live_conversation_seconds() == 0
    assert RetentionPolicy.safety_media_default_days() == 30
    assert RetentionPolicy.safety_media_hard_max_days() == 60
    assert RetentionPolicy.open_report_days() == 180
    assert RetentionPolicy.final_report_rich_evidence_days() == 90
    assert RetentionPolicy.safety_review_rich_notes_days() == 90
    assert RetentionPolicy.safety_event_rich_days() == 180
    assert RetentionPolicy.inactive_boundary_block_days() == 30
    assert RetentionPolicy.guest_inactivity_days() == 30
    assert RetentionPolicy.terminal_match_days() == 30
    assert RetentionPolicy.terminal_conversation_days() == 30
    assert RetentionPolicy.closed_relationship_rich_days() == 30
    assert RetentionPolicy.terminal_relationship_consent_days() == 30
    assert RetentionPolicy.operational_cleanup_hours() == 24
    assert RetentionPolicy.deleted_memory_days() == 7
    assert RetentionPolicy.reflection_backup_days() == 14
    assert RetentionPolicy.deleted_account_backup_days() == 14
    assert RetentionPolicy.expired_session_cleanup_days() == 30
    assert RetentionPolicy.revoked_session_cleanup_days() == 30
    assert RetentionPolicy.oauth_logical_minutes() == 10
    assert RetentionPolicy.revoked_google_link_days() == 30
    assert RetentionPolicy.analytics_days() == 90
    assert RetentionPolicy.posthog_days() == 90
    assert RetentionPolicy.sentry_days() == 30
    assert RetentionPolicy.operator_backup_days() == 14
  end

  test "policy map is explicit and contains no participant-linked V1 learning or queue persistence allowance" do
    policy = RetentionPolicy.v1()

    assert policy.ordinary_live_conversation == {:server_durable_seconds, 0}
    assert policy.learning_records == :participant_linked_persistence_forbidden
    assert policy.queue_states == :durable_persistence_forbidden
    assert policy.legacy_messages == :ordinary_live_persistence_forbidden
    assert policy.legacy_message_reactions == :ordinary_live_persistence_forbidden
    assert policy.local_indexeddb == :user_controlled
    assert policy.user_exported_backups == :user_controlled
  end
end
