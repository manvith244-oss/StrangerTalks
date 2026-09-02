# filepath: lib/strangertalks_new/matchmaking/matchmaking_engine.ex
defmodule StrangertalksNew.Matchmaking.MatchmakingEngine do
  @moduledoc """
  Core orchestration engine for Slice 02. Manages queue lifecycle boundaries,
  implements deterministic Door eligibility and enforces safety blockades.
  """

  require Logger
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLanguages
  alias StrangertalksNew.Matching
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.Participant
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  @pubsub_topic "strangertalks:matchmaking"
  @scarcity_wait_ms 15_000
  @valid_doors MapSet.new([:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL])
  @approved_cross_door_pairs MapSet.new([
                               MapSet.new([:JUST_TALK, :EXPLORE]),
                               MapSet.new([:JUST_TALK, :KEEP_IT_LIGHT]),
                               MapSet.new([:KEEP_IT_LIGHT, :EXPLORE]),
                               MapSet.new([:EXPLORE, :SOMETHING_REAL])
                             ])

  @doc """
  Registers an incoming participant profile into volatile memory storage.
  Bypasses persistent disk writes during active wait loops.
  """
  def join_queue(
        participant_id,
        door_type,
        conversation_language,
        media_overlap,
        keystroke_profile
      )
      when is_binary(participant_id) and is_atom(door_type) and
             (is_binary(conversation_language) or is_nil(conversation_language)) and
             (is_integer(media_overlap) or is_nil(media_overlap)) and
             (is_number(keystroke_profile) or is_nil(keystroke_profile)) do
    with :ok <- validate_door(door_type),
         {:ok, normalized_language} <- ConversationLanguages.normalize(conversation_language) do
      put_queue_entry(
        participant_id,
        door_type,
        normalized_language,
        media_overlap,
        keystroke_profile,
        nil
      )
    end
  end

  def join_queue(_id, _door, _lang, _media, _key), do: {:error, :unsupported_schema}

  def requeue_transition_survivor(
        participant_id,
        door_type,
        conversation_language,
        conversation_id
      )
      when is_binary(participant_id) and is_atom(door_type) and is_binary(conversation_id) do
    with :ok <- validate_door(door_type),
         {:ok, normalized_language} <-
           ConversationLanguages.normalize(conversation_language) do
      put_queue_entry(participant_id, door_type, normalized_language, nil, nil, conversation_id)
    end
  end

  def cancel_transition_survivor(participant_id, conversation_id)
      when is_binary(participant_id) and is_binary(conversation_id) do
    ParticipantActivityLock.with_participants([participant_id], fn ->
      Agent.get_and_update(QueueState, fn state ->
        case Map.get(state, participant_id) do
          %{recovery_conversation_id: ^conversation_id} ->
            {:removed, Map.delete(state, participant_id)}

          _other ->
            {:stale, state}
        end
      end)
    end)
  end

  defp put_queue_entry(
         participant_id,
         door_type,
         conversation_language,
         media_overlap,
         keystroke_profile,
         recovery_conversation_id
       ) do
    entry_payload = %{
      participant_id: participant_id,
      door_selection: door_type,
      conversation_language: conversation_language,
      media_bitmask: media_overlap,
      # Reserved for a future evidence-based interaction metric. Unknown and unused in V1 matchmaking.
      keystroke_cadence: keystroke_profile,
      queue_entry_time: DateTime.utc_now(),
      queue_entry_monotonic: System.monotonic_time(),
      queue_attempt_id: Ecto.UUID.generate(),
      attempt_count: 1
    }

    entry_payload =
      if recovery_conversation_id,
        do: Map.put(entry_payload, :recovery_conversation_id, recovery_conversation_id),
        else: entry_payload

    result =
      ParticipantActivityLock.with_participants([participant_id], fn ->
        case resolve_active_conversation(participant_id) do
          :available ->
            Agent.get_and_update(QueueState, fn state ->
              case Map.get(state, participant_id) do
                nil ->
                  {{:inserted, entry_payload}, Map.put(state, participant_id, entry_payload)}

                %{
                  door_selection: ^door_type,
                  conversation_language: ^conversation_language
                } = existing_entry ->
                  {{:same_entry, existing_entry}, state}

                _entry ->
                  {{:error, :already_queued_different_door}, state}
              end
            end)

          {:busy, _active_conv} ->
            {:error, :participant_busy}
        end
      end)

    case result do
      {:inserted, inserted_entry} ->
        Phoenix.PubSub.broadcast(
          StrangertalksNew.PubSub,
          @pubsub_topic,
          {:queue_event, :queue_entered, participant_id}
        )

        StrangertalksNew.Telemetry.execute([:queue, :joined], %{count: 1}, %{door_type: door_type})

        {:ok,
         %{
           status: :queued,
           entry_time: inserted_entry.queue_entry_time,
           queue_attempt_id: inserted_entry.queue_attempt_id
         }}

      {:same_entry, existing_entry} ->
        {:ok,
         %{
           status: :queued,
           entry_time: existing_entry.queue_entry_time,
           queue_attempt_id: existing_entry.queue_attempt_id
         }}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :queue_instantiation_failed}
    end
  end

  @doc """
  Removes a participant from volatile memory, leaving zero data trails behind.
  """
  def leave_queue(participant_id, reason \\ :explicit_leave)
      when is_binary(participant_id) and reason in [:explicit_leave, :timeout] do
    leave_queue(participant_id, reason, :any_attempt)
  end

  defp leave_queue(participant_id, reason, expected_attempt_id) do
    removal_result =
      ParticipantActivityLock.with_participants([participant_id], fn ->
        Agent.get_and_update(QueueState, fn state ->
          case Map.pop(state, participant_id) do
            {nil, state} ->
              {:not_queued, state}

            {%{queue_attempt_id: attempt_id} = entry, new_state}
            when expected_attempt_id in [:any_attempt, attempt_id] ->
              {{:removed, entry}, new_state}

            {_entry, _new_state} ->
              {:stale_attempt, state}
          end
        end)
      end)

    case removal_result do
      {:removed, removed_entry} ->
        emit_queue_residence_duration(removed_entry, reason)

        StrangertalksNew.Telemetry.execute(
          [:queue, :left],
          %{count: 1},
          %{leave_reason: reason, door_type: removed_entry.door_selection}
        )

        :ok

      :not_queued ->
        :ok

      :stale_attempt ->
        {:error, :stale_attempt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancels queue authority without reporting success after a committed conversation wins.
  """
  def cancel_queue(participant_id, queue_attempt_id)
      when is_binary(participant_id) and is_binary(queue_attempt_id) do
    ParticipantActivityLock.with_participants([participant_id], fn ->
      case Agent.get_and_update(QueueState, fn state ->
             case Map.pop(state, participant_id) do
               {nil, state} ->
                 {:not_queued, state}

               {%{queue_attempt_id: ^queue_attempt_id} = entry, new_state} ->
                 {{:removed, entry}, new_state}

               {_current_entry, _new_state} ->
                 {:stale_attempt, state}
             end
           end) do
        {:removed, removed_entry} ->
          emit_queue_residence_duration(removed_entry, :explicit_leave)

          StrangertalksNew.Telemetry.execute(
            [:queue, :left],
            %{count: 1},
            %{leave_reason: :explicit_leave, door_type: removed_entry.door_selection}
          )

          Phoenix.PubSub.broadcast(
            StrangertalksNew.PubSub,
            @pubsub_topic,
            {:queue_event, :queue_left, participant_id, queue_attempt_id}
          )

          :ok

        :not_queued ->
          case resolve_active_conversation(participant_id) do
            {:busy, _conversation} ->
              {:error, :participant_busy}

            :available ->
              Phoenix.PubSub.broadcast(
                StrangertalksNew.PubSub,
                @pubsub_topic,
                {:queue_event, :queue_left, participant_id, queue_attempt_id}
              )

              :ok
          end

        :stale_attempt ->
          {:error, :stale_attempt}
      end
    end)
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
  # V1 callers may evaluate concurrently. Every durable admission revalidates the current
  # queue attempts, safety state and conversation activity under the same participant locks.
  def evaluate_pending_matches do
    state = Agent.get(QueueState, fn state -> state end)

    participants =
      state
      |> Map.values()
      |> Enum.sort_by(fn participant ->
        {
          DateTime.to_unix(participant.queue_entry_time, :microsecond),
          participant.participant_id
        }
      end)

    case process_matching_pool(participants, []) do
      {:ok, matches_created} ->
        {:ok, matches_created}

      _ ->
        {:ok, []}
    end
  end

  # --- Internal Private Implementations ---

  defp process_matching_pool([], matched_acc), do: {:ok, matched_acc}

  defp process_matching_pool([p1 | rest], matched_acc) do
    case find_viable_partner(p1, rest, DateTime.utc_now()) do
      {:match, p2, score} ->
        case persist_match_and_conversation(p1, p2, score) do
          {:ok, match, conversation} ->
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

  defp find_viable_partner(_p1, [], _now), do: :no_match

  defp find_viable_partner(p1, candidates, now) do
    exact_partner =
      Enum.find(candidates, fn p2 ->
        language_compatible?(p1, p2) and p1.door_selection == p2.door_selection and
          safe_pair?(p1, p2)
      end)

    cross_partner =
      if is_nil(exact_partner) and scarcity_qualified?(p1, now) do
        Enum.find(candidates, fn p2 ->
          language_compatible?(p1, p2) and scarcity_qualified?(p2, now) and
            approved_cross_door?(p1, p2) and safe_pair?(p1, p2)
        end)
      end

    case exact_partner || cross_partner do
      nil -> :no_match
      partner -> {:match, partner, 100}
    end
  end

  defp scarcity_qualified?(participant, now),
    do: DateTime.diff(now, participant.queue_entry_time, :millisecond) >= @scarcity_wait_ms

  defp approved_cross_door?(p1, p2),
    do:
      MapSet.member?(
        @approved_cross_door_pairs,
        MapSet.new([p1.door_selection, p2.door_selection])
      )

  defp safe_pair?(p1, p2),
    do: not MatchingRules.check_safety_veto?(p1.participant_id, p2.participant_id)

  defp language_compatible?(p1, p2) do
    language = Map.get(p1, :conversation_language)
    is_binary(language) and language == Map.get(p2, :conversation_language)
  end

  defp persist_match_and_conversation(p1, p2, score) do
    started_at = System.monotonic_time()

    result =
      ParticipantActivityLock.with_participants([p1.participant_id, p2.participant_id], fn ->
        persist_locked_match_and_conversation(p1, p2, score)
      end)

    StrangertalksNew.Telemetry.execute(
      [:match, :operation],
      %{duration: System.monotonic_time() - started_at},
      %{
        result: if(match?({:ok, _match, _conversation}, result), do: :success, else: :failure),
        match_kind: :anonymous
      }
    )

    result
  end

  defp persist_locked_match_and_conversation(p1, p2, score) do
    queue_state = Agent.get(QueueState, & &1)
    activity_a = resolve_active_conversation(p1.participant_id)
    activity_b = resolve_active_conversation(p2.participant_id)

    with %{door_selection: door_a, conversation_language: language_a, queue_attempt_id: attempt_a} <-
           Map.get(queue_state, p1.participant_id),
         ^door_a <- p1.door_selection,
         ^language_a <- p1.conversation_language,
         ^attempt_a <- p1.queue_attempt_id,
         %{door_selection: door_b, conversation_language: language_b, queue_attempt_id: attempt_b} <-
           Map.get(queue_state, p2.participant_id),
         ^door_b <- p2.door_selection,
         ^language_b <- p2.conversation_language,
         ^attempt_b <- p2.queue_attempt_id,
         ^language_a <- language_b,
         false <- MatchingRules.check_safety_veto?(p1.participant_id, p2.participant_id),
         :available <- activity_a,
         :available <- activity_b do
      persist_revalidated_queue_match(p1, p2, score)
    else
      _ -> {:error, :participant_activity_changed}
    end
  end

  defp persist_revalidated_queue_match(p1, p2, score) do
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
        participant_a_door_type: p1.door_selection,
        participant_b_door_type: p2.door_selection,
        conversation_language: p1.conversation_language,
        door_type: common_door(p1, p2),
        compatibility_score: score / 100,
        compatibility_version: "compatibility_v1",
        match_status: :CREATED,
        match_strategy: match_strategy(p1, p2),
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
      |> Multi.run(:pairing_reservations, fn repo, %{match: match} ->
        acquire_pairing_reservations(
          repo,
          match.match_id,
          [p1.participant_id, p2.participant_id],
          match_found_time
        )
      end)
      |> Multi.insert(:conversation, fn %{match: match} ->
        Conversation.changeset(%Conversation{}, %{
          match_id: match.match_id,
          participant_a_id: p1.participant_id,
          participant_b_id: p2.participant_id,
          door_type: common_door(p1, p2),
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
          Agent.update(QueueState, fn state ->
            state
            |> Map.delete(p1.participant_id)
            |> Map.delete(p2.participant_id)
          end)

          emit_queue_residence_duration(p1, :matched)
          emit_queue_residence_duration(p2, :matched)

          StrangertalksNew.Telemetry.execute(
            [:match, :created],
            %{count: 1},
            %{door_type: match.door_type}
          )

          StrangertalksNew.Telemetry.execute(
            [:conversation, :created],
            %{count: 1},
            %{conversation_status: :PENDING, door_type: match.door_type}
          )

          StrangertalksNew.Telemetry.execute(
            [:queue, :left],
            %{count: 2},
            %{leave_reason: :matched, door_type: match.door_type}
          )

          {:ok, match, conversation}

        {:error, operation, reason, _changes} ->
          Logger.error("matchmaking persistence transaction failed",
            operation: operation,
            reason_code: StrangertalksNew.DomainError.from_error(reason).code
          )

          {:error, reason}
      end
    else
      Logger.error("matchmaking participant record missing",
        operation: :match_persistence,
        missing_participant_count: length(missing_participant_ids)
      )

      {:invalid_participants, missing_participant_ids}
    end
  end

  defp acquire_pairing_reservations(repo, match_id, participant_ids, acquired_at) do
    ordered_participant_ids = participant_ids |> Enum.map(&canonical_uuid!/1) |> Enum.sort()

    case Enum.reduce_while(ordered_participant_ids, :ok, fn participant_id, :ok ->
           case repo.query(
                  "INSERT INTO participant_pairing_reservations (match_id, participant_id, acquired_at) VALUES ($1, $2, $3)",
                  [
                    dump_uuid!(match_id),
                    dump_uuid!(participant_id),
                    DateTime.to_naive(acquired_at)
                  ]
                ) do
             {:ok, _result} -> {:cont, :ok}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      :ok -> {:ok, ordered_participant_ids}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_uuid!(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, canonical_uuid} -> canonical_uuid
      :error -> raise ArgumentError, "invalid participant UUID"
    end
  end

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped_uuid} -> dumped_uuid
      :error -> raise ArgumentError, "invalid UUID"
    end
  end

  defp validate_door(door_type) do
    if MapSet.member?(@valid_doors, door_type), do: :ok, else: {:error, :invalid_door}
  end

  defp common_door(p1, p2) do
    if p1.door_selection == p2.door_selection, do: p1.door_selection, else: nil
  end

  defp match_strategy(p1, p2) do
    if p1.door_selection == p2.door_selection, do: :COMPATIBILITY, else: :SCARCITY
  end

  defp resolve_active_conversation(participant_id) do
    case StrangertalksNew.SessionReconciliation.reconcile(participant_id) do
      {:ok, %{canonical_state: :CONVERSATION, conversation: conv}} -> {:busy, conv}
      {:ok, _snapshot} -> :available
      {:error, reason} -> {:busy, {:reconciliation_error, reason}}
    end
  end

  defp emit_queue_residence_duration(entry, leave_reason) do
    case entry do
      %{queue_entry_monotonic: started_at, door_selection: door_type}
      when is_integer(started_at) ->
        StrangertalksNew.Telemetry.execute(
          [:queue, :residence],
          %{duration: System.monotonic_time() - started_at},
          %{leave_reason: leave_reason, door_type: door_type}
        )

      _entry ->
        :ok
    end
  end
end
