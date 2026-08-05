defmodule StrangertalksNew.Reports do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Report
  alias StrangertalksNew.Conversation

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

      case existing_report(conversation_id, reporter_id, reported_id, report_category, evidence) do
        %Report{} = report ->
          {:ok, report}

        nil ->
          now = DateTime.utc_now()

          create_report(%{
            created_at: now,
            updated_at: now,
            reporting_participant_id: reporter_id,
            reported_participant_id: reported_id,
            conversation_id: conversation_id,
            report_category: report_category,
            report_status: :SUBMITTED,
            reporter_context: evidence
          })
      end
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

  defp existing_report(conversation_id, reporter_id, reported_id, category, evidence) do
    base_query =
      from report in Report,
        where:
          report.conversation_id == ^conversation_id and
            report.reporting_participant_id == ^reporter_id and
            report.reported_participant_id == ^reported_id and
            report.report_category == ^category

    evidence_query =
      if is_nil(evidence) do
        from report in base_query, where: is_nil(report.reporter_context)
      else
        from report in base_query, where: report.reporter_context == ^evidence
      end

    Repo.one(from report in evidence_query, limit: 1)
  end
end
