# filepath: lib/strangertalks_new/matching_rules.ex
defmodule StrangertalksNew.MatchingRules do
  @moduledoc """
  Boundary Context managing relational records, safety verification matrices,
  and explicit telemetric storage handoffs for StrangerTalks.
  """
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.MatchingRules.{Participant, QueueState, BoundaryBlock}

  def create_participant(attrs \\ %{}) do
    %Participant{}
    |> Participant.changeset(attrs)
    |> Repo.insert()
  end

  def get_participant!(id), do: Repo.get!(Participant, id)

  def update_participant(%Participant{} = participant, attrs) do
    participant
    |> Participant.changeset(attrs)
    |> Repo.update()
  end

  def log_match_telemetry(participant_id, strategy, duration, vibe_vector) do
    %QueueState{}
    |> QueueState.changeset(%{
      participant_id: participant_id,
      matched_strategy_applied: strategy,
      wait_duration_seconds: duration,
      intent_vibe_vector: vibe_vector
    })
    |> Repo.insert()
  end

  def enforce_block(blocker_id, blocked_id, surface) do
    %BoundaryBlock{}
    |> BoundaryBlock.changeset(%{
      blocker_user_id: blocker_id,
      blocked_user_id: blocked_id,
      source_surface: surface,
      active_status: true
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def check_safety_veto?(participant_a_id, participant_b_id) do
    query =
      from b in BoundaryBlock,
        where:
          (b.blocker_user_id == ^participant_a_id and b.blocked_user_id == ^participant_b_id and
             b.active_status == true) or
            (b.blocker_user_id == ^participant_b_id and b.blocked_user_id == ^participant_a_id and
               b.active_status == true),
        select: count(b.blocker_user_id)

    Repo.one(query) > 0
  end
end
