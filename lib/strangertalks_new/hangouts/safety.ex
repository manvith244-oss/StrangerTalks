defmodule StrangertalksNew.Hangouts.Safety do
  @moduledoc """
  Hangout-scoped report and block authority.

  Public targeting uses temporary room identity slots. Persistent participant identifiers
  remain server-side, reports reuse `hangout_reports`, and blocks reuse canonical
  `MatchingRules` pair-boundary authority.
  """

  alias StrangertalksNew.Hangouts.{HangoutMembership, HangoutReport, HangoutRoom}
  alias StrangertalksNew.{MatchingRules, Repo}

  @category_pairs [
    {"harassment", :HARASSMENT},
    {"sexual_content", :SEXUAL_MISCONDUCT},
    {"hate", :HATE},
    {"threat", :THREATS},
    {"spam_scam", :SPAM},
    {"personal_information", :PERSONAL_INFORMATION},
    {"other", :OTHER}
  ]
  @wire_to_db Map.new(@category_pairs)

  def report_categories, do: Enum.map(@category_pairs, &elem(&1, 0))

  def submit_report(room_id, reporting_participant_id, attrs)
      when is_binary(room_id) and is_binary(reporting_participant_id) and is_map(attrs) do
    with {:ok, _room} <- active_room(room_id),
         {:ok, _reporter} <- active_membership(room_id, reporting_participant_id),
         {:ok, client_report_id} <- report_id(attrs),
         {:ok, target_slot} <- target_slot(attrs),
         {:ok, target} <- report_target_membership(room_id, target_slot),
         :ok <- reject_self(reporting_participant_id, target.participant_id, :self_report),
         {:ok, wire_category, database_category} <- report_category(attrs),
         {:ok, evidence} <- evidence(attrs) do
      deduplication_key =
        report_deduplication_key(room_id, reporting_participant_id, client_report_id)

      semantic = %{
        reporting_participant_id: reporting_participant_id,
        reported_participant_id: target.participant_id,
        database_category: database_category,
        wire_category: wire_category,
        evidence: evidence,
        target: target
      }

      persist_or_replay_report(room_id, deduplication_key, semantic)
    end
  end

  def submit_report(_room_id, _reporting_participant_id, _attrs),
    do: {:error, :invalid_report_intent}

  def block_member(room_id, blocking_participant_id, target_identity_slot)
      when is_binary(room_id) and is_binary(blocking_participant_id) and
             is_integer(target_identity_slot) and target_identity_slot >= 0 do
    with {:ok, _room} <- active_room(room_id),
         {:ok, _blocker} <- active_membership(room_id, blocking_participant_id),
         {:ok, target} <- block_target_membership(room_id, target_identity_slot),
         :ok <- reject_self(blocking_participant_id, target.participant_id, :self_block),
         {:ok, _block} <-
           MatchingRules.enforce_block(blocking_participant_id, target.participant_id, "HANGOUT") do
      {:ok, %{status: "blocked", target: public_identity(target)}}
    end
  end

  def block_member(_room_id, _blocking_participant_id, _target_identity_slot),
    do: {:error, :invalid_block_intent}

  defp persist_or_replay_report(room_id, deduplication_key, semantic) do
    case Repo.get_by(HangoutReport, deduplication_key: deduplication_key) do
      nil -> insert_report(room_id, deduplication_key, semantic)
      existing -> replay_report(existing, semantic)
    end
  end

  defp insert_report(room_id, deduplication_key, semantic) do
    now = DateTime.utc_now()

    attrs = %{
      category: semantic.database_category,
      status: :SUBMITTED,
      evidence: semantic.evidence,
      deduplication_key: deduplication_key,
      created_at: now,
      updated_at: now
    }

    result =
      %HangoutReport{}
      |> HangoutReport.changeset(
        attrs,
        room_id,
        semantic.reporting_participant_id,
        semantic.reported_participant_id
      )
      |> Repo.insert()

    case result do
      {:ok, _report} ->
        {:ok, public_report(semantic)}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :deduplication_key) do
          case Repo.get_by(HangoutReport, deduplication_key: deduplication_key) do
            nil -> {:error, :report_persistence_failed}
            existing -> replay_report(existing, semantic)
          end
        else
          {:error, :invalid_report_intent}
        end
    end
  end

  defp replay_report(existing, semantic) do
    if existing.reporting_participant_id == semantic.reporting_participant_id and
         existing.reported_participant_id == semantic.reported_participant_id and
         existing.category == semantic.database_category and
         existing.evidence == semantic.evidence do
      {:ok, public_report(semantic)}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp public_report(semantic) do
    %{
      status: "submitted",
      category: semantic.wire_category,
      target: public_identity(semantic.target)
    }
  end

  defp active_room(room_id) do
    case Repo.get(HangoutRoom, room_id) do
      nil -> {:error, :room_not_found}
      %HangoutRoom{status: :ACTIVE} = room -> {:ok, room}
      %HangoutRoom{status: status} when status in [:ENDING, :ENDED] -> {:error, :terminal_room}
      %HangoutRoom{} -> {:error, :room_not_active}
    end
  end

  defp active_membership(room_id, participant_id) do
    case Repo.get_by(HangoutMembership, room_id: room_id, participant_id: participant_id) do
      %HangoutMembership{status: :ACTIVE} = membership -> {:ok, membership}
      %HangoutMembership{} -> {:error, :membership_not_active}
      nil -> {:error, :membership_not_active}
    end
  end

  defp report_target_membership(room_id, slot) do
    case membership_by_slot(room_id, slot) do
      %HangoutMembership{} = membership -> {:ok, membership}
      nil -> {:error, :invalid_report_target}
    end
  end

  defp block_target_membership(room_id, slot) do
    case membership_by_slot(room_id, slot) do
      %HangoutMembership{} = membership -> {:ok, membership}
      nil -> {:error, :invalid_block_target}
    end
  end

  defp membership_by_slot(room_id, slot) do
    Repo.get_by(HangoutMembership, room_id: room_id, temporary_identity_slot: slot)
  end

  defp reject_self(participant_id, participant_id, reason), do: {:error, reason}
  defp reject_self(_actor_id, _target_id, _reason), do: :ok

  defp report_id(attrs) do
    case Map.get(attrs, :client_report_id) do
      id when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 256 -> {:ok, id}
      _ -> {:error, :invalid_report_intent}
    end
  end

  defp target_slot(attrs) do
    case Map.get(attrs, :target_identity_slot) do
      slot when is_integer(slot) and slot >= 0 -> {:ok, slot}
      _ -> {:error, :invalid_report_intent}
    end
  end

  defp report_category(attrs) do
    case Map.get(attrs, :category) do
      category when is_binary(category) ->
        case Map.fetch(@wire_to_db, category) do
          {:ok, database_category} -> {:ok, category, database_category}
          :error -> {:error, :invalid_report_category}
        end

      _ ->
        {:error, :invalid_report_intent}
    end
  end

  defp evidence(attrs) do
    max_bytes = HangoutReport.max_evidence_bytes()

    case Map.get(attrs, :evidence) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if byte_size(value) <= max_bytes do
          {:ok, value}
        else
          {:error, :report_evidence_too_large}
        end

      _ ->
        {:error, :invalid_report_intent}
    end
  end

  defp report_deduplication_key(room_id, participant_id, client_report_id) do
    [room_id, participant_id, client_report_id]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp public_identity(membership) do
    %{
      slot: membership.temporary_identity_slot,
      label: membership.temporary_identity_label,
      emoji: membership.temporary_identity_emoji
    }
  end
end
