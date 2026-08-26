defmodule StrangertalksNew.ConversationLifecycle.Transitions do
  @moduledoc """
  Authoritative single-node V1 lifecycle transition engine for Conversations.

  Enforces legal state transitions, rejects illegal/terminal mutations, and
  consistently applies durable timestamps and ending metadata.
  """

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Repo

  @terminal_statuses [:ENDED, :ABANDONED, :FAILED, :COMPLETED]

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
      case conv
           |> Conversation.changeset(attrs)
           |> Repo.update() do
        {:ok, updated} ->
          StrangertalksNew.Telemetry.execute(
            [:conversation, :transitioned],
            %{count: 1},
            %{
              from_status: conv.conversation_status,
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

          {:ok, updated}

        {:error, reason} ->
          emit_terminal_persistence_failure(target_status, event, reason)
          {:error, reason}
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
end
