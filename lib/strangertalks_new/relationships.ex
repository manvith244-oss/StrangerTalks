defmodule StrangertalksNew.Relationships do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Relationship
  alias StrangertalksNew.RelationshipConsent
  alias StrangertalksNew.Conversation
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

  def consent_to_relationship(conversation_id, participant_id) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         true <- participant_id in [conversation.participant_a_id, conversation.participant_b_id],
         true <- eligible_conversation?(conversation) do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.insert(
        :consent_attempt,
        RelationshipConsent.changeset(%RelationshipConsent{}, %{
          conversation_id: conversation_id,
          participant_id: participant_id,
          created_at: now
        }),
        on_conflict: :nothing,
        conflict_target: [:conversation_id, :participant_id]
      )
      |> Multi.all(
        :consents,
        from(c in RelationshipConsent, where: c.conversation_id == ^conversation_id)
      )
      |> Multi.run(:relationship, fn repo, %{consents: consents} ->
        if length(consents) == 2 do
          {participant_a_id, participant_b_id} =
            canonical_pair(conversation.participant_a_id, conversation.participant_b_id)

          attrs = %{
            created_at: now,
            updated_at: now,
            accepted_at: now,
            first_conversation_at: conversation.created_at,
            last_conversation_at: conversation.ended_at,
            last_activity_at: now,
            relationship_status: :ACTIVE,
            origin_door_type: conversation.door_type,
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

          %Relationship{}
          |> Relationship.changeset(attrs)
          |> repo.insert(on_conflict: :nothing)
          |> case do
            {:ok, _} ->
              {:ok,
               repo.one!(
                 from r in Relationship,
                   where:
                     r.participant_a_id == ^participant_a_id and
                       r.participant_b_id == ^participant_b_id
               )}

            error ->
              error
          end
        else
          {:ok, nil}
        end
      end)
      |> Multi.run(:conversation_link, fn repo, %{relationship: relationship} ->
        if relationship do
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

        {:ok, %{relationship: relationship}} ->
          Phoenix.PubSub.broadcast(
            StrangertalksNew.PubSub,
            @topic,
            {:relationship_created, relationship.relationship_id, conversation.participant_a_id,
             conversation.participant_b_id}
          )

          {:ok, %{status: "created", relationship_id: relationship.relationship_id}}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    else
      nil -> {:error, :conversation_not_found}
      false -> {:error, :not_conversation_member_or_ineligible}
    end
  end

  defp eligible_conversation?(conversation),
    do:
      conversation.conversation_status == :ENDED and conversation.conversation_completed == true and
        conversation.ending_type == :NATURAL_END

  defp canonical_pair(a, b), do: if(a < b, do: {a, b}, else: {b, a})
end
