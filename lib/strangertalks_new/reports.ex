defmodule StrangertalksNew.Reports do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Report
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.SafetyReview
  alias StrangertalksNew.ReportSafetyMedia
  alias Ecto.Multi

  @categories %{
    "SPAM" => :SPAM,
    "HARASSMENT" => :HARASSMENT,
    "SEXUAL_MISCONDUCT" => :SEXUAL_MISCONDUCT,
    "MALICIOUS_LINKS" => :MALICIOUS_LINKS,
    "THREATS" => :THREATS
  }
  @max_evidence_bytes 4_096
  @default_safety_media_aggregate_limit 52_428_800

  def max_evidence_bytes, do: @max_evidence_bytes
  def max_safety_media_aggregate_bytes, do: @default_safety_media_aggregate_limit

  def create_report(attrs \\ %{}) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  def get_report(id) do
    Repo.get(Report, id)
  end

  def change_report(%Report{} = report, attrs \\ %{}) do
    Report.changeset(report, attrs)
  end

  def submit_conversation_report(conversation_id, reporter_id, category, evidence)
      when is_binary(conversation_id) and is_binary(reporter_id) and is_binary(category) and
             (is_binary(evidence) or is_nil(evidence)) do
    submit_conversation_report(conversation_id, reporter_id, category, evidence, nil)
  end

  def submit_conversation_report(_conversation_id, _reporter_id, _category, _evidence),
    do: {:error, :invalid_report_payload}

  def submit_conversation_report(
        conversation_id,
        reporter_id,
        category,
        evidence,
        target_client_message_id
      )
      when is_binary(conversation_id) and is_binary(reporter_id) and is_binary(category) and
             (is_binary(evidence) or is_nil(evidence)) and
             (is_binary(target_client_message_id) or is_nil(target_client_message_id)) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         true <- reporter_id in [conversation.participant_a_id, conversation.participant_b_id],
         {:ok, report_category} <- category_from_string(category),
         {:ok, authoritative_evidence, evidence_key} <-
           authoritative_evidence(
             conversation_id,
             reporter_id,
             evidence,
             target_client_message_id
           ) do
      reported_id = other_participant(conversation, reporter_id)

      deduplication_key =
        deduplication_key(
          conversation_id,
          reporter_id,
          reported_id,
          category,
          authoritative_evidence,
          evidence_key
        )

      create_report_and_review(
        conversation_id,
        reporter_id,
        reported_id,
        report_category,
        authoritative_evidence,
        deduplication_key
      )
    else
      nil -> {:error, :conversation_not_found}
      false -> {:error, :not_conversation_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def submit_conversation_report(
        _conversation_id,
        _reporter_id,
        _category,
        _evidence,
        _target_client_message_id
      ),
      do: {:error, :invalid_report_payload}

  defp authoritative_evidence(_conversation_id, _reporter_id, evidence, nil) do
    with :ok <- validate_evidence(evidence), do: {:ok, evidence, :participant_context}
  end

  defp authoritative_evidence(
         conversation_id,
         reporter_id,
         _browser_evidence,
         target_client_message_id
       ) do
    case ConversationServer.capture_report_evidence(
           conversation_id,
           reporter_id,
           target_client_message_id
         ) do
      {:ok, %{type: type, binary: binary, media_type: media_type, byte_size: byte_size}}
      when type in [:view_once_photo, :view_once_video] and is_binary(binary) and
             is_binary(media_type) ->
        max_bytes =
          case type do
            :view_once_photo -> 1_048_576
            :view_once_video -> 5_242_880
          end

        if byte_size(binary) <= max_bytes and byte_size <= max_bytes do
          {:ok,
           %{
             type: type,
             binary: binary,
             media_type: media_type,
             byte_size: byte_size
           }, {:target, target_client_message_id}}
        else
          {:ok, "[View-Once Media Evidence Unavailable: oversized]",
           {:target, target_client_message_id}}
        end

      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content, {:target, target_client_message_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp category_from_string(category) do
    case Map.fetch(@categories, category) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_report_category}
    end
  end

  defp validate_evidence(nil), do: :ok

  defp validate_evidence(evidence) when is_binary(evidence) do
    if String.valid?(evidence) and byte_size(evidence) <= @max_evidence_bytes,
      do: :ok,
      else: {:error, :invalid_report_payload}
  end

  defp other_participant(conversation, reporter_id) do
    if conversation.participant_a_id == reporter_id,
      do: conversation.participant_b_id,
      else: conversation.participant_a_id
  end

  defp create_report_and_review(
         conversation_id,
         reporter_id,
         reported_id,
         category,
         evidence,
         key
       ) do
    now = DateTime.utc_now()

    {reporter_context, media_evidence} =
      case evidence do
        %{type: :view_once_photo, binary: binary, media_type: media_type, byte_size: byte_size} ->
          {"[View-Once Photo Evidence Attached]",
           %{binary: binary, media_type: media_type, byte_size: byte_size}}

        %{type: :view_once_video, binary: binary, media_type: media_type, byte_size: byte_size} ->
          {"[View-Once Video Evidence Attached]",
           %{binary: binary, media_type: media_type, byte_size: byte_size}}

        text when is_binary(text) ->
          {text, nil}

        nil ->
          {nil, nil}
      end

    multi =
      Multi.new()
      |> Multi.insert(
        :report_attempt,
        Report.changeset(%Report{}, %{
          created_at: now,
          updated_at: now,
          reporting_participant_id: reporter_id,
          reported_participant_id: reported_id,
          conversation_id: conversation_id,
          report_category: category,
          report_status: :SUBMITTED,
          reporter_context: reporter_context,
          deduplication_key: key
        }),
        on_conflict: :nothing,
        conflict_target: [:deduplication_key]
      )
      |> Multi.run(:report, fn repo, _ -> {:ok, repo.get_by!(Report, deduplication_key: key)} end)
      |> Multi.run(:review_attempt, fn repo, %{report: report} ->
        SafetyReview.changeset(%SafetyReview{}, %{
          report_id: report.report_id,
          status: :PENDING,
          created_at: now,
          updated_at: now
        })
        |> repo.insert(on_conflict: :nothing, conflict_target: [:report_id])
      end)
      |> Multi.run(:review, fn repo, %{report: report} ->
        {:ok, repo.get_by!(SafetyReview, report_id: report.report_id)}
      end)

    multi =
      if media_evidence != nil do
        Multi.run(multi, :safety_media, fn repo, %{report: report} ->
          # Deterministic serialization lock on report_safety_media prevents concurrent over-admission
          Ecto.Adapters.SQL.query!(
            repo,
            "LOCK TABLE report_safety_media IN SHARE ROW EXCLUSIVE MODE",
            []
          )

          aggregate_limit =
            Application.get_env(
              :strangertalks_new,
              :safety_media_aggregate_byte_limit,
              @default_safety_media_aggregate_limit
            )

          current_aggregate =
            repo.one(from(s in ReportSafetyMedia, select: coalesce(sum(s.byte_size), 0))) || 0

          if current_aggregate + media_evidence.byte_size <= aggregate_limit do
            case repo.get_by(ReportSafetyMedia, report_id: report.report_id) do
              nil ->
                %ReportSafetyMedia{}
                |> ReportSafetyMedia.changeset(%{
                  report_id: report.report_id,
                  media_bytes: media_evidence.binary,
                  media_type: media_evidence.media_type,
                  byte_size: media_evidence.byte_size,
                  created_at: now
                })
                |> repo.insert()

              existing ->
                {:ok, existing}
            end
          else
            # Aggregate storage limit reached: preserve report record, omit media attachment
            {:ok, nil}
          end
        end)
      else
        multi
      end

    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{report: report}} -> {:ok, report}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp deduplication_key(
         conversation_id,
         reporter_id,
         reported_id,
         category,
         %{type: type, binary: binary},
         evidence_key
       )
       when type in [:view_once_photo, :view_once_video] do
    [
      conversation_id,
      reporter_id,
      reported_id,
      category,
      inspect(evidence_key),
      Base.encode16(:crypto.hash(:sha256, binary))
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp deduplication_key(
         conversation_id,
         reporter_id,
         reported_id,
         category,
         evidence,
         evidence_key
       ) do
    [conversation_id, reporter_id, reported_id, category, inspect(evidence_key), evidence || ""]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
