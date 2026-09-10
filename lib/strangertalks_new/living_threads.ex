defmodule StrangertalksNew.LivingThreads do
  @moduledoc """
  Disposable two-person consequence pilot.

  This context intentionally implements only the precommitted founder experiment:
  one A seed, one B continuation, an 8-hour continuation deadline, a 24-hour reveal,
  and a read-only spectator control. It is not a general World or Commons engine.
  """

  import Ecto.Query

  alias StrangertalksNew.Hangouts.HangoutReport
  alias StrangertalksNew.LivingThreads.{ExperimentAssignment, LivingThread, PilotEvent}
  alias StrangertalksNew.{MatchingRules, Repo}

  @continuation_timeout_seconds 8 * 60 * 60
  @resolution_seconds 24 * 60 * 60
  @active_report_statuses [:SUBMITTED, :UNDER_REVIEW]
  @max_candidate_scan 20

  def ensure_assignment(participant_id, opts \\ [])

  def ensure_assignment(participant_id, opts) when is_binary(participant_id) do
    now = now(opts)

    case Repo.get_by(ExperimentAssignment, participant_id: participant_id) do
      %ExperimentAssignment{} = assignment ->
        {:ok, assignment}

      nil ->
        attrs = %{role: role_for(participant_id), assigned_at: now}

        %ExperimentAssignment{}
        |> ExperimentAssignment.changeset(attrs, participant_id)
        |> Repo.insert()
        |> case do
          {:ok, assignment} -> {:ok, assignment}
          {:error, changeset} -> recover_assignment_race(participant_id, changeset)
        end
    end
  end

  def ensure_assignment(_participant_id, _opts), do: {:error, :invalid_participant}

  def start_thread(participant_id, body, opts \\ [])

  def start_thread(participant_id, body, opts)
      when is_binary(participant_id) and is_binary(body) do
    now = now(opts)

    with {:ok, assignment} <- ensure_assignment(participant_id, now: now),
         :ok <- require_role(assignment, :CONSEQUENCE_A),
         {:ok, body} <- normalize_body(body),
         nil <- Repo.get_by(LivingThread, starter_participant_id: participant_id) do
      attrs = %{
        status: :WAITING_FOR_B,
        starter_body: body,
        opened_at: now,
        continuation_deadline_at: DateTime.add(now, @continuation_timeout_seconds, :second),
        resolves_at: DateTime.add(now, @resolution_seconds, :second)
      }

      Repo.transaction(fn ->
        thread =
          %LivingThread{}
          |> LivingThread.opening_changeset(attrs, participant_id)
          |> Repo.insert()
          |> unwrap_or_rollback(:invalid_thread)

        insert_event!(
          participant_id,
          thread.thread_id,
          :THREAD_CONTRIBUTED,
          %{},
          now,
          "contributed:#{participant_id}:#{thread.thread_id}:a"
        )

        insert_event!(
          participant_id,
          thread.thread_id,
          :NEW_THREAD_JOINED,
          %{role: "a"},
          now,
          "joined:#{participant_id}:#{thread.thread_id}:a"
        )

        thread
      end)
      |> normalize_transaction()
    else
      %LivingThread{} -> {:error, :thread_already_exists}
      {:error, _reason} = error -> error
    end
  end

  def start_thread(_participant_id, _body, _opts), do: {:error, :invalid_thread_input}

  def continue_next(participant_id, body, opts \\ [])

  def continue_next(participant_id, body, opts)
      when is_binary(participant_id) and is_binary(body) do
    now = now(opts)

    with {:ok, assignment} <- ensure_assignment(participant_id, now: now),
         :ok <- require_role(assignment, :CARRIER_B),
         {:ok, body} <- normalize_body(body),
         nil <- Repo.get_by(LivingThread, carrier_participant_id: participant_id) do
      materialize_deadlines(now)

      Repo.transaction(fn ->
        if Repo.exists?(
             from t in LivingThread,
               where: t.carrier_participant_id == ^participant_id
           ) do
          Repo.rollback(:carrier_already_used)
        end

        candidates =
          Repo.all(
            from t in LivingThread,
              where:
                t.status == :WAITING_FOR_B and
                  t.continuation_deadline_at > ^now and
                  t.starter_participant_id != ^participant_id,
              order_by: [asc: t.opened_at, asc: t.thread_id],
              limit: ^@max_candidate_scan,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        case Enum.find(candidates, &eligible_pair?(&1.starter_participant_id, participant_id)) do
          nil ->
            Repo.rollback(:no_waiting_thread)

          thread ->
            remaining = max(DateTime.diff(thread.resolves_at, now, :second), 0)

            updated =
              thread
              |> LivingThread.continuation_changeset(
                %{
                  status: :CONTINUED,
                  continuation_body: body,
                  continued_at: now,
                  time_remaining_at_continuation_seconds: remaining
                },
                participant_id
              )
              |> Repo.update()
              |> unwrap_or_rollback(:invalid_continuation)

            insert_event!(
              participant_id,
              thread.thread_id,
              :THREAD_CONTRIBUTED,
              %{"time_remaining_at_continuation_seconds" => remaining},
              now,
              "contributed:#{participant_id}:#{thread.thread_id}:b"
            )

            insert_event!(
              participant_id,
              thread.thread_id,
              :NEW_THREAD_JOINED,
              %{role: "b"},
              now,
              "joined:#{participant_id}:#{thread.thread_id}:b"
            )

            updated
        end
      end)
      |> normalize_transaction()
    else
      %LivingThread{} -> {:error, :carrier_already_used}
      {:error, _reason} = error -> error
    end
  end

  def continue_next(_participant_id, _body, _opts), do: {:error, :invalid_continuation_input}

  def experience_for(participant_id, opts \\ [])

  def experience_for(participant_id, opts) when is_binary(participant_id) do
    now = now(opts)
    materialize_deadlines(now)

    with {:ok, assignment} <- ensure_assignment(participant_id, now: now) do
      case assignment.role do
        :CONSEQUENCE_A -> consequence_experience(assignment, now)
        :SPECTATOR_A -> spectator_experience(assignment, now)
        :CARRIER_B -> carrier_experience(assignment, now)
      end
    end
  end

  def experience_for(_participant_id, _opts), do: {:error, :invalid_participant}

  def record_known_person_debrief(participant_id, answer, reason \\ nil, opts \\ [])

  def record_known_person_debrief(participant_id, answer, reason, opts)
      when is_binary(participant_id) and answer in ["no", "maybe", "yes"] do
    now = now(opts)
    materialize_deadlines(now)

    with {:ok, assignment} <- ensure_assignment(participant_id, now: now),
         :ok <- require_a_role(assignment),
         {:ok, thread} <- assigned_a_thread(assignment),
         %LivingThread{status: :RESOLVED} = resolved <- Repo.get!(LivingThread, thread.thread_id),
         {:ok, reason} <- normalize_reason(reason) do
      metadata = %{"answer" => answer, "reason" => reason}

      insert_event(
        participant_id,
        resolved.thread_id,
        :KNOWN_PERSON_DEBRIEF,
        metadata,
        now,
        "debrief:#{participant_id}:#{resolved.thread_id}"
      )

      {:ok, :recorded}
    else
      %LivingThread{} -> {:error, :thread_not_resolved}
      {:error, _reason} = error -> error
    end
  end

  def record_known_person_debrief(_participant_id, _answer, _reason, _opts),
    do: {:error, :invalid_debrief}

  def materialize_deadlines(%DateTime{} = now) do
    Repo.update_all(
      from(t in LivingThread,
        where: t.status == :WAITING_FOR_B and t.continuation_deadline_at <= ^now
      ),
      set: [status: :LIQUIDITY_FAILURE]
    )

    Repo.update_all(
      from(t in LivingThread,
        where: t.status == :CONTINUED and t.resolves_at <= ^now
      ),
      set: [status: :RESOLVED, resolved_at: now]
    )

    :ok
  end

  defp consequence_experience(
         %ExperimentAssignment{participant_id: participant_id} = assignment,
         now
       ) do
    case Repo.get_by(LivingThread, starter_participant_id: participant_id) do
      nil ->
        {:ok, %{role: assignment.role, state: :NEEDS_CONTRIBUTION}}

      thread ->
        expose_thread(thread, assignment.role, participant_id, now)
    end
  end

  defp spectator_experience(%ExperimentAssignment{} = assignment, now) do
    case spectator_thread(assignment, now) do
      {:ok, thread, current_assignment} ->
        expose_thread(thread, current_assignment.role, current_assignment.participant_id, now)

      {:error, :no_observable_thread} ->
        {:ok, %{role: assignment.role, state: :WAITING_FOR_THREAD}}
    end
  end

  defp carrier_experience(%ExperimentAssignment{participant_id: participant_id, role: role}, now) do
    case Repo.get_by(LivingThread, carrier_participant_id: participant_id) do
      %LivingThread{} = thread ->
        {:ok,
         %{
           role: role,
           state: :CARRIED,
           thread_id: thread.thread_id,
           seed: thread.starter_body
         }}

      nil ->
        materialize_deadlines(now)

        candidate =
          Repo.all(
            from t in LivingThread,
              where:
                t.status == :WAITING_FOR_B and
                  t.continuation_deadline_at > ^now and
                  t.starter_participant_id != ^participant_id,
              order_by: [asc: t.opened_at, asc: t.thread_id],
              limit: ^@max_candidate_scan
          )
          |> Enum.find(&eligible_pair?(&1.starter_participant_id, participant_id))

        case candidate do
          nil ->
            {:ok, %{role: role, state: :WAITING_FOR_THREAD}}

          thread ->
            log_seen_or_reopened(participant_id, thread.thread_id, now)

            {:ok,
             %{
               role: role,
               state: :CAN_CONTINUE,
               thread_id: thread.thread_id,
               seed: thread.starter_body
             }}
        end
    end
  end

  defp spectator_thread(%ExperimentAssignment{observed_thread_id: thread_id} = assignment, _now)
       when is_binary(thread_id) do
    case Repo.get(LivingThread, thread_id) do
      %LivingThread{} = thread -> {:ok, thread, assignment}
      nil -> {:error, :no_observable_thread}
    end
  end

  defp spectator_thread(%ExperimentAssignment{} = assignment, now) do
    Repo.transaction(fn ->
      locked_assignment =
        Repo.one!(
          from a in ExperimentAssignment,
            where: a.assignment_id == ^assignment.assignment_id,
            lock: "FOR UPDATE"
        )

      if is_binary(locked_assignment.observed_thread_id) do
        {Repo.get!(LivingThread, locked_assignment.observed_thread_id), locked_assignment}
      else
        observed_ids =
          Repo.all(
            from a in ExperimentAssignment,
              where: not is_nil(a.observed_thread_id),
              select: a.observed_thread_id
          )

        candidates =
          Repo.all(
            from t in LivingThread,
              where:
                t.starter_participant_id != ^assignment.participant_id and
                  t.status in [:WAITING_FOR_B, :CONTINUED] and
                  t.resolves_at > ^now and
                  t.thread_id not in ^observed_ids,
              order_by: [asc: t.opened_at, asc: t.thread_id],
              limit: ^@max_candidate_scan,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        case Enum.find(
               candidates,
               &eligible_pair?(&1.starter_participant_id, assignment.participant_id)
             ) do
          nil ->
            Repo.rollback(:no_observable_thread)

          thread ->
            updated_assignment =
              locked_assignment
              |> ExperimentAssignment.changeset(
                %{
                  role: locked_assignment.role,
                  assigned_at: locked_assignment.assigned_at,
                  observed_thread_id: thread.thread_id
                },
                locked_assignment.participant_id
              )
              |> Repo.update()
              |> unwrap_or_rollback(:spectator_assignment_failed)

            {thread, updated_assignment}
        end
      end
    end)
    |> case do
      {:ok, {thread, current_assignment}} -> {:ok, thread, current_assignment}
      {:error, :no_observable_thread} -> {:error, :no_observable_thread}
      {:error, _reason} -> {:error, :no_observable_thread}
    end
  end

  defp expose_thread(thread, role, participant_id, now) do
    thread = Repo.get!(LivingThread, thread.thread_id)
    log_seen_or_reopened(participant_id, thread.thread_id, now)

    if thread.status == :RESOLVED do
      log_once(
        participant_id,
        thread.thread_id,
        :THREAD_RESOLVED,
        %{},
        now,
        "resolved:#{participant_id}:#{thread.thread_id}"
      )
    end

    base = %{
      role: role,
      state: thread.status,
      status: thread.status,
      thread_id: thread.thread_id,
      seed: thread.starter_body,
      opened_at: thread.opened_at,
      continuation_deadline_at: thread.continuation_deadline_at,
      resolves_at: thread.resolves_at
    }

    base =
      if role == :CONSEQUENCE_A do
        Map.put(base, :your_contribution, thread.starter_body)
      else
        base
      end

    if thread.status == :RESOLVED and is_binary(thread.continuation_body) do
      Map.put(base, :continuation, thread.continuation_body)
    else
      base
    end
    |> then(&{:ok, &1})
  end

  defp assigned_a_thread(%ExperimentAssignment{
         role: :CONSEQUENCE_A,
         participant_id: participant_id
       }) do
    case Repo.get_by(LivingThread, starter_participant_id: participant_id) do
      %LivingThread{} = thread -> {:ok, thread}
      nil -> {:error, :thread_not_found}
    end
  end

  defp assigned_a_thread(%ExperimentAssignment{role: :SPECTATOR_A, observed_thread_id: thread_id})
       when is_binary(thread_id) do
    case Repo.get(LivingThread, thread_id) do
      %LivingThread{} = thread -> {:ok, thread}
      nil -> {:error, :thread_not_found}
    end
  end

  defp assigned_a_thread(%ExperimentAssignment{role: :SPECTATOR_A}),
    do: {:error, :thread_not_found}

  defp assigned_a_thread(_assignment), do: {:error, :wrong_role}

  defp log_seen_or_reopened(participant_id, thread_id, now) do
    seen_key = "seen:#{participant_id}:#{thread_id}"

    if Repo.exists?(from e in PilotEvent, where: e.deduplication_key == ^seen_key) do
      log_once(
        participant_id,
        thread_id,
        :THREAD_REOPENED,
        %{},
        now,
        "reopened:#{participant_id}:#{thread_id}"
      )
    else
      log_once(participant_id, thread_id, :THREAD_SEEN, %{}, now, seen_key)
    end
  end

  defp insert_event(participant_id, thread_id, event_type, metadata, occurred_at, dedupe_key) do
    %PilotEvent{}
    |> PilotEvent.changeset(
      %{
        event_type: event_type,
        metadata: metadata,
        deduplication_key: dedupe_key,
        occurred_at: occurred_at
      },
      participant_id,
      thread_id
    )
    |> Repo.insert(on_conflict: :nothing)
  end

  defp insert_event!(participant_id, thread_id, event_type, metadata, occurred_at, dedupe_key) do
    case insert_event(participant_id, thread_id, event_type, metadata, occurred_at, dedupe_key) do
      {:ok, event} -> event
      {:error, changeset} -> Repo.rollback({:invalid_pilot_event, changeset})
    end
  end

  defp log_once(participant_id, thread_id, event_type, metadata, occurred_at, dedupe_key) do
    case insert_event(participant_id, thread_id, event_type, metadata, occurred_at, dedupe_key) do
      {:ok, _event} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  defp eligible_pair?(participant_a_id, participant_b_id) do
    participant_a_id != participant_b_id and
      not MatchingRules.check_safety_veto?(participant_a_id, participant_b_id) and
      not active_report_between?(participant_a_id, participant_b_id)
  end

  defp active_report_between?(participant_a_id, participant_b_id) do
    Repo.exists?(
      from r in HangoutReport,
        where:
          r.status in ^@active_report_statuses and
            ((r.reporting_participant_id == ^participant_a_id and
                r.reported_participant_id == ^participant_b_id) or
               (r.reporting_participant_id == ^participant_b_id and
                  r.reported_participant_id == ^participant_a_id))
    )
  end

  defp require_role(%ExperimentAssignment{role: role}, role), do: :ok
  defp require_role(_assignment, _role), do: {:error, :wrong_role}

  defp require_a_role(%ExperimentAssignment{role: role})
       when role in [:CONSEQUENCE_A, :SPECTATOR_A],
       do: :ok

  defp require_a_role(_assignment), do: {:error, :wrong_role}

  defp normalize_body(body) do
    body = String.trim(body)

    cond do
      body == "" -> {:error, :invalid_body}
      not String.valid?(body) -> {:error, :invalid_body}
      byte_size(body) > 1000 -> {:error, :invalid_body}
      true -> {:ok, body}
    end
  end

  defp normalize_reason(nil), do: {:ok, nil}

  defp normalize_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)

    if String.valid?(reason) and byte_size(reason) <= 1000,
      do: {:ok, reason},
      else: {:error, :invalid_debrief}
  end

  defp normalize_reason(_reason), do: {:error, :invalid_debrief}

  defp role_for(participant_id) do
    case :erlang.phash2(participant_id, 4) do
      0 -> :CONSEQUENCE_A
      1 -> :SPECTATOR_A
      _ -> :CARRIER_B
    end
  end

  defp recover_assignment_race(participant_id, changeset) do
    case Repo.get_by(ExperimentAssignment, participant_id: participant_id) do
      %ExperimentAssignment{} = assignment -> {:ok, assignment}
      nil -> {:error, {:invalid_assignment, changeset}}
    end
  end

  defp unwrap_or_rollback({:ok, value}, _reason), do: value
  defp unwrap_or_rollback({:error, changeset}, reason), do: Repo.rollback({reason, changeset})

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {reason, _changeset}}), do: {:error, reason}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
end
