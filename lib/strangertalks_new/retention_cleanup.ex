defmodule StrangertalksNew.RetentionCleanup do
  @moduledoc """
  Bounded, idempotent execution of the Command-approved StrangerTalks V1 retention policy.

  Each category runs in its own database transaction. A failure in one category is returned as a
  bounded error and does not roll back or suppress independent categories. This module does not
  schedule itself; production cadence belongs to release/operations authority.
  """

  alias StrangertalksNew.{Repo, RetentionPolicy}

  @terminal_conversation_statuses ~w(ENDED ABANDONED FAILED)
  @terminal_match_statuses ~w(ENDED FAILED EXPIRED)

  @doc "Runs every approved primary-database cleanup category once."
  def run(now \\ DateTime.utc_now()) when is_struct(now, DateTime) do
    now = DateTime.truncate(now, :microsecond)

    run_tasks([
      {:oauth_attempts, fn -> cleanup_oauth_attempts(now) end},
      {:account_sessions, fn -> cleanup_account_sessions(now) end},
      {:reconnect_intents, fn -> cleanup_reconnect_intents(now) end},
      {:composer_grants, fn -> cleanup_composer_grants(now) end},
      {:safety_media, fn -> cleanup_safety_media(now) end},
      {:reports, fn -> cleanup_reports(now) end},
      {:safety_reviews, fn -> cleanup_safety_reviews(now) end},
      {:safety_events, fn -> cleanup_safety_events(now) end},
      {:boundary_blocks, fn -> cleanup_boundary_blocks(now) end},
      {:deleted_memories, fn -> cleanup_deleted_memories(now) end},
      {:relationship_consents, fn -> cleanup_relationship_consents(now) end},
      {:closed_relationships, fn -> minimize_closed_relationships(now) end},
      {:conversations, fn -> cleanup_terminal_conversations(now) end},
      {:matches, fn -> cleanup_terminal_matches(now) end},
      {:analytics, fn -> cleanup_analytics(now) end},
      {:revoked_google_links, fn -> cleanup_revoked_google_links(now) end},
      {:inactive_guests, fn -> cleanup_inactive_guests(now) end}
    ])
  end

  @doc false
  def run_tasks(tasks) when is_list(tasks) do
    Enum.reduce(tasks, %{}, fn {name, fun}, acc ->
      Map.put(acc, name, run_task(fun))
    end)
  end

  defp run_task(fun) when is_function(fun, 0) do
    try do
      case Repo.transaction(fun) do
        {:ok, {:ok, count}} -> {:ok, count}
        {:ok, count} when is_integer(count) or is_map(count) -> {:ok, count}
        {:ok, other} -> other
        {:error, reason} -> {:error, reason}
      end
    rescue
      error -> {:error, {:exception, error}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc false
  def safety_media_disposition(created_at, active_human_review?, now)
      when is_struct(created_at, DateTime) and is_boolean(active_human_review?) and
             is_struct(now, DateTime) do
    age_seconds = DateTime.diff(now, created_at, :second)
    default_seconds = RetentionPolicy.safety_media_default_days() * 86_400
    hard_max_seconds = RetentionPolicy.safety_media_hard_max_days() * 86_400

    cond do
      age_seconds >= hard_max_seconds -> :delete
      age_seconds >= default_seconds and active_human_review? -> :retain
      age_seconds >= default_seconds -> :delete
      true -> :retain
    end
  end

  @doc false
  def terminal_conversation_expired?(status, ended_at, now) do
    status = normalize_status(status)

    status in @terminal_conversation_statuses and is_struct(ended_at, DateTime) and
      DateTime.compare(
        ended_at,
        RetentionPolicy.cutoff_days(now, RetentionPolicy.terminal_conversation_days())
      ) in [:lt, :eq]
  end

  @doc false
  def terminal_match_expired?(status, terminal_at, now) do
    status = normalize_status(status)

    status in @terminal_match_statuses and is_struct(terminal_at, DateTime) and
      DateTime.compare(
        terminal_at,
        RetentionPolicy.cutoff_days(now, RetentionPolicy.terminal_match_days())
      ) in [:lt, :eq]
  end

  @doc false
  def operational_record_expired?(terminal_at, now) when is_struct(terminal_at, DateTime) do
    DateTime.compare(
      terminal_at,
      RetentionPolicy.cutoff_hours(now, RetentionPolicy.operational_cleanup_hours())
    ) in [:lt, :eq]
  end

  def operational_record_expired?(_, _), do: false

  @doc false
  def deleted_memory_expired?(deleted_at, now) when is_struct(deleted_at, DateTime) do
    DateTime.compare(
      deleted_at,
      RetentionPolicy.cutoff_days(now, RetentionPolicy.deleted_memory_days())
    ) in [:lt, :eq]
  end

  def deleted_memory_expired?(_, _), do: false

  @doc false
  def analytics_expired?(created_at, now) when is_struct(created_at, DateTime) do
    DateTime.compare(
      created_at,
      RetentionPolicy.cutoff_days(now, RetentionPolicy.analytics_days())
    ) in [:lt, :eq]
  end

  def analytics_expired?(_, _), do: false

  defp cleanup_oauth_attempts(now) do
    cutoff = RetentionPolicy.cutoff_hours(now, RetentionPolicy.operational_cleanup_hours())

    delete_count(
      """
      DELETE FROM google_oauth_attempts
      WHERE (consumed_at IS NOT NULL AND consumed_at <= $1)
         OR expires_at <= $1
      """,
      [cutoff]
    )
  end

  defp cleanup_account_sessions(now) do
    expired_cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.expired_session_cleanup_days())

    revoked_cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.revoked_session_cleanup_days())

    delete_count(
      """
      DELETE FROM account_sessions
      WHERE expires_at <= $1
         OR (revoked_at IS NOT NULL AND revoked_at <= $2)
      """,
      [expired_cutoff, revoked_cutoff]
    )
  end

  defp cleanup_reconnect_intents(now) do
    cutoff = RetentionPolicy.cutoff_hours(now, RetentionPolicy.operational_cleanup_hours())

    delete_count(
      """
      DELETE FROM relationship_reconnection_intents
      WHERE (status = 'CONSUMED' AND COALESCE(consumed_at, updated_at) <= $1)
         OR (status = 'CANCELLED' AND COALESCE(cancelled_at, updated_at) <= $1)
         OR (status = 'EXPIRED' AND COALESCE(expires_at, updated_at) <= $1)
         OR (status = 'ACTIVE' AND expires_at <= $1)
      """,
      [cutoff]
    )
  end

  defp cleanup_composer_grants(now) do
    cutoff = RetentionPolicy.cutoff_hours(now, RetentionPolicy.operational_cleanup_hours())

    delete_count(
      """
      DELETE FROM composer_grants
      WHERE (state <> 'OPEN' AND updated_at <= $1)
         OR (terminal_expires_at IS NOT NULL AND terminal_expires_at <= $1)
      """,
      [cutoff]
    )
  end

  defp cleanup_safety_media(now) do
    default_cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.safety_media_default_days())

    hard_cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.safety_media_hard_max_days())

    delete_count(
      """
      DELETE FROM report_safety_media media
      WHERE media.created_at <= $1
        AND (
          media.created_at <= $2
          OR NOT EXISTS (
            SELECT 1
            FROM safety_reviews review
            WHERE review.report_id = media.report_id
              AND review.status = 'IN_REVIEW'
          )
        )
      """,
      [default_cutoff, hard_cutoff]
    )
  end

  defp cleanup_reports(now) do
    final_cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.final_report_rich_evidence_days())

    open_cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.open_report_days())

    final =
      update_count(
        """
        UPDATE reports
        SET reporter_context = NULL,
            reported_message_id = NULL
        WHERE report_status IN ('RESOLVED', 'DISMISSED')
          AND COALESCE(resolved_at, updated_at, created_at) <= $1
          AND (reporter_context IS NOT NULL OR reported_message_id IS NOT NULL)
        """,
        [final_cutoff]
      )

    open =
      update_count(
        """
        UPDATE reports
        SET reporter_context = NULL,
            reported_message_id = NULL
        WHERE report_status IN ('SUBMITTED', 'UNDER_REVIEW')
          AND created_at <= $1
          AND (reporter_context IS NOT NULL OR reported_message_id IS NOT NULL)
        """,
        [open_cutoff]
      )

    merge_counts(final, open)
  end

  defp cleanup_safety_reviews(now) do
    cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.safety_review_rich_notes_days())

    update_count(
      """
      UPDATE safety_reviews
      SET review_notes = NULL
      WHERE status IN ('RESOLVED', 'DISMISSED')
        AND COALESCE(reviewed_at, updated_at, created_at) <= $1
        AND review_notes IS NOT NULL
      """,
      [cutoff]
    )
  end

  defp cleanup_safety_events(now) do
    cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.safety_event_rich_days())

    deleted =
      delete_count(
        """
        DELETE FROM safety_events event
        WHERE event.event_status IN ('RESOLVED', 'DISMISSED')
          AND COALESCE(event.review_completed_at, event.updated_at, event.created_at) <= $1
          AND COALESCE(event.action_type, 'NONE') = 'NONE'
          AND COALESCE(event.block_created, FALSE) = FALSE
          AND NOT EXISTS (
            SELECT 1 FROM boundary_blocks block
            WHERE block.active_status = TRUE
              AND (
                block.blocker_user_id IN (event.reporting_participant_id, event.target_participant_id, event.affected_participant_id)
                OR block.blocked_user_id IN (event.reporting_participant_id, event.target_participant_id, event.affected_participant_id)
              )
          )
        """,
        [cutoff]
      )

    minimized =
      update_count(
        """
        UPDATE safety_events
        SET report_description = NULL,
            safety_summary = '{}'::jsonb,
            contains_sensitive_data = FALSE
        WHERE event_status IN ('RESOLVED', 'DISMISSED')
          AND COALESCE(review_completed_at, updated_at, created_at) <= $1
          AND (
            report_description IS NOT NULL
            OR COALESCE(safety_summary, '{}'::jsonb) <> '{}'::jsonb
            OR contains_sensitive_data = TRUE
          )
        """,
        [cutoff]
      )

    merge_counts(deleted, minimized)
  end

  defp cleanup_boundary_blocks(now) do
    cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.inactive_boundary_block_days())

    delete_count(
      """
      DELETE FROM boundary_blocks
      WHERE active_status = FALSE
        AND timestamp <= $1
        AND NOT EXISTS (
          SELECT 1 FROM safety_events event
          WHERE event.event_status IN ('OPEN', 'UNDER_REVIEW')
            AND (
              event.reporting_participant_id IN (boundary_blocks.blocker_user_id, boundary_blocks.blocked_user_id)
              OR event.target_participant_id IN (boundary_blocks.blocker_user_id, boundary_blocks.blocked_user_id)
              OR event.affected_participant_id IN (boundary_blocks.blocker_user_id, boundary_blocks.blocked_user_id)
            )
        )
      """,
      [cutoff]
    )
  end

  defp cleanup_deleted_memories(now) do
    cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.deleted_memory_days())

    delete_count("DELETE FROM memories WHERE deleted_at IS NOT NULL AND deleted_at <= $1", [
      cutoff
    ])
  end

  defp cleanup_relationship_consents(now) do
    cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.terminal_relationship_consent_days())

    delete_count(
      """
      DELETE FROM relationship_consents consent
      USING conversations conversation
      WHERE consent.conversation_id = conversation.conversation_id
        AND consent.created_at <= $1
        AND conversation.conversation_status IN ('ENDED', 'ABANDONED', 'FAILED')
      """,
      [cutoff]
    )
  end

  defp minimize_closed_relationships(now) do
    cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.closed_relationship_rich_days())

    update_count(
      """
      UPDATE relationships
      SET relationship_name = NULL,
          participant_custom_name = NULL,
          most_common_atmosphere = NULL,
          learning_version = 'retention-minimized',
          learning_processed = FALSE,
          reconnection_priority = 0.0000,
          relationship_strength_score = 0.0000,
          continuation_probability = 0.0000,
          relationship_temperature = 0.0000,
          atmosphere_history = '{}'::jsonb,
          relationship_summary = '{}'::jsonb,
          latest_note_at = NULL,
          latest_memory_id = NULL,
          featured_memory_id = NULL,
          private_note_count = 0
      WHERE relationship_status = 'CLOSED'
        AND closed_at IS NOT NULL
        AND closed_at <= $1
        AND (
          relationship_name IS NOT NULL
          OR participant_custom_name IS NOT NULL
          OR most_common_atmosphere IS NOT NULL
          OR learning_version <> 'retention-minimized'
          OR learning_processed <> FALSE
          OR reconnection_priority <> 0.0000
          OR relationship_strength_score <> 0.0000
          OR continuation_probability <> 0.0000
          OR relationship_temperature <> 0.0000
          OR atmosphere_history <> '{}'::jsonb
          OR relationship_summary <> '{}'::jsonb
          OR latest_note_at IS NOT NULL
          OR latest_memory_id IS NOT NULL
          OR featured_memory_id IS NOT NULL
          OR private_note_count <> 0
        )
      """,
      [cutoff]
    )
  end

  defp cleanup_terminal_conversations(now) do
    cutoff =
      RetentionPolicy.cutoff_days(now, RetentionPolicy.terminal_conversation_days())

    delete_count(
      """
      DELETE FROM conversations conversation
      WHERE conversation.conversation_status IN ('ENDED', 'ABANDONED', 'FAILED')
        AND conversation.ended_at IS NOT NULL
        AND conversation.ended_at <= $1
        AND NOT EXISTS (SELECT 1 FROM reports report WHERE report.conversation_id = conversation.conversation_id)
        AND NOT EXISTS (SELECT 1 FROM safety_events event WHERE event.conversation_id = conversation.conversation_id)
        AND NOT EXISTS (SELECT 1 FROM relationships relationship WHERE relationship.origin_conversation_id = conversation.conversation_id)
        AND NOT EXISTS (SELECT 1 FROM memories memory WHERE memory.conversation_id = conversation.conversation_id)
        AND NOT EXISTS (SELECT 1 FROM relationship_consents consent WHERE consent.conversation_id = conversation.conversation_id)
      """,
      [cutoff]
    )
  end

  defp cleanup_terminal_matches(now) do
    cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.terminal_match_days())

    delete_count(
      """
      DELETE FROM matches match
      WHERE match.match_status IN ('ENDED', 'FAILED', 'EXPIRED')
        AND COALESCE(match.match_end_time, match.created_at) <= $1
        AND NOT EXISTS (SELECT 1 FROM conversations conversation WHERE conversation.match_id = match.match_id)
        AND NOT EXISTS (SELECT 1 FROM relationships relationship WHERE relationship.origin_match_id = match.match_id)
        AND NOT EXISTS (SELECT 1 FROM memories memory WHERE memory.match_id = match.match_id)
        AND NOT EXISTS (SELECT 1 FROM safety_events event WHERE event.match_id = match.match_id)
      """,
      [cutoff]
    )
  end

  defp cleanup_analytics(now) do
    cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.analytics_days())
    delete_count("DELETE FROM analytics_records WHERE created_at <= $1", [cutoff])
  end

  defp cleanup_revoked_google_links(now) do
    cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.revoked_google_link_days())

    delete_count(
      """
      DELETE FROM google_account_links link
      USING private_accounts account
      WHERE link.account_id = account.account_id
        AND link.revoked_at IS NOT NULL
        AND link.revoked_at <= $1
        AND link.encrypted_refresh_token IS NULL
        AND link.refresh_token_iv IS NULL
        AND link.refresh_token_tag IS NULL
        AND link.token_key_version IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM reports report
          WHERE report.report_status IN ('SUBMITTED', 'UNDER_REVIEW')
            AND account.participant_id IN (report.reporting_participant_id, report.reported_participant_id)
        )
        AND NOT EXISTS (
          SELECT 1 FROM boundary_blocks block
          WHERE block.active_status = TRUE
            AND account.participant_id IN (block.blocker_user_id, block.blocked_user_id)
        )
        AND NOT EXISTS (
          SELECT 1 FROM safety_events event
          WHERE event.event_status IN ('OPEN', 'UNDER_REVIEW')
            AND account.participant_id IN (event.reporting_participant_id, event.target_participant_id, event.affected_participant_id)
        )
      """,
      [cutoff]
    )
  end

  defp cleanup_inactive_guests(now) do
    cutoff = RetentionPolicy.cutoff_days(now, RetentionPolicy.guest_inactivity_days())

    delete_count(
      """
      DELETE FROM participants participant
      WHERE participant.presence_state = 'OFFLINE'
        AND COALESCE(participant.last_active_at, participant.created_at) <= $1
        AND NOT EXISTS (SELECT 1 FROM private_accounts account WHERE account.participant_id = participant.participant_id)
        AND NOT EXISTS (SELECT 1 FROM conversations conversation WHERE participant.participant_id IN (conversation.participant_a_id, conversation.participant_b_id))
        AND NOT EXISTS (SELECT 1 FROM matches match WHERE participant.participant_id IN (match.participant_a_id, match.participant_b_id))
        AND NOT EXISTS (SELECT 1 FROM relationships relationship WHERE participant.participant_id IN (relationship.participant_a_id, relationship.participant_b_id))
        AND NOT EXISTS (SELECT 1 FROM relationship_consents consent WHERE consent.participant_id = participant.participant_id)
        AND NOT EXISTS (SELECT 1 FROM relationship_reconnection_intents intent WHERE intent.participant_id = participant.participant_id)
        AND NOT EXISTS (SELECT 1 FROM reports report WHERE participant.participant_id IN (report.reporting_participant_id, report.reported_participant_id))
        AND NOT EXISTS (SELECT 1 FROM safety_events event WHERE participant.participant_id IN (event.reporting_participant_id, event.target_participant_id, event.affected_participant_id))
        AND NOT EXISTS (SELECT 1 FROM boundary_blocks block WHERE participant.participant_id IN (block.blocker_user_id, block.blocked_user_id))
        AND NOT EXISTS (SELECT 1 FROM memories memory WHERE memory.owner_participant_id = participant.participant_id)
        AND NOT EXISTS (SELECT 1 FROM reflections reflection WHERE reflection.owner_participant_id = participant.participant_id)
        AND NOT EXISTS (SELECT 1 FROM composer_grants composer_grant WHERE composer_grant.owner_participant_id = participant.participant_id)
      """,
      [cutoff]
    )
  end

  defp delete_count(sql, params), do: query_count(sql, params)
  defp update_count(sql, params), do: query_count(sql, params)

  defp query_count(sql, params) do
    result = Ecto.Adapters.SQL.query!(Repo, sql, params)
    {:ok, result.num_rows || 0}
  end

  defp merge_counts({:ok, first}, {:ok, second}), do: {:ok, first + second}

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_), do: ""
end
