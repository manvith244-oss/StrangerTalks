defmodule StrangertalksNew.Hangouts.Matcher do
  @moduledoc """
  Single-runtime V1 waiting-queue authority for Hangouts.

  Queue attempts are intentionally transient. Durable social authority begins only when
  `StrangertalksNew.Hangouts.create_formed_room/2` commits a room and its memberships.
  Horizontal multi-node queue coordination is deliberately outside this V1 boundary.
  """

  use GenServer

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutRoom, Observability, RoomServer}
  alias StrangertalksNew.MatchingRules

  @default_config [minimum_size: 3, target_size: 4, max_size: 6]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def enqueue(participant_id, language_tag)
      when is_binary(participant_id) and is_binary(language_tag) do
    GenServer.call(__MODULE__, {:enqueue, participant_id, language_tag})
  end

  def enqueue(_participant_id, _language_tag), do: {:error, :invalid_queue_request}

  def leave_queue(participant_id) when is_binary(participant_id) do
    GenServer.call(__MODULE__, {:leave_queue, participant_id})
  end

  def leave_queue(_participant_id), do: {:error, :invalid_queue_request}

  def try_form(language_tag) when is_binary(language_tag) do
    GenServer.call(__MODULE__, {:try_form, language_tag}, :infinity)
  end

  def try_form(_language_tag), do: {:error, :invalid_language_tag}

  def prune_stale(age_ms) when is_integer(age_ms) and age_ms >= 0 do
    GenServer.call(__MODULE__, {:prune_stale, age_ms})
  end

  def prune_stale(_age_ms), do: {:error, :invalid_stale_age}

  @impl true
  def init(:ok) do
    {:ok, %{attempts: %{}, queues: %{}, next_ordinal: 0}}
  end

  @impl true
  def handle_call({:enqueue, participant_id, language_tag}, _from, state) do
    cond do
      not valid_language_tag?(language_tag) ->
        {:reply, {:error, :invalid_language_tag}, state}

      not Hangouts.participant_available?(participant_id) ->
        {:reply, {:error, :already_in_hangout}, drop_participant(state, participant_id)}

      true ->
        case Map.get(state.attempts, participant_id) do
          %{language_tag: ^language_tag} = attempt ->
            {:reply, {:ok, public_attempt(attempt)}, state}

          %{} ->
            {:reply, {:error, :already_queued}, state}

          nil ->
            attempt = %{
              queue_attempt_id: Ecto.UUID.generate(),
              participant_id: participant_id,
              language_tag: language_tag,
              enqueued_at: DateTime.utc_now(),
              enqueued_monotonic_ms: System.monotonic_time(:millisecond),
              ordinal: state.next_ordinal
            }

            next_state =
              state
              |> put_attempt(attempt)
              |> Map.update!(:next_ordinal, &(&1 + 1))

            Observability.emit(:queue_entered, %{count: 1})
            {:reply, {:ok, public_attempt(attempt)}, next_state}
        end
    end
  end

  def handle_call({:leave_queue, participant_id}, _from, state) do
    queued? = Map.has_key?(state.attempts, participant_id)
    next_state = drop_participant(state, participant_id)

    if queued? do
      Observability.emit(:queue_cancelled, %{count: 1})
    end

    {:reply, :ok, next_state}
  end

  def handle_call({:try_form, language_tag}, _from, state) do
    with :ok <- validate_language_tag(language_tag),
         {:ok, config} <- matcher_config() do
      {reply, next_state} = form_room(language_tag, state, config, 0)
      {:reply, reply, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prune_stale, age_ms}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    stale_participant_ids =
      state.attempts
      |> Map.values()
      |> Enum.filter(fn attempt ->
        now_ms - attempt.enqueued_monotonic_ms >= age_ms
      end)
      |> Enum.map(& &1.participant_id)

    next_state = Enum.reduce(stale_participant_ids, state, &drop_participant(&2, &1))
    {:reply, {:ok, length(stale_participant_ids)}, next_state}
  end

  defp form_room(language_tag, state, config, retry_count) do
    state = clean_unavailable(language_tag, state)
    participant_ids = queue_participant_ids(state, language_tag)

    if length(participant_ids) < config.minimum_size do
      {{:ok, :waiting}, state}
    else
      selected_ids = select_compatible_group(participant_ids, config)

      if selected_ids == [] do
        {{:ok, :waiting}, state}
      else
        attrs = %{
          language_tag: language_tag,
          experiment_arm: :GROUP_WITH_CONTENT,
          minimum_size: config.minimum_size,
          target_size: config.target_size,
          max_size: config.max_size
        }

        formation_latency_ms = formation_latency_ms(state, selected_ids)

        case Hangouts.create_formed_room(selected_ids, attrs) do
          {:ok, %{room: room}} ->
            committed_state = Enum.reduce(selected_ids, state, &drop_participant(&2, &1))

            case RoomServer.ensure_started(room.room_id) do
              {:ok, _pid} ->
                formed = %{
                  room_id: room.room_id,
                  participant_ids: selected_ids,
                  size: length(selected_ids)
                }

                room_measurements = %{
                  count: 1,
                  room_size: length(selected_ids),
                  formation_latency_ms: formation_latency_ms
                }

                Observability.emit_room(room.room_id, :room_formed, room_measurements)
                Observability.emit_room(room.room_id, :room_activated, %{count: 1})

                {{:ok, formed}, committed_state}

              {:error, reason} ->
                {{:error, {:room_server_start_failed, reason}}, committed_state}
            end

          {:error, :already_in_hangout} ->
            refreshed_state = clean_unavailable(language_tag, state)

            if refreshed_state != state and retry_count < length(participant_ids) do
              form_room(language_tag, refreshed_state, config, retry_count + 1)
            else
              {{:error, :formation_conflict}, state}
            end

          {:error, reason} ->
            {{:error, reason}, state}

          {:error, reason, _changeset} ->
            {{:error, reason}, state}
        end
      end
    end
  end

  defp formation_latency_ms(state, selected_ids) do
    now_ms = System.monotonic_time(:millisecond)

    selected_ids
    |> Enum.map(&Map.fetch!(state.attempts, &1).enqueued_monotonic_ms)
    |> Enum.min(fn -> now_ms end)
    |> then(&(now_ms - &1))
    |> max(0)
  end

  defp select_compatible_group(participant_ids, config) do
    desired_size = min(length(participant_ids), min(config.target_size, config.max_size))

    desired_size
    |> down_to(config.minimum_size)
    |> Enum.find_value([], fn size ->
      first_compatible_combination(participant_ids, size, [])
    end)
  end

  defp down_to(high, low) when high >= low, do: Enum.to_list(high..low//-1)
  defp down_to(_high, _low), do: []

  defp first_compatible_combination(_remaining, 0, selected), do: Enum.reverse(selected)

  defp first_compatible_combination(remaining, needed, _selected)
       when length(remaining) < needed,
       do: nil

  defp first_compatible_combination([], _needed, _selected), do: nil

  defp first_compatible_combination([candidate | rest], needed, selected) do
    selected_result =
      if safe_with_selected?(candidate, selected) do
        first_compatible_combination(rest, needed - 1, [candidate | selected])
      end

    case selected_result do
      nil -> first_compatible_combination(rest, needed, selected)
      group -> group
    end
  end

  defp safe_with_selected?(candidate, selected) do
    Enum.all?(selected, fn existing ->
      not MatchingRules.check_safety_veto?(candidate, existing)
    end)
  end

  defp clean_unavailable(language_tag, state) do
    state
    |> queue_participant_ids(language_tag)
    |> Enum.reduce(state, fn participant_id, acc ->
      if Hangouts.participant_available?(participant_id) do
        acc
      else
        drop_participant(acc, participant_id)
      end
    end)
  end

  defp queue_participant_ids(state, language_tag) do
    Map.get(state.queues, language_tag, [])
  end

  defp put_attempt(state, attempt) do
    queues =
      Map.update(
        state.queues,
        attempt.language_tag,
        [attempt.participant_id],
        fn participant_ids ->
          participant_ids ++ [attempt.participant_id]
        end
      )

    %{state | attempts: Map.put(state.attempts, attempt.participant_id, attempt), queues: queues}
  end

  defp drop_participant(state, participant_id) do
    case Map.pop(state.attempts, participant_id) do
      {nil, _attempts} ->
        state

      {%{language_tag: language_tag}, attempts} ->
        remaining =
          state.queues
          |> Map.get(language_tag, [])
          |> Enum.reject(&(&1 == participant_id))

        queues =
          if remaining == [] do
            Map.delete(state.queues, language_tag)
          else
            Map.put(state.queues, language_tag, remaining)
          end

        %{state | attempts: attempts, queues: queues}
    end
  end

  defp public_attempt(attempt) do
    %{
      status: :queued,
      queue_attempt_id: attempt.queue_attempt_id,
      enqueued_at: attempt.enqueued_at
    }
  end

  defp validate_language_tag(language_tag) do
    if valid_language_tag?(language_tag), do: :ok, else: {:error, :invalid_language_tag}
  end

  defp valid_language_tag?(language_tag) when is_binary(language_tag) do
    %HangoutRoom{}
    |> HangoutRoom.changeset(%{
      created_at: DateTime.utc_now(),
      status: :FORMING,
      language_tag: language_tag,
      experiment_arm: :GROUP_WITH_CONTENT,
      minimum_size: 3,
      target_size: 4,
      max_size: 6,
      message_sequence: 0,
      content_sequence: 0
    })
    |> Map.get(:valid?)
  end

  defp valid_language_tag?(_language_tag), do: false

  defp matcher_config do
    configured = Application.get_env(:strangertalks_new, __MODULE__, [])

    config =
      @default_config
      |> Keyword.merge(normalize_config(configured))
      |> Map.new()

    if valid_config?(config) do
      {:ok, config}
    else
      {:error, :invalid_matcher_config}
    end
  end

  defp normalize_config(config) when is_list(config), do: config
  defp normalize_config(config) when is_map(config), do: Map.to_list(config)
  defp normalize_config(_config), do: []

  defp valid_config?(config) do
    values = [config.minimum_size, config.target_size, config.max_size]

    Enum.all?(values, &(is_integer(&1) and &1 >= 2 and &1 <= 12)) and
      config.minimum_size <= config.target_size and
      config.target_size <= config.max_size
  end
end
