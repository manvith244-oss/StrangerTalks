defmodule StrangertalksNew.Hangouts.DurableInteractions do
  @moduledoc false

  import Ecto.Query

  alias StrangertalksNew.Hangouts.{
    HangoutMembership,
    HangoutReaction,
    HangoutRoom,
    HangoutRoomContent,
    HangoutSkipVote,
    SharedContent
  }

  alias StrangertalksNew.Repo

  @allowed_reactions ~w(laugh fire love wow agree)

  def add_reaction(room_id, participant_id, expected_sequence, reaction)
      when is_binary(room_id) and is_binary(participant_id) and
             is_integer(expected_sequence) and expected_sequence >= 0 and is_binary(reaction) do
    if reaction in @allowed_reactions do
      Repo.transaction(fn ->
        room = lock_interaction_room!(room_id, expected_sequence)
        membership = active_membership!(room_id, participant_id)
        room_content = SharedContent.current_record_for_locked_room!(room)
        now = DateTime.utc_now()

        existing =
          Repo.get_by(HangoutReaction,
            room_content_id: room_content.room_content_id,
            membership_id: membership.membership_id
          )

        {changed?, persisted} =
          case existing do
            %HangoutReaction{reaction: ^reaction} = record ->
              {false, record}

            %HangoutReaction{} = record ->
              updated =
                record
                |> HangoutReaction.changeset(%{reaction: reaction, updated_at: now})
                |> Repo.update()
                |> unwrap!(:invalid_reaction)

              {true, updated}

            nil ->
              inserted =
                %HangoutReaction{}
                |> HangoutReaction.changeset(%{
                  room_id: room_id,
                  room_content_id: room_content.room_content_id,
                  membership_id: membership.membership_id,
                  reaction: reaction,
                  created_at: now,
                  updated_at: now
                })
                |> Repo.insert()
                |> unwrap!(:invalid_reaction)

              {true, inserted}
          end

        %{
          changed?: changed?,
          reaction: persisted.reaction,
          membership: membership,
          counts: reaction_counts(room_content.room_content_id),
          content_sequence: room_content.sequence
        }
      end)
      |> normalize_transaction()
    else
      {:error, :invalid_reaction}
    end
  end

  def add_reaction(_room_id, _participant_id, _expected_sequence, _reaction),
    do: {:error, :invalid_reaction_request}

  def cast_skip_vote(room_id, participant_id, expected_sequence, ratio)
      when is_binary(room_id) and is_binary(participant_id) and
             is_integer(expected_sequence) and expected_sequence >= 0 and is_number(ratio) and
             ratio > 0 and ratio < 1 do
    result =
      Repo.transaction(fn ->
        room = lock_interaction_room!(room_id, expected_sequence)
        membership = active_membership!(room_id, participant_id)
        room_content = SharedContent.current_record_for_locked_room!(room)

        existing? =
          Repo.exists?(
            from vote in HangoutSkipVote,
              where:
                vote.room_content_id == ^room_content.room_content_id and
                  vote.membership_id == ^membership.membership_id
          )

        unless existing? do
          %HangoutSkipVote{}
          |> HangoutSkipVote.changeset(%{
            room_id: room_id,
            room_content_id: room_content.room_content_id,
            membership_id: membership.membership_id,
            created_at: DateTime.utc_now()
          })
          |> Repo.insert()
          |> unwrap!(:invalid_skip_vote)
        end

        active_membership_ids = active_membership_ids(room_id)
        vote_count = active_vote_count(room_content.room_content_id, active_membership_ids)
        required_votes = required_skip_votes(length(active_membership_ids), ratio)

        if not existing? and vote_count >= required_votes do
          content_state = SharedContent.advance_locked(room)

          %{
            advanced: true,
            new_vote?: true,
            previous_content_sequence: room_content.sequence,
            votes: vote_count,
            required_votes: required_votes,
            content: content_state
          }
        else
          %{
            advanced: false,
            new_vote?: not existing?,
            content_sequence: room_content.sequence,
            votes: vote_count,
            required_votes: required_votes
          }
        end
      end)

    case result do
      {:ok, %{advanced: true} = value} ->
        SharedContent.emit_transition(room_id, value.content)
        {:ok, value}

      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cast_skip_vote(room_id, participant_id, expected_sequence, ratio)
      when is_binary(room_id) and is_binary(participant_id) and
             is_integer(expected_sequence) and expected_sequence >= 0 and is_number(ratio) do
    {:error, :invalid_skip_quorum_ratio}
  end

  def cast_skip_vote(_room_id, _participant_id, _expected_sequence, _ratio),
    do: {:error, :invalid_skip_request}

  def current_summary(room_id, ratio)
      when is_binary(room_id) and is_number(ratio) and ratio > 0 and ratio < 1 do
    case Repo.get(HangoutRoom, room_id) do
      nil ->
        {:error, :room_not_found}

      %HangoutRoom{experiment_arm: :GROUP_NO_CONTENT} ->
        {:ok, empty_summary(0)}

      %HangoutRoom{} = room ->
        case current_room_content(room) do
          nil ->
            {:ok, empty_summary(room.content_sequence)}

          room_content ->
            active_ids = active_membership_ids(room_id)

            {:ok,
             %{
               content_sequence: room_content.sequence,
               reaction_counts: reaction_counts(room_content.room_content_id),
               skip_votes: active_vote_count(room_content.room_content_id, active_ids),
               required_skip_votes: required_skip_votes(length(active_ids), ratio)
             }}
        end
    end
  end

  def current_summary(_room_id, _ratio), do: {:error, :invalid_interaction_summary_request}

  defp lock_interaction_room!(room_id, expected_sequence) do
    room = Repo.one(from r in HangoutRoom, where: r.room_id == ^room_id, lock: "FOR UPDATE")

    cond do
      is_nil(room) -> Repo.rollback(:room_not_found)
      room.status in [:ENDING, :ENDED] -> Repo.rollback(:terminal_room)
      room.experiment_arm == :GROUP_NO_CONTENT -> Repo.rollback(:content_disabled)
      room.status != :ACTIVE -> Repo.rollback(:room_not_active)
      room.content_sequence != expected_sequence -> Repo.rollback(:stale_content)
      true -> room
    end
  end

  defp active_membership!(room_id, participant_id) do
    case Repo.get_by(HangoutMembership, room_id: room_id, participant_id: participant_id) do
      nil -> Repo.rollback(:membership_not_found)
      %HangoutMembership{status: :ACTIVE} = membership -> membership
      %HangoutMembership{} -> Repo.rollback(:membership_not_active)
    end
  end

  defp active_membership_ids(room_id) do
    Repo.all(
      from membership in HangoutMembership,
        where: membership.room_id == ^room_id and membership.status == :ACTIVE,
        select: membership.membership_id
    )
  end

  defp active_vote_count(_room_content_id, []), do: 0

  defp active_vote_count(room_content_id, membership_ids) do
    Repo.aggregate(
      from(vote in HangoutSkipVote,
        where:
          vote.room_content_id == ^room_content_id and vote.membership_id in ^membership_ids
      ),
      :count,
      :skip_vote_id
    )
  end

  defp reaction_counts(room_content_id) do
    Repo.all(
      from reaction in HangoutReaction,
        where: reaction.room_content_id == ^room_content_id,
        group_by: reaction.reaction,
        select: {reaction.reaction, count(reaction.reaction_id)}
    )
    |> Map.new()
  end

  defp current_room_content(room) do
    Repo.one(
      from content in HangoutRoomContent,
        where: content.room_id == ^room.room_id and content.sequence == ^room.content_sequence
    )
  end

  defp required_skip_votes(active_count, ratio), do: floor(active_count * ratio) + 1

  defp empty_summary(content_sequence) do
    %{
      content_sequence: content_sequence,
      reaction_counts: %{},
      skip_votes: 0,
      required_skip_votes: 0
    }
  end

  defp unwrap!({:ok, value}, _reason), do: value
  defp unwrap!({:error, changeset}, reason), do: Repo.rollback({reason, changeset})

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {reason, changeset}}), do: {:error, reason, changeset}
  defp normalize_transaction({:error, reason}), do: {:error, reason}
end
