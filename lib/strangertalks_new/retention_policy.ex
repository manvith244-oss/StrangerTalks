defmodule StrangertalksNew.RetentionPolicy do
  @moduledoc """
  Authoritative StrangerTalks V1 engineering retention policy.

  These values are product/security engineering rules. This module intentionally makes no legal
  compliance claim. Production scheduling belongs to release/operations authority, not this module.
  """

  @ordinary_live_conversation_seconds 0
  @safety_media_default_days 30
  @safety_media_hard_max_days 60
  @open_report_days 180
  @final_report_rich_evidence_days 90
  @safety_review_rich_notes_days 90
  @safety_event_rich_days 180
  @inactive_boundary_block_days 30
  @guest_inactivity_days 30
  @terminal_match_days 30
  @terminal_conversation_days 30
  @closed_relationship_rich_days 30
  @terminal_relationship_consent_days 30
  @operational_cleanup_hours 24
  @deleted_memory_days 7
  @reflection_backup_days 14
  @deleted_account_backup_days 14
  @expired_session_cleanup_days 30
  @revoked_session_cleanup_days 30
  @oauth_logical_minutes 10
  @revoked_google_link_days 30
  @analytics_days 90
  @posthog_days 90
  @sentry_days 30
  @operator_backup_days 14

  def ordinary_live_conversation_seconds, do: @ordinary_live_conversation_seconds
  def safety_media_default_days, do: @safety_media_default_days
  def safety_media_hard_max_days, do: @safety_media_hard_max_days
  def open_report_days, do: @open_report_days
  def final_report_rich_evidence_days, do: @final_report_rich_evidence_days
  def safety_review_rich_notes_days, do: @safety_review_rich_notes_days
  def safety_event_rich_days, do: @safety_event_rich_days
  def inactive_boundary_block_days, do: @inactive_boundary_block_days
  def guest_inactivity_days, do: @guest_inactivity_days
  def terminal_match_days, do: @terminal_match_days
  def terminal_conversation_days, do: @terminal_conversation_days
  def closed_relationship_rich_days, do: @closed_relationship_rich_days
  def terminal_relationship_consent_days, do: @terminal_relationship_consent_days
  def operational_cleanup_hours, do: @operational_cleanup_hours
  def deleted_memory_days, do: @deleted_memory_days
  def reflection_backup_days, do: @reflection_backup_days
  def deleted_account_backup_days, do: @deleted_account_backup_days
  def expired_session_cleanup_days, do: @expired_session_cleanup_days
  def revoked_session_cleanup_days, do: @revoked_session_cleanup_days
  def oauth_logical_minutes, do: @oauth_logical_minutes
  def revoked_google_link_days, do: @revoked_google_link_days
  def analytics_days, do: @analytics_days
  def posthog_days, do: @posthog_days
  def sentry_days, do: @sentry_days
  def operator_backup_days, do: @operator_backup_days

  @doc "Returns the complete named V1 retention contract for audit/tests."
  def v1 do
    %{
      ordinary_live_conversation: {:server_durable_seconds, @ordinary_live_conversation_seconds},
      safety_media: %{
        default_days: @safety_media_default_days,
        active_human_review_hard_max_days: @safety_media_hard_max_days
      },
      reports: %{
        open_max_days: @open_report_days,
        final_rich_evidence_days: @final_report_rich_evidence_days
      },
      safety_reviews: %{final_rich_notes_days: @safety_review_rich_notes_days},
      safety_events: %{rich_narrative_days: @safety_event_rich_days},
      boundary_blocks: %{inactive_history_days: @inactive_boundary_block_days},
      guest_participants: %{inactive_days: @guest_inactivity_days},
      matches: %{terminal_days: @terminal_match_days},
      conversations: %{terminal_days: @terminal_conversation_days},
      relationships: %{closed_rich_detail_days: @closed_relationship_rich_days},
      relationship_consents: %{terminal_days: @terminal_relationship_consent_days},
      reconnection_intents: %{physical_cleanup_hours: @operational_cleanup_hours},
      memories: %{deleted_primary_purge_days: @deleted_memory_days},
      reflections: %{backup_residual_days: @reflection_backup_days},
      deleted_accounts: %{backup_residual_days: @deleted_account_backup_days},
      sessions: %{
        expired_cleanup_days: @expired_session_cleanup_days,
        revoked_cleanup_days: @revoked_session_cleanup_days
      },
      oauth_attempts: %{
        logical_minutes: @oauth_logical_minutes,
        physical_cleanup_hours: @operational_cleanup_hours
      },
      google_links: %{revoked_metadata_days: @revoked_google_link_days},
      composer_grants: %{physical_cleanup_hours: @operational_cleanup_hours},
      analytics: %{rolling_days: @analytics_days},
      posthog: %{maximum_days: @posthog_days},
      sentry: %{maximum_days: @sentry_days},
      operator_backups: %{rolling_days: @operator_backup_days},
      local_indexeddb: :user_controlled,
      user_exported_backups: :user_controlled,
      learning_records: :participant_linked_persistence_forbidden,
      queue_states: :durable_persistence_forbidden,
      legacy_messages: :ordinary_live_persistence_forbidden,
      legacy_message_reactions: :ordinary_live_persistence_forbidden
    }
  end

  def cutoff_days(now, days) when is_struct(now, DateTime) and is_integer(days) and days >= 0,
    do: DateTime.add(now, -days * 86_400, :second)

  def cutoff_hours(now, hours) when is_struct(now, DateTime) and is_integer(hours) and hours >= 0,
    do: DateTime.add(now, -hours * 3_600, :second)
end
