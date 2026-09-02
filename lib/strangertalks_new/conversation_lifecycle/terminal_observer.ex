defmodule StrangertalksNew.ConversationLifecycle.TerminalObserver do
  @moduledoc """
  Low-cardinality observability bridge for terminal Conversation events.

  The observer consumes the existing internal `conversation.ended` bus event only
  long enough to locate the runtime that is expected to terminate. Conversation
  identifiers are never copied into telemetry metadata or retained after runtime
  lookup. Terminal reasons are collapsed to a bounded allowlist.
  """

  use GenServer

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  @topic "strangertalks:matchmaking"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @topic)
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_info(
        {:conversation_event, :"conversation.ended",
         %{"payload" => %{"conversation_id" => conversation_id, "reason" => reason}}},
        state
      ) do
    terminal_reason = bounded_reason(reason)

    StrangertalksNew.Telemetry.execute(
      [:terminal, :client_notification],
      %{count: 1},
      %{terminal_reason: terminal_reason, notification_path: :conversation_bus}
    )

    case ConversationServer.lookup(conversation_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:noreply, put_in(state.monitors[ref], terminal_reason)}

      {:error, :not_started} ->
        emit_runtime_cleanup(terminal_reason, :already_stopped)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {terminal_reason, monitors} ->
        emit_runtime_cleanup(terminal_reason, :process_down)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp emit_runtime_cleanup(terminal_reason, cleanup_path) do
    StrangertalksNew.Telemetry.execute(
      [:terminal, :runtime_cleanup],
      %{count: 1},
      %{terminal_reason: terminal_reason, cleanup_path: cleanup_path}
    )
  end

  defp bounded_reason("PARTICIPANT_COMPLETED"), do: :participant_completed
  defp bounded_reason("LEFT_DURING_TRANSITION"), do: :left_during_transition
  defp bounded_reason("SAFETY_TERMINATED"), do: :safety_terminated
  defp bounded_reason("RECOVERY_TIMEOUT"), do: :recovery_timeout
  defp bounded_reason("INITIALIZATION_FAILED"), do: :initialization_failed
  defp bounded_reason(_reason), do: :other_terminal
end
