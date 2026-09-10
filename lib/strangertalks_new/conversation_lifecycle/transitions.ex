defmodule StrangertalksNew.ConversationLifecycle.Transitions do
  @moduledoc """
  Authoritative single-node V1 lifecycle transition engine for Conversations.

  Enforces legal state transitions, rejects illegal/terminal mutations, and
  consistently applies durable timestamps and ending metadata.
  """

  import Ecto.Query, warn: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Repo

  @terminal_statuses [:ENDED, :ABANDONED, :FAILED]

  @type event ::
          :participants_connected
          | :participant_disconnected
          | :participant_reconnected
          | :participant_completed
          | :safety_terminated
          | :recovery_timeout
          | :initialization_failed
          | :abandon

  @doc """
  Applies a lifecycle event transition to a Conversation struct.
  Returns `{:ok, %Conversation{}}` on success or `{:error, {:invalid_transition, atom(), event()} | term()}` on failure.
  """
  @spec transition(Conversation.t(), event(), map()) ::
          {:ok, Conversation.t()} | {:error, {:invalid_transition, atom(), event()} | term()}
  def transition(conversation, event, attrs \\ %{})

  # PENDING -> ACTIVE
  def transition(
        %Conversation{conversation_status: :PENDING} = conv,
        :participants_connected,
        attrs
      ) do
    apply_transition(
      conv,
      :ACTIVE,
      :participants_connected,
      Map.merge(%{conversation_status: :ACTIVE}, attrs)
    )
  end

  # PENDING -> ABANDONED (timeout)
  def transition(%Conversation{conversation_status: :PENDING} = conv, :recovery_timeout, attrs) do
    now = DateTime.utc_now()

    default_attrs = %{
      conversation_status: :ABANDONED,
      ended_at: now,
      ending_type: :TIMEOUT
    }

    apply_transition(conv, :ABANDONED, :recovery_timeout, Map.merge(default_attrs, attrs))
  end

  # PENDING -> FAILED
  def transition(
        %Conversation{conversation_status: :PENDING} = conv,
        :initialization_failed,
        attrs
      ) do
    now = DateTime.utc_now()

    default_attrs = %{
      conversation_status: :FAILED,
      ended_at: now,
      ending_type: :DISCONNECT
    }

    apply_transition(conv, :FAILED, :initialization_failed, Map.merge(default_attrs, attrs))
  end

  # A participant explicitly ending a conversation before both peers connected is
  # a terminal transition failure, not a successfully completed conversation.
  def transition(
        %Conversation{conversation_status: :PENDING} = conv,
        :participant_completed,
        attrs
      ) do
    now = DateTime.utc_now()

    default_attrs = %{
      conversation_status: :FAILED,
      ended_at: now,
      ending_type: :PARTICIPANT_LEFT,
      conversation_completed: false
    }

    apply_transition(conv, :FAILED, :participant_completed, Map.merge(default_attrs, attrs))
  end

  # ACTIVE -> PAUSED
  def transition(
        %Conversation{conversation_status: :ACTIVE} = conv,
        :participant_disconnected,
        attrs
      ) do
    apply_transition(
      conv,
      :PAUSED,
      :participant_disconnected,
      Map.merge(%{conversation_status: :PAUSED}, attrs)
    )
  end

  # PAUSED -> ACTIVE
  def transition(
        %Conversation{conversation_status: :PAUSED} = conv,
        :participant_reconnected,
        attrs
      ) do
    apply_transition(
      conv,
      :ACTIVE,
      :participant_reconnected,
      Map.merge(%{conversation_status: :ACTIVE}, attrs)
    )
  end

  # ACTIVE / PAUSED -> ENDED (natural/participant completed)
  def transition(%Conversation{conversation_status: status} = conv, :participant_completed, attrs)
      when status in [:ACTIVE, :PAUSED] do
    now = DateTime.utc_now()

    default_attrs = %{
      conversation_status: :ENDED,
      ended_at: now,
      ending_type: :NATURAL_END,
      conversation_completed: true
    }

    apply_transition(conv, :ENDED, :participant_completed, Map.merge(default_attrs, attrs))
  end

  # PENDING / ACTIVE / PAUSED -> ENDED (safety terminated)
  def transition(%Conversation{conversation_status: status} = conv, :safety_terminated, attrs)
      when status in [:PENDING, :ACTIVE, :PAUSED] do
    now = DateTime.utc_now()

    default_attrs = %{
      conversation_status: :ENDED,
      ended_at: now,
      ending_type: :SAFETY_ACTION,
      safety_flagged: true
    }

    apply_transition(conv, :ENDED, :safety_terminated, Map.merge(default_attrs, attrs))
  end

  # ACTIVE / PAUSED -> ABANDONED (recovery timeout / abandon)
  def transition(%Conversation{conversation_status: status} = conv, event, attrs)
      when status in [:ACTIVE, :PAUSED] and event in [:recovery_timeout, :abandon] do
    now = DateTime.utc_now()

    default_attrs = %{
      conversation_status: :ABANDONED,
      ended_at: now,
      ending_type: :TIMEOUT
    }

    apply_transition(conv, :ABANDONED, event, Map.merge(default_attrs, attrs))
  end

  # Terminal State Rule: cannot transition out of terminal state
  def transition(%Conversation{conversation_status: status}, event, _attrs)
      when status in @terminal_statuses do
    {:error, {:invalid_transition, status, event}}
  end

  # Catch-all illegal transition
  def transition(%Conversation{conversation_status: status}, event, _attrs) do
    {:error, {:invalid_transition, status, event}}
  end

  @doc """
  Checks whether a given conversation status is terminal.
  """
  @spec terminal?(atom()) :: boolean()
  def terminal?(status) when is_atom(status), do: status in @terminal_statuses

  defp apply_transition(conv, target_status, event, attrs) do
    if terminal?(target_status) do
      StrangertalksNew.Telemetry.execute(
        [:terminal, :request_accepted],
        %{count: 1},
        %{terminal_status: target_status, lifecycle_event: event}
      )
    end

    try do
      changeset = Conversation.changeset(conv, attrs)

      if changeset.valid? do
        persist_if_canonical(conv, changeset, target_status, event)
      else
        emit_terminal_persistence_failure(target_status, event, changeset)
        {:error, changeset}
      end
    rescue
      exception ->
        emit_terminal_persistence_failure(target_status, event, exception)
        {:error, exception}
    catch
      :exit, reason ->
        emit_terminal_persistence_failure(target_status, event, reason)
        {:error, reason}
    end
  end

  defp emit_terminal_persistence_failure(target_status, event, reason) do
    if terminal?(target_status) do
      StrangertalksNew.Telemetry.failure(
        [:terminal, :persistence_failed],
        reason,
        %{terminal_status: target_status, lifecycle_event: event}
      )
    end
  end

  defp persist_if_canonical(conv, changeset, target_status, event) do
    expected_status = conv.conversation_status

    query =
      from current in Conversation,
        where:
          current.conversation_id == ^conv.conversation_id and
            current.conversation_status == ^expected_status

    result =
      if terminal?(target_status) do
        Repo.transaction(fn ->
          case persist_update(query, changeset, conv, event) do
            {:ok, updated} ->
              case release_pairing_reservations(updated) do
                :ok -> updated
                {:error, reason} -> Repo.rollback(reason)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      else
        persist_update(query, changeset, conv, event)
      end

    case result do
      {:ok, %Conversation{} = updated} ->
        emit_committed_transition(updated, expected_status, target_status, event)
        {:ok, updated}

      {:ok, {:ok, %Conversation{} = updated}} ->
        emit_committed_transition(updated, expected_status, target_status, event)
        {:ok, updated}

      {:error, reason} ->
        emit_terminal_persistence_failure(target_status, event, reason)
        {:error, reason}
    end
  end

  defp persist_update(query, changeset, conv, event) do
    case Repo.update_all(query, set: Map.to_list(changeset.changes)) do
      {1, _} ->
        {:ok, Repo.get!(Conversation, conv.conversation_id)}

      {0, _} ->
        case Repo.get(Conversation, conv.conversation_id) do
          nil ->
            {:error, :conversation_not_found}

          %Conversation{conversation_status: canonical_status} ->
            {:error, {:invalid_transition, canonical_status, event}}
        end
    end
  end

  defp release_pairing_reservations(%Conversation{match_id: match_id, ended_at: ended_at}) do
    released_at = ended_at || DateTime.utc_now()

    with {:ok, dumped_match_id} <- Ecto.UUID.dump(match_id),
         {:ok, _result} <-
           Repo.query(
             """
             UPDATE participant_pairing_reservations
             SET released_at = $2
             WHERE match_id = $1 AND released_at IS NULL
             """,
             [dumped_match_id, DateTime.to_naive(released_at)]
           ) do
      :ok
    else
      :error -> {:error, :invalid_match_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_committed_transition(updated, expected_status, target_status, event) do
    StrangertalksNew.Telemetry.execute(
      [:conversation, :transitioned],
      %{count: 1},
      %{
        from_status: expected_status,
        to_status: target_status,
        lifecycle_event: event
      }
    )

    if terminal?(target_status) and updated.ending_type != :BLOCK do
      StrangertalksNew.Telemetry.execute(
        [:terminal, :durable_commit],
        %{count: 1},
        %{terminal_status: target_status, lifecycle_event: event}
      )
    end
  end
end
