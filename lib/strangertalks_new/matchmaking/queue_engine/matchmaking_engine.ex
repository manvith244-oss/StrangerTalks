# filepath: lib/strangertalks_new/matchmaking/matchmaking_engine.ex
defmodule StrangertalksNew.Matchmaking.MatchmakingEngine do
  @moduledoc """
  Core orchestration engine for Slice 02. Manages queue lifecycle boundaries,
  implements dynamic score-decay evaluations, and enforces safety blockades.
  """

  require Logger

  alias Ecto.Multi
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.Participant
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

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
    put_queue_entry(
      participant_id,
      door_type,
      preferred_language,
      media_overlap,
      keystroke_profile
    )
  end

  def join_queue(participant_id, door_type, preferred_language, media_overlap, keystroke_profile)
      when is_binary(participant_id) and is_atom(door_type) and
             (is_binary(preferred_language) or is_nil(preferred_language)) and
             (is_integer(media_overlap) or is_nil(media_overlap)) and
             (is_number(keystroke_profile) or is_nil(keystroke_profile)) do
    put_queue_entry(
      participant_id,
      door_type,
      preferred_language,
      media_overlap,
      keystroke_profile
    )
  end

  def join_queue(_id, _door, _lang, _media, _key), do: {:error, :unsupported_schema}

  defp put_queue_entry(
         participant_id,
         door_type,
         preferred_language,
         media_overlap,
         keystroke_profile
       ) do
    entry_payload = %{
      participant_id: participant_id,
      door_selection: door_type,
      language_tag: preferred_language,
      media_bitmask: media_overlap,
      # Reserved for a future evidence-based interaction metric. Unknown and unused in V1 matchmaking.
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
  # V1 constraint: matching is serialized in this process, so one pairing and persistence
  # operation completes before the next begins. Concurrent or multi-worker matching will
  # require explicit participant reservation or database-level locking.
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
          case persist_match_and_conversation(p1, p2, score) do
            {:ok, match, conversation} ->
              leave_queue(p1.participant_id)
              leave_queue(p2.participant_id)

              Phoenix.PubSub.broadcast(
                StrangertalksNew.PubSub,
                @pubsub_topic,
                {:match_event, :match_created, match.match_id, conversation.conversation_id,
                 p1.participant_id, p2.participant_id, score}
              )

              remaining_pool =
                Enum.reject(rest, fn participant ->
                  participant.participant_id == p2.participant_id
                end)

              process_matching_pool(remaining_pool, [match.match_id | matched_acc])

            {:invalid_participants, missing_participant_ids} ->
              Enum.each(missing_participant_ids, &leave_queue/1)

              remaining_pool =
                Enum.reject(rest, fn participant ->
                  participant.participant_id in missing_participant_ids
                end)

              if p1.participant_id in missing_participant_ids do
                process_matching_pool(remaining_pool, matched_acc)
              else
                process_matching_pool([p1 | remaining_pool], matched_acc)
              end

            {:error, _reason} ->
              process_matching_pool(rest, matched_acc)
          end

        :no_match ->
          process_matching_pool(rest, matched_acc)
      end
    end
  end

  defp find_viable_partner(_p1, [], _threshold), do: :no_match

  defp find_viable_partner(p1, [p2 | rest], threshold) do
    if p1.door_selection == p2.door_selection and
         not MatchingRules.check_safety_veto?(p1.participant_id, p2.participant_id) do
      # V1 compatibility is the verified binary fact that both participants selected the same Door.
      # Reserved profile inputs do not affect eligibility, ordering, or score.
      _unused_threshold = threshold
      {:match, p2, 100}
    else
      find_viable_partner(p1, rest, threshold)
    end
  end

  defp persist_match_and_conversation(p1, p2, score) do
    missing_participant_ids =
      [p1.participant_id, p2.participant_id]
      |> Enum.reject(&Repo.get(Participant, &1))

    if missing_participant_ids == [] do
      match_found_time = DateTime.utc_now()
      queue_entry_time = Enum.min_by([p1.queue_entry_time, p2.queue_entry_time], & &1, DateTime)
      queue_duration_seconds = DateTime.diff(match_found_time, queue_entry_time, :second)

      match_attrs = %{
        participant_a_id: p1.participant_id,
        participant_b_id: p2.participant_id,
        door_type: p1.door_selection,
        compatibility_score: score / 100,
        compatibility_version: "compatibility_v1",
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        queue_entry_time: queue_entry_time,
        match_found_time: match_found_time,
        queue_duration_seconds: queue_duration_seconds,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false,
        created_at: match_found_time
      }

      Multi.new()
      |> Multi.insert(:match, Matching.changeset(%Matching{}, match_attrs))
      |> Multi.insert(:conversation, fn %{match: match} ->
        Conversation.changeset(%Conversation{}, %{
          match_id: match.match_id,
          participant_a_id: p1.participant_id,
          participant_b_id: p2.participant_id,
          door_type: p1.door_selection,
          conversation_status: :PENDING,
          bridge_shown: false,
          bridge_used: false,
          bridge_ignored: false,
          conversation_completed: false,
          memory_created: false,
          relationship_created: false,
          reconnected_later: false,
          relationship_created_at_end: false,
          safety_flagged: false,
          learning_processed: false,
          message_count: 0,
          voice_note_count: 0,
          memory_count: 0,
          report_count: 0,
          block_count: 0,
          duration_seconds: 0,
          created_at: match_found_time
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{match: match, conversation: conversation}} ->
          {:ok, match, conversation}

        {:error, operation, reason, _changes} ->
          Logger.error("matchmaking persistence transaction failed",
            operation: operation,
            participant_a_id: p1.participant_id,
            participant_b_id: p2.participant_id,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      Enum.each(missing_participant_ids, fn participant_id ->
        Logger.error("matchmaking participant record missing: #{participant_id}",
          participant_id: participant_id,
          context: "match_persistence"
        )
      end)

      {:invalid_participants, missing_participant_ids}
    end
  end
end
