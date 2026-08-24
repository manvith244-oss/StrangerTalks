defmodule StrangertalksNew.Intelligence.V1Metrics do
  @moduledoc """
  Privacy-safe, read-only V1 intelligence over canonical durable product records.

  This module intentionally does not create a second raw-event store. It derives a
  small operator snapshot from already-authoritative Match, Conversation,
  Relationship and Report rows. No participant, conversation, match, message,
  report, account or content identifiers are returned.
  """

  import Ecto.Query, warn: false

  alias StrangertalksNew.{Conversation, Matching, Relationship, Repo, Report}

  @schema_version "team8-v1-metrics-1"
  @max_window_seconds 31 * 24 * 60 * 60

  @forbidden_output_keys MapSet.new([
                           :participant_id,
                           :participant_a_id,
                           :participant_b_id,
                           :conversation_id,
                           :match_id,
                           :message_id,
                           :reported_message_id,
                           :reporting_participant_id,
                           :reported_participant_id,
                           :reporter_context,
                           :deduplication_key,
                           :content,
                           :text,
                           :body,
                           :audio,
                           :transcript,
                           :token,
                           :email,
                           :name,
                           :photo,
                           :ip,
                           :ip_address,
                           :memory_text,
                           :summary_text,
                           :learning_summary,
                           :keystroke_cadence,
                           :keystroke_latency_variance,
                           :readiness_score
                         ])

  @metric_dictionary [
    %{
      name: :matches_created,
      definition: "Canonical Match rows created inside the reporting window.",
      source: "matches.created_at",
      interpretation: "Operational matching throughput.",
      non_goal: "Must not be interpreted as Conversation quality or participant satisfaction."
    },
    %{
      name: :same_door_matches,
      definition: "Matches where both participants entered through the same Door.",
      source: "matches participant_a_door_type / participant_b_door_type",
      interpretation: "How often deterministic matching stayed within the exact-Door path.",
      non_goal: "Must not be used to infer personal compatibility."
    },
    %{
      name: :cross_door_matches,
      definition: "Matches where the two canonical entry Doors differ.",
      source: "matches participant_a_door_type / participant_b_door_type",
      interpretation: "Observed use of the approved scarcity cross-Door path.",
      non_goal: "Must not automatically change cross-Door timing or policy."
    },
    %{
      name: :average_queue_time_seconds,
      definition:
        "Arithmetic mean of persisted queue_duration_seconds for Matches in the window.",
      source: "matches.queue_duration_seconds",
      interpretation: "Operational wait experienced by successfully matched attempts.",
      non_goal:
        "Does not describe people who never produced a Match and is not a happiness score."
    },
    %{
      name: :conversations_started,
      definition: "Canonical Conversation rows created inside the reporting window.",
      source: "conversations.created_at",
      interpretation: "Conversation creation reliability/throughput.",
      non_goal: "Creation alone does not prove a worthwhile human Conversation."
    },
    %{
      name: :natural_ends,
      definition: "Conversations ending with NATURAL_END inside the reporting window.",
      source: "conversations.ended_at + ending_type",
      interpretation: "Voluntary non-safety terminal outcomes.",
      non_goal: "A natural ending is not automatically a positive emotional outcome."
    },
    %{
      name: :technical_disconnects,
      definition: "Conversations ending with DISCONNECT inside the reporting window.",
      source: "conversations.ended_at + ending_type",
      interpretation: "A bounded technical-survival failure signal.",
      non_goal: "Must not be interpreted as participant rejection or low connection quality."
    },
    %{
      name: :failed_conversations,
      definition: "Conversations with FAILED status and ended_at inside the reporting window.",
      source: "conversations.ended_at + conversation_status",
      interpretation: "Durable Conversation failures requiring reliability review.",
      non_goal: "Does not authorize automatic runtime or product-policy changes."
    },
    %{
      name: :voluntary_relationships_created,
      definition:
        "Canonical Relationship rows created after mutual consent inside the reporting window.",
      source: "relationships.created_at",
      interpretation:
        "A strong explicit continuation signal because Relationship creation requires mutual consent.",
      non_goal: "Must not be generalized into a psychological or relationship-strength score."
    },
    %{
      name: :reports_submitted,
      definition: "Canonical Report rows created inside the reporting window.",
      source: "reports.created_at",
      interpretation: "Aggregate use of the report safety boundary.",
      non_goal: "Must not expose report evidence or automatically punish participants."
    },
    %{
      name: :block_terminated_conversations,
      definition: "Conversations ending with BLOCK inside the reporting window.",
      source: "conversations.ended_at + ending_type",
      interpretation: "Aggregate use of the in-Conversation block terminal boundary.",
      non_goal: "Does not represent all BoundaryBlocks created from every product surface."
    }
  ]

  def schema_version, do: @schema_version
  def metric_dictionary, do: @metric_dictionary

  @doc """
  Returns a bounded, privacy-safe aggregate snapshot for `[from, to)`.

  The V1 query window is capped at 31 days so an operator report cannot casually
  become an unbounded production scan on the single-server architecture.
  """
  def snapshot(%DateTime{} = from, %DateTime{} = to) do
    with :ok <- validate_window(from, to) do
      snapshot = build_snapshot(from, to)

      if safe_output?(snapshot) do
        {:ok, snapshot}
      else
        {:error, :unsafe_analytics_output}
      end
    end
  end

  def snapshot(_from, _to), do: {:error, :invalid_analytics_window}

  @doc "Returns true only when a nested analytics payload contains no forbidden V1 keys."
  def safe_output?(value), do: not contains_forbidden_key?(value)

  defp validate_window(from, to) do
    seconds = DateTime.diff(to, from, :second)

    cond do
      seconds <= 0 -> {:error, :invalid_analytics_window}
      seconds > @max_window_seconds -> {:error, :analytics_window_too_large}
      true -> :ok
    end
  end

  defp build_snapshot(from, to) do
    match_query =
      from m in Matching,
        where: m.created_at >= ^from and m.created_at < ^to

    conversation_started_query =
      from c in Conversation,
        where: c.created_at >= ^from and c.created_at < ^to

    conversation_ended_query =
      from c in Conversation,
        where: not is_nil(c.ended_at) and c.ended_at >= ^from and c.ended_at < ^to

    relationship_query =
      from r in Relationship,
        where: r.created_at >= ^from and r.created_at < ^to

    report_query =
      from r in Report,
        where: r.created_at >= ^from and r.created_at < ^to

    %{
      schema_version: @schema_version,
      window: %{
        from: DateTime.to_iso8601(from),
        to: DateTime.to_iso8601(to)
      },
      system: %{
        matches_created: Repo.aggregate(match_query, :count, :match_id),
        same_door_matches:
          Repo.aggregate(
            from(m in match_query,
              where: m.participant_a_door_type == m.participant_b_door_type
            ),
            :count,
            :match_id
          ),
        cross_door_matches:
          Repo.aggregate(
            from(m in match_query,
              where: m.participant_a_door_type != m.participant_b_door_type
            ),
            :count,
            :match_id
          ),
        average_queue_time_seconds: average_queue_time(match_query),
        conversations_started:
          Repo.aggregate(conversation_started_query, :count, :conversation_id),
        natural_ends:
          Repo.aggregate(
            from(c in conversation_ended_query, where: c.ending_type == :NATURAL_END),
            :count,
            :conversation_id
          ),
        technical_disconnects:
          Repo.aggregate(
            from(c in conversation_ended_query, where: c.ending_type == :DISCONNECT),
            :count,
            :conversation_id
          ),
        failed_conversations:
          Repo.aggregate(
            from(c in conversation_ended_query, where: c.conversation_status == :FAILED),
            :count,
            :conversation_id
          )
      },
      human_outcomes: %{
        voluntary_relationships_created:
          Repo.aggregate(relationship_query, :count, :relationship_id),
        reports_submitted: Repo.aggregate(report_query, :count, :report_id),
        block_terminated_conversations:
          Repo.aggregate(
            from(c in conversation_ended_query, where: c.ending_type == :BLOCK),
            :count,
            :conversation_id
          )
      }
    }
  end

  defp average_queue_time(match_query) do
    match_query
    |> select([m], avg(m.queue_duration_seconds))
    |> Repo.one()
    |> case do
      nil -> 0.0
      %Decimal{} = value -> Decimal.to_float(value)
      value when is_number(value) -> value * 1.0
    end
  end

  defp contains_forbidden_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      normalized_key = normalize_key(key)
      MapSet.member?(@forbidden_output_keys, normalized_key) or contains_forbidden_key?(value)
    end)
  end

  defp contains_forbidden_key?(list) when is_list(list),
    do: Enum.any?(list, &contains_forbidden_key?/1)

  defp contains_forbidden_key?(_value), do: false

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> :unknown_external_key
    end
  end

  defp normalize_key(_key), do: :unknown_external_key
end
