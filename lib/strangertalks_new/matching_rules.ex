# filepath: lib/strangertalks_new/matching_rules.ex
defmodule StrangertalksNew.MatchingRules do
  @moduledoc """
  Boundary Context managing relational records, safety verification matrices,
  and explicit telemetric storage handoffs for StrangerTalks.
  """
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Conversations
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
                     {:ok, terminal_conversation} <-
                       terminate_conversation_for_block(current_conversation, blocker_id),
                     {:ok, terminal_truth} <-
                       Conversations.terminal_truth(terminal_conversation) do
                  {block, terminal_conversation, terminal_truth}
                else
                  {:error, reason} -> Repo.rollback(reason)
                end
              end)

            case result do
              {:ok, {block, terminal_conversation, terminal_truth}} ->
                if terminal_conversation.ending_type == :BLOCK do
                  StrangertalksNew.Telemetry.execute(
                    [:terminal, :durable_commit],
                    %{count: 1},
                    %{terminal_status: :ENDED, lifecycle_event: :safety_terminated}
                  )
                end

                terminate_suspended_runtime(suspended_runtime)
                stop_conversation_runtime(conversation_id)
                emit_block_runtime_cleanup(suspended_runtime, terminal_conversation)
                broadcast_terminal_authority(conversation_id, terminal_truth.client_event)
                emit_block_notification_observability(terminal_conversation)
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

  defp emit_block_notification_observability(%Conversation{ending_type: :BLOCK}) do
    StrangertalksNew.Telemetry.execute(
      [:terminal, :client_notification],
      %{count: 1},
      %{terminal_reason: :blocked, notification_path: :block_broadcast}
    )
  end

  defp emit_block_notification_observability(%Conversation{} = conversation) do
    StrangertalksNew.Telemetry.execute(
      [:terminal, :stale_action_rejected],
      %{count: 1},
      %{
        terminal_action: :block,
        canonical_ending: bounded_ending_type(conversation.ending_type)
      }
    )

    :ok
  end

  defp emit_block_runtime_cleanup({:suspended, _pid}, %Conversation{ending_type: :BLOCK}) do
    StrangertalksNew.Telemetry.execute(
      [:terminal, :runtime_cleanup],
      %{count: 1},
      %{terminal_reason: :blocked, cleanup_path: :block_suspended_runtime}
    )
  end

  defp emit_block_runtime_cleanup(_runtime, _conversation), do: :ok

  defp bounded_ending_type(:NATURAL_END), do: :natural_end
  defp bounded_ending_type(:BLOCK), do: :block
  defp bounded_ending_type(:SAFETY_ACTION), do: :safety_action
  defp bounded_ending_type(:PARTICIPANT_LEFT), do: :participant_left
  defp bounded_ending_type(:TIMEOUT), do: :timeout
  defp bounded_ending_type(:DISCONNECT), do: :disconnect
  defp bounded_ending_type(_ending_type), do: :other_terminal

  defp broadcast_terminal_authority(conversation_id, client_event) do
    StrangertalksNewWeb.Endpoint.broadcast(
      "conversation:#{conversation_id}",
      "conversation:ended",
      client_event
    )
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
