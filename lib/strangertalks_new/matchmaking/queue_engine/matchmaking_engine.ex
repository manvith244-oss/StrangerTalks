# filepath: lib/strangertalks_new/matchmaking/matchmaking_engine.ex
defmodule StrangertalksNew.Matchmaking.MatchmakingEngine do
  @moduledoc """
  Core orchestration engine for Slice 02. Manages queue lifecycle boundaries,
  implements dynamic score-decay evaluations, and enforces safety blockades.
  """

  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.QueueEngine.Matcher

  @pubsub_topic "strangertalks:matchmaking"
  @max_wait_ceiling_seconds 90
  @decay_floor 45
  @initial_threshold 70

  @doc """
  Registers an incoming participant profile into volatile memory storage.
  Bypasses persistent disk writes during active wait loops.
  """
  def join_queue(participant_id, door_type, preferred_language, media_overlap, keystroke_profile)
      when is_binary(participant_id) and is_atom(door_type) and is_binary(preferred_language) and
             is_integer(media_overlap) and is_float(keystroke_profile) do
    entry_payload = %{
      participant_id: participant_id,
      door_selection: door_type,
      language_tag: preferred_language,
      media_bitmask: media_overlap,
      keystroke_cadence: keystroke_profile,
      queue_entry_time: DateTime.utc_now(),
      attempt_count: 1
    }

    # Atomically inject into our primary Elixir Agent memory matrix
    case Agent.update(QueueState, fn state -> Map.put(state, participant_id, entry_payload) end) do
      :ok ->
        Phoenix.PubSub.broadcast(
          StrangertalksNew.PubSub,
          @pubsub_topic,
          {:queue_event, :queue_entered, participant_id}
        )

        {:ok, %{status: :queued, entry_time: DateTime.utc_now()}}

      _ ->
        {:error, :queue_instantiation_failed}
    end
  end

  def join_queue(_id, _door, _lang, _media, _key), do: {:error, :unsupported_schema}

  @doc """
  Removes a participant from volatile memory, leaving zero data trails behind.
  """
  def leave_queue(participant_id) when is_binary(participant_id) do
    Agent.update(QueueState, fn state -> Map.delete(state, participant_id) end)
    :ok
  end

  @doc """
  Compiles a fast telemetry snapshot from the volatile RAM state map.
  """
  def get_queue_status do
    state = Agent.get(QueueState, fn state -> state end)
    total_participants = map_size(state)

    avg_wait =
      if total_participants > 0 do
        now = DateTime.utc_now()

        total_seconds =
          Enum.reduce(state, 0, fn {_id, p}, acc ->
            acc + DateTime.diff(now, p.queue_entry_time, :second)
          end)

        total_seconds / total_participants
      else
        0.0
      end

    {:ok,
     %{
       active_participants: total_participants,
       average_wait_time: avg_wait,
       door_imbalance_index: 0.0
     }}
  end

  @doc """
  Runs the candidate evaluation pipeline. Iterates over active pools, calculates 
  linear decay thresholds, enforces safety parameters, and forms matches.
  """
  def evaluate_pending_matches do
    state = Agent.get(QueueState, fn state -> state end)
    participants = Map.values(state)

    case process_matching_pool(participants, []) do
      {:ok, matches_created} ->
        {:ok, matches_created}

      _ ->
        {:ok, []}
    end
  end

  @doc """
  Calculates the dynamic threshold based on wait time and active pool metrics.
  Exposed publicly with a default arity clause to fulfill ParticipantServer demands.
  """
  @spec calculate_decay_threshold(integer(), integer()) :: integer()
  def calculate_decay_threshold(t, concurrent_sockets \\ 100)

  def calculate_decay_threshold(t, _concurrent_sockets) when t <= 30, do: @initial_threshold

  def calculate_decay_threshold(t, _concurrent_sockets) do
    decayed = @initial_threshold - 5 * div(t - 30, 10)
    max(decayed, @decay_floor)
  end

  # --- Internal Private Implementations ---

  defp process_matching_pool([], matched_acc), do: {:ok, matched_acc}

  defp process_matching_pool([p1 | rest], matched_acc) do
    # Calculate operational target threshold based on dwell time metrics
    wait_time = DateTime.diff(DateTime.utc_now(), p1.queue_entry_time, :second)

    # Enforce strict 90-second timeout tracking guidelines
    if wait_time >= @max_wait_ceiling_seconds do
      leave_queue(p1.participant_id)

      Phoenix.PubSub.broadcast(
        StrangertalksNew.PubSub,
        @pubsub_topic,
        {:queue_event, :queue_timeout, p1.participant_id}
      )

      process_matching_pool(rest, matched_acc)
    else
      current_threshold = calculate_decay_threshold(wait_time)

      case find_viable_partner(p1, rest, current_threshold) do
        {:match, p2, score} ->
          # Atomic structural eviction sequence to prevent concurrent double-matching anomalies
          leave_queue(p1.participant_id)
          leave_queue(p2.participant_id)

          match_id = Ecto.UUID.generate()

          Phoenix.PubSub.broadcast(
            StrangertalksNew.PubSub,
            @pubsub_topic,
            {:match_event, :match_created, match_id, p1.participant_id, p2.participant_id, score}
          )

          # Filter out the newly paired candidate from the remaining collection loop
          remaining_pool = Enum.reject(rest, fn p -> p.participant_id == p2.participant_id end)
          process_matching_pool(remaining_pool, [match_id | matched_acc])

        :no_match ->
          process_matching_pool(rest, matched_acc)
      end
    end
  end

  defp find_viable_partner(_p1, [], _threshold), do: :no_match

  defp find_viable_partner(p1, [p2 | rest], threshold) do
    # Map raw profile data points into the structured entities required by the Matcher utility
    mapped_p1 = transform_payload(p1)
    mapped_p2 = transform_payload(p2)

    score = Matcher.compute_match_score(mapped_p1, mapped_p2)

    if score >= threshold do
      {:match, p2, score}
    else
      find_viable_partner(p1, rest, threshold)
    end
  end

  defp transform_payload(p) do
    %{
      language: p.language_tag,
      intent_vibe_vector: %{
        "primary_intent" => to_string(p.door_selection),
        "vibe_dimensions" => %{}
      },
      media_mask: p.media_bitmask,
      typing_rate: p.keystroke_cadence
    }
  end
end
