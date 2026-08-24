defmodule StrangertalksNew.Relationships do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Relationship
  alias StrangertalksNew.RelationshipConsent
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.ParticipantActivityLock
  alias Ecto.Multi

  @topic "strangertalks:matchmaking"

  def create_relationship(attrs \\ %{}) do
    %Relationship{}
    |> Relationship.changeset(attrs)
    |> Repo.insert()
  end

  def get_relationship(id) do
    Repo.get(Relationship, id)
  end

  def change_relationship(%Relationship{} = relationship, attrs \\ %{}) do
    Relationship.changeset(relationship, attrs)
  end

  def close_relationship(relationship_id, participant_id, closure_reason)
      when is_binary(relationship_id) and is_binary(participant_id) and
             closure_reason in [:PARTICIPANT_CLOSED, :BLOCKED, :SAFETY_ACTION] do
    case Repo.get(Relationship, relationship_id) do
      %Relationship{} = relationship ->
        participant_ids = [relationship.participant_a_id, relationship.participant_b_id]

        if participant_id in participant_ids do
          ParticipantActivityLock.with_participants(participant_ids, fn ->
            close_relationship_locked(relationship_id, participant_id, closure_reason)
          end)
        else
          {:error, :not_relationship_member}
        end

      nil ->
        {:error, :relationship_not_found}
    end
  end

  def close_relationship(_relationship_id, _participant_id, _closure_reason),
    do: {:error, :invalid_closure}

  def consent_to_relationship(conversation_id, participant_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{} = conversation ->
        with :ok <- authorize_member(conversation, participant_id) do
          ParticipantActivityLock.with_participants(
            [conversation.participant_a_id, conversation.participant_b_id],
            fn -> consent_to_relationship_locked(conversation_id, participant_id) end
          )
        end

      nil ->
        {:error, :conversation_not_found}
    end
  end

  defp consent_to_relationship_locked(conversation_id, participant_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:conversation_lock, fn repo, _changes ->
      case repo.one(
             from c in Conversation,
               where: c.conversation_id == ^conversation_id,
               lock: "FOR UPDATE"
           ) do
        %Conversation{} = locked_conversation ->
          with :ok <- authorize_member(locked_conversation, participant_id),
               :ok <- authorize_eligible_state(locked_conversation),
               :ok <- authorize_safety_boundary(locked_conversation) do
            {:ok, locked_conversation}
          end

        nil ->
          {:error, :conversation_not_found}
      end
    end)
    |> Multi.insert(
      :consent_attempt,
      fn %{conversation_lock: _conversation} ->
        RelationshipConsent.changeset(%RelationshipConsent{}, %{
          conversation_id: conversation_id,
          participant_id: participant_id,
          created_at: now
        })
      end,
      on_conflict: :nothing,
      conflict_target: [:conversation_id, :participant_id]
    )
    |> Multi.all(
      :consents,
      from(c in RelationshipConsent, where: c.conversation_id == ^conversation_id)
    )
    |> Multi.run(:relationship, fn repo,
                                   %{conversation_lock: conversation, consents: consents} ->
      if length(consents) == 2 do
        {participant_a_id, participant_b_id} =
          canonical_pair(conversation.participant_a_id, conversation.participant_b_id)

        match = repo.get!(Matching, conversation.match_id)
        origin_doors = doors_by_participant(match)

        attrs = %{
          created_at: now,
          updated_at: now,
          accepted_at: now,
          first_conversation_at: conversation.created_at,
          last_conversation_at: conversation.ended_at,
          last_activity_at: now,
          relationship_status: :ACTIVE,
          origin_door_type: conversation.door_type,
          origin_participant_a_door_type: Map.fetch!(origin_doors, participant_a_id),
          origin_participant_b_door_type: Map.fetch!(origin_doors, participant_b_id),
          participant_a_id: participant_a_id,
          participant_b_id: participant_b_id,
          origin_conversation_id: conversation.conversation_id,
          origin_match_id: conversation.match_id,
          participant_a_accepted: true,
          participant_b_accepted: true,
          allow_reconnection: true,
          reconnection_eligible: true,
          participant_a_closed: false,
          participant_b_closed: false,
          participant_a_blocked: false,
          participant_b_blocked: false,
          conversation_count: 1,
          memory_count: 0,
          reconnection_count: 0,
          shared_memory_count: 0,
          private_note_count: 0
        }

        existing_relationship =
          repo.one(
            from r in Relationship,
              where:
                r.participant_a_id == ^participant_a_id and
                  r.participant_b_id == ^participant_b_id
          )

        if existing_relationship do
          {:ok, {existing_relationship, false}}
        else
          %Relationship{}
          |> Relationship.changeset(attrs)
          |> repo.insert(on_conflict: :nothing)
          |> case do
            {:ok, _} ->
              {:ok,
               {repo.one!(
                  from r in Relationship,
                    where:
                      r.participant_a_id == ^participant_a_id and
                        r.participant_b_id == ^participant_b_id
                ), true}}

            error ->
              error
          end
        end
      else
        {:ok, nil}
      end
    end)
    |> Multi.run(:conversation_link, fn repo,
                                        %{conversation_lock: conversation, relationship: relationship_result} ->
      if relationship_result do
        {relationship, _created?} = relationship_result

        conversation
        |> Conversation.changeset(%{
          relationship_id: relationship.relationship_id,
          relationship_created: true,
          relationship_created_at_end: true
        })
        |> repo.update()
      else
        {:ok, conversation}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{relationship: nil}} ->
        {:ok, %{status: "waiting_for_mutual_consent"}}

      {:ok, %{conversation_lock: conversation, relationship: {relationship, created?}}} ->
        if created? do
          Phoenix.PubSub.broadcast(
            StrangertalksNew.PubSub,
            @topic,
            {:relationship_created, relationship.relationship_id, conversation.participant_a_id,
             conversation.participant_b_id}
          )
        end

        {:ok, %{status: "created", relationship_id: relationship.relationship_id}}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp authorize_member(conversation, participant_id) do
    if participant_id in [conversation.participant_a_id, conversation.participant_b_id],
      do: :ok,
      else: {:error, :not_conversation_member}
  end

  defp authorize_safety_boundary(conversation) do
    if MatchingRules.check_safety_veto?(
         conversation.participant_a_id,
         conversation.participant_b_id
       ),
      do: {:error, :relationship_unavailable},
      else: :ok
  end

  defp close_relationship_locked(relationship_id, participant_id, closure_reason) do
    case Repo.get(Relationship, relationship_id) do
      %Relationship{relationship_status: :CLOSED} ->
        {:ok, %{status: "closed"}}

      %Relationship{} = relationship ->
        closed_participant_field =
          if relationship.participant_a_id == participant_id,
            do: :participant_a_closed,
            else: :participant_b_closed

        relationship
        |> Relationship.changeset(%{
          closed_participant_field => true,
          relationship_status: :CLOSED,
          closure_reason: closure_reason,
          closed_at: DateTime.utc_now(),
          closed_by_participant_id: participant_id,
          allow_reconnection: false,
          reconnection_eligible: false
        })
        |> Repo.update()
        |> case do
          {:ok, _relationship} -> {:ok, %{status: "closed"}}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :relationship_not_found}
    end
  end

  defp authorize_eligible_state(conversation) do
    if eligible_conversation?(conversation),
      do: :ok,
      else: {:error, :conversation_inactive}
  end

  defp eligible_conversation?(conversation),
    do:
      conversation.conversation_status == :ENDED and conversation.conversation_completed == true and
        conversation.ending_type == :NATURAL_END

  defp canonical_pair(a, b), do: if(a < b, do: {a, b}, else: {b, a})

  defp doors_by_participant(match) do
    %{
      match.participant_a_id => match.participant_a_door_type,
      match.participant_b_id => match.participant_b_door_type
    }
  end
end
