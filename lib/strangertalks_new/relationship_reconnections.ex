defmodule StrangertalksNew.RelationshipReconnections do
  import Ecto.Query, warn: false

  alias Ecto.Multi

  alias StrangertalksNew.{
    Conversation,
    Matching,
    MatchingRules,
    Relationship,
    RelationshipReconnectionIntent,
    Repo
  }

  alias StrangertalksNew.QueueEngine.QueueState

  @topic "strangertalks:matchmaking"
  @availability_seconds 15 * 60

  def start_or_replace(relationship_id, participant_id, door_type) do
    with {:ok, relationship} <- eligible_relationship(relationship_id, participant_id) do
      case matched_or_idle(relationship, participant_id) do
        {:ok, %{status: "matched"} = result} -> {:ok, result}
        _ -> start_when_idle(relationship, participant_id, door_type)
      end
    else
      _ -> {:error, :reconnection_unavailable}
    end
  end

  defp start_when_idle(relationship, participant_id, door_type) do
    with :ok <- requester_available(participant_id),
         false <-
           MatchingRules.check_safety_veto?(
             relationship.participant_a_id,
             relationship.participant_b_id
           ) do
      case Repo.transaction(fn ->
             locked_start(relationship.relationship_id, participant_id, door_type)
           end) do
        {:ok, {:matched, conversation, updated}} ->
          Phoenix.PubSub.broadcast(
            StrangertalksNew.PubSub,
            @topic,
            {:bond_reconnect_matched, conversation.conversation_id, updated.participant_a_id,
             updated.participant_b_id}
          )

          {:ok, %{status: "matched", conversation_id: conversation.conversation_id}}

        {:ok, {:existing, conversation}} ->
          {:ok, %{status: "matched", conversation_id: conversation.conversation_id}}

        {:ok, {:waiting, intent}} ->
          {:ok, waiting_result(intent)}

        {:error, _reason} ->
          {:error, :reconnection_unavailable}
      end
    else
      _ -> {:error, :reconnection_unavailable}
    end
  end

  def cancel(relationship_id, participant_id) do
    now = DateTime.utc_now()

    with {:ok, _relationship} <- eligible_relationship(relationship_id, participant_id) do
      expire_stale(relationship_id, participant_id, now)

      from(i in RelationshipReconnectionIntent,
        where:
          i.relationship_id == ^relationship_id and i.participant_id == ^participant_id and
            i.status == :ACTIVE
      )
      |> Repo.update_all(set: [status: :CANCELLED, cancelled_at: now, updated_at: now])

      {:ok, %{status: "cancelled"}}
    else
      _ -> {:error, :reconnection_unavailable}
    end
  end

  def status(relationship_id, participant_id) do
    now = DateTime.utc_now()

    with {:ok, relationship} <- eligible_relationship(relationship_id, participant_id) do
      expire_stale(relationship_id, participant_id, now)

      case own_active_intent(relationship_id, participant_id) do
        %RelationshipReconnectionIntent{} = intent -> {:ok, waiting_result(intent)}
        nil -> matched_or_idle(relationship, participant_id)
      end
    else
      _ -> {:error, :reconnection_unavailable}
    end
  end

  defp locked_start(relationship_id, participant_id, door_type) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [relationship_id])
    now = DateTime.utc_now()

    relationship =
      Repo.one!(
        from r in Relationship, where: r.relationship_id == ^relationship_id, lock: "FOR UPDATE"
      )

    case matched_or_idle(relationship, participant_id) do
      {:ok, %{status: "matched", conversation_id: conversation_id}} ->
        {:existing, Repo.get!(Conversation, conversation_id)}

      _ ->
        locked_start_idle(relationship, participant_id, door_type, now)
    end
  end

  defp locked_start_idle(relationship, participant_id, door_type, now) do
    unless valid_relationship?(relationship, participant_id) and
             requester_available?(participant_id) and
             not MatchingRules.check_safety_veto?(
               relationship.participant_a_id,
               relationship.participant_b_id
             ),
           do: Repo.rollback(:reconnection_unavailable)

    relationship_id = relationship.relationship_id
    expire_stale(relationship_id, participant_id, now)
    intent = upsert_own_intent(relationship, participant_id, door_type, now)

    other_id =
      if participant_id == relationship.participant_a_id,
        do: relationship.participant_b_id,
        else: relationship.participant_a_id

    other =
      Repo.one(
        from i in RelationshipReconnectionIntent,
          where:
            i.relationship_id == ^relationship_id and i.participant_id == ^other_id and
              i.status == :ACTIVE and i.door_type == ^door_type and i.expires_at > ^now,
          lock: "FOR UPDATE"
      )

    if other && requester_available?(other_id) do
      persist_reconnect(relationship, intent, other, now)
    else
      {:waiting, intent}
    end
  end

  defp upsert_own_intent(relationship, participant_id, door_type, now) do
    case own_active_intent(relationship.relationship_id, participant_id, "FOR UPDATE") do
      %RelationshipReconnectionIntent{door_type: ^door_type} = intent ->
        intent

      %RelationshipReconnectionIntent{} = intent ->
        intent
        |> RelationshipReconnectionIntent.changeset(%{
          door_type: door_type,
          created_at: now,
          updated_at: now,
          expires_at: DateTime.add(now, @availability_seconds, :second)
        })
        |> Repo.update!()

      nil ->
        %RelationshipReconnectionIntent{}
        |> RelationshipReconnectionIntent.changeset(%{
          relationship_id: relationship.relationship_id,
          participant_id: participant_id,
          door_type: door_type,
          status: :ACTIVE,
          created_at: now,
          updated_at: now,
          expires_at: DateTime.add(now, @availability_seconds, :second)
        })
        |> Repo.insert!()
    end
  end

  defp persist_reconnect(relationship, intent, other, now) do
    first_at =
      Enum.min_by([intent.created_at, other.created_at], &DateTime.to_unix(&1, :microsecond))

    participant_ids = Enum.sort([relationship.participant_a_id, relationship.participant_b_id])

    match_attrs = %{
      created_at: now,
      door_type: intent.door_type,
      match_status: :CREATED,
      match_strategy: :relationship_reconnect_v1,
      participant_a_id: hd(participant_ids),
      participant_b_id: List.last(participant_ids),
      compatibility_score: nil,
      queue_entry_time: first_at,
      match_found_time: now,
      queue_duration_seconds: max(0, DateTime.diff(now, first_at, :second)),
      conversation_duration_seconds: 0,
      conversation_started: false,
      conversation_completed: false,
      memory_created: false,
      relationship_created: false,
      reconnected_later: true,
      report_generated: false,
      block_generated: false,
      safety_review_required: false,
      learning_processed: false
    }

    multi =
      Multi.new()
      |> Multi.insert(:match, Matching.changeset(%Matching{}, match_attrs))
      |> Multi.insert(:conversation, fn %{match: match} ->
        Conversation.changeset(%Conversation{}, %{
          created_at: now,
          match_id: match.match_id,
          participant_a_id: match.participant_a_id,
          participant_b_id: match.participant_b_id,
          conversation_status: :PENDING,
          door_type: intent.door_type,
          relationship_id: relationship.relationship_id,
          message_count: 0,
          voice_note_count: 0,
          bridge_shown: false,
          bridge_used: false,
          bridge_ignored: false,
          conversation_completed: false,
          memory_created: false,
          relationship_created: false,
          reconnected_later: true,
          memory_count: 0,
          relationship_created_at_end: false,
          report_count: 0,
          block_count: 0,
          safety_flagged: false,
          learning_processed: false,
          duration_seconds: 0
        })
      end)
      |> Multi.update_all(
        :consume_intents,
        from(i in RelationshipReconnectionIntent,
          where:
            i.reconnect_intent_id in ^[intent.reconnect_intent_id, other.reconnect_intent_id] and
              i.status == :ACTIVE
        ),
        set: [status: :CONSUMED, consumed_at: now, updated_at: now]
      )
      |> Multi.run(:both_consumed, fn
        _repo, %{consume_intents: {2, _}} -> {:ok, true}
        _repo, _ -> {:error, :intent_race}
      end)
      |> Multi.update(:relationship, fn %{conversation: conversation} ->
        Relationship.changeset(relationship, %{
          latest_conversation_id: conversation.conversation_id,
          last_activity_at: now,
          updated_at: now,
          reconnection_count: relationship.reconnection_count + 1
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{conversation: conversation, relationship: updated}} ->
        {:matched, conversation, updated}

      {:error, _step, reason, _changes} ->
        Repo.rollback(reason)
    end
  end

  defp eligible_relationship(id, participant_id) do
    case Repo.get(Relationship, id) do
      %Relationship{} = relationship ->
        if valid_relationship?(relationship, participant_id),
          do: {:ok, relationship},
          else: {:error, :unavailable}

      nil ->
        {:error, :unavailable}
    end
  end

  defp valid_relationship?(relationship, participant_id),
    do:
      participant_id in [relationship.participant_a_id, relationship.participant_b_id] and
        relationship.relationship_status == :ACTIVE and relationship.allow_reconnection and
        relationship.reconnection_eligible and not relationship.participant_a_blocked and
        not relationship.participant_b_blocked

  defp requester_available(participant_id),
    do: if(requester_available?(participant_id), do: :ok, else: {:error, :unavailable})

  defp requester_available?(participant_id),
    do: not queued?(participant_id) and not active_conversation?(participant_id)

  defp queued?(participant_id), do: Agent.get(QueueState, &Map.has_key?(&1, participant_id))

  defp active_conversation?(participant_id),
    do:
      Repo.exists?(
        from c in Conversation,
          where:
            c.conversation_status in [:PENDING, :ACTIVE] and
              (c.participant_a_id == ^participant_id or c.participant_b_id == ^participant_id)
      )

  defp expire_stale(relationship_id, participant_id, now) do
    from(i in RelationshipReconnectionIntent,
      where:
        i.relationship_id == ^relationship_id and i.participant_id == ^participant_id and
          i.status == :ACTIVE and i.expires_at <= ^now
    )
    |> Repo.update_all(set: [status: :EXPIRED, updated_at: now])
  end

  defp own_active_intent(relationship_id, participant_id, lock \\ nil) do
    query =
      from i in RelationshipReconnectionIntent,
        where:
          i.relationship_id == ^relationship_id and i.participant_id == ^participant_id and
            i.status == :ACTIVE

    query = if lock, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp waiting_result(intent),
    do: %{
      status: "waiting_for_mutual_availability",
      door_type: Atom.to_string(intent.door_type),
      expires_at: DateTime.to_iso8601(intent.expires_at)
    }

  defp matched_or_idle(relationship, participant_id) do
    consumed? =
      Repo.exists?(
        from i in RelationshipReconnectionIntent,
          where:
            i.relationship_id == ^relationship.relationship_id and
              i.participant_id == ^participant_id and i.status == :CONSUMED
      )

    conversation =
      if consumed? && relationship.latest_conversation_id,
        do: Repo.get(Conversation, relationship.latest_conversation_id)

    if conversation && conversation.conversation_status in [:PENDING, :ACTIVE],
      do: {:ok, %{status: "matched", conversation_id: conversation.conversation_id}},
      else: {:ok, %{status: "idle"}}
  end
end
