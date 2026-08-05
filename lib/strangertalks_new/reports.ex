defmodule StrangertalksNew.Reports do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Report
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.SafetyReview
  alias Ecto.Multi

  @categories %{
    "SPAM" => :SPAM,
    "HARASSMENT" => :HARASSMENT,
    "SEXUAL_MISCONDUCT" => :SEXUAL_MISCONDUCT,
    "MALICIOUS_LINKS" => :MALICIOUS_LINKS,
    "THREATS" => :THREATS
  }

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
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         true <- reporter_id in [conversation.participant_a_id, conversation.participant_b_id],
         {:ok, report_category} <- category_from_string(category) do
      reported_id = other_participant(conversation, reporter_id)

      deduplication_key =
        deduplication_key(conversation_id, reporter_id, reported_id, category, evidence)

      create_report_and_review(
        conversation_id,
        reporter_id,
        reported_id,
        report_category,
        evidence,
        deduplication_key
      )
    else
      nil -> {:error, :conversation_not_found}
      false -> {:error, :not_conversation_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def submit_conversation_report(_conversation_id, _reporter_id, _category, _evidence),
    do: {:error, :invalid_report_payload}

  defp category_from_string(category) do
    case Map.fetch(@categories, category) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_report_category}
    end
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
        reporter_context: evidence,
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
    |> Repo.transaction()
    |> case do
      {:ok, %{report: report}} -> {:ok, report}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp deduplication_key(conversation_id, reporter_id, reported_id, category, evidence) do
    [conversation_id, reporter_id, reported_id, category, evidence || ""]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
