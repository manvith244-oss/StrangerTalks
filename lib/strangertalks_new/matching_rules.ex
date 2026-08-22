# filepath: lib/strangertalks_new/matching_rules.ex
defmodule StrangertalksNew.MatchingRules do
  @moduledoc """
  Boundary Context managing relational records, safety verification matrices,
  and explicit telemetric storage handoffs for StrangerTalks.
  """
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Relationship
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, Transitions}
  alias StrangertalksNew.MatchingRules.{Participant, QueueState, BoundaryBlock}

  @terminal_conversation_statuses [:ENDED, :ABANDONED, :FAILED, :COMPLETED]

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
    ParticipantActivityLock.with_participants([blocker_id, blocked_id], fn ->
      insert_block(blocker_id, blocked_id, surface)
    end)
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

    Repo.one(query) > 0 or closed_relationship?(participant_a_id, participant_b_id)
  end

  defp closed_relationship?(participant_a_id, participant_b_id) do
    from(r in Relationship,
      where:
        r.relationship_status == :CLOSED and
          ((r.participant_a_id == ^participant_a_id and
              r.participant_b_id == ^participant_b_id) or
             (r.participant_a_id == ^participant_b_id and
                r.participant_b_id == ^participant_a_id)),
      select: count(r.relationship_id)
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  def block_conversation_participant(conversation_id, blocker_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :conversation_not_found}

      conversation ->
        if blocker_id in [conversation.participant_a_id, conversation.participant_b_id] do
          blocked_id =
            if blocker_id == conversation.participant_a_id,
              do: conversation.participant_b_id,
              else: conversation.participant_a_id

          ParticipantActivityLock.with_participants([blocker_id, blocked_id], fn ->
            suspended_runtime = suspend_conversation_runtime(conversation_id)

            result =
              Repo.transaction(fn ->
                current_conversation = Repo.get!(Conversation, conversation_id)

                with {:ok, block} <- insert_block(blocker_id, blocked_id, "CONVERSATION"),
                     {:ok, _conversation} <-
                       terminate_conversation_for_block(current_conversation, blocker_id) do
                  block
                else
                  {:error, reason} -> Repo.rollback(reason)
                end
              end)

            case result do
              {:ok, block} ->
                terminate_suspended_runtime(suspended_runtime)
                stop_conversation_runtime(conversation_id)
                {:ok, block}

              {:error, reason} ->
                resume_conversation_runtime(suspended_runtime)
                {:error, reason}
            end
          end)
        else
          {:error, :not_conversation_member}
        end
    end
  end

  defp insert_block(blocker_id, blocked_id, surface) do
    %BoundaryBlock{}
    |> BoundaryBlock.changeset(%{
      blocker_user_id: blocker_id,
      blocked_user_id: blocked_id,
      source_surface: surface,
      active_status: true
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp terminate_conversation_for_block(
         %Conversation{conversation_status: status} = conversation,
         _blocker_id
       )
       when status in @terminal_conversation_statuses,
       do: {:ok, conversation}

  defp terminate_conversation_for_block(%Conversation{} = conversation, blocker_id) do
    Transitions.transition(conversation, :safety_terminated, %{
      ending_type: :BLOCK,
      ending_initiator: blocker_id,
      conversation_completed: false,
      safety_flagged: true
    })
  end

  defp suspend_conversation_runtime(conversation_id) do
    case ConversationServer.lookup(conversation_id) do
      {:ok, pid} ->
        try do
          :ok = :sys.suspend(pid)
          {:suspended, pid}
        catch
          :exit, _reason -> :not_running
        end

      {:error, :not_started} ->
        :not_running
    end
  end

  defp resume_conversation_runtime({:suspended, pid}) do
    try do
      :sys.resume(pid)
    catch
      :exit, _reason -> :ok
    end
  end

  defp resume_conversation_runtime(:not_running), do: :ok

  defp terminate_suspended_runtime({:suspended, pid}) do
    try do
      :sys.terminate(pid, :normal, 5_000)
    catch
      :exit, _reason -> :ok
    end
  end

  defp terminate_suspended_runtime(:not_running), do: :ok

  defp stop_conversation_runtime(conversation_id) do
    case ConversationServer.lookup(conversation_id) do
      {:ok, pid} ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _reason -> :ok
        end

      {:error, :not_started} ->
        :ok
    end
  end
end
