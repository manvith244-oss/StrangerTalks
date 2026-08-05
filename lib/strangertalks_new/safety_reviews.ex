defmodule StrangertalksNew.SafetyReviews do
  import Ecto.Query, warn: false
  alias StrangertalksNew.{Repo, SafetyReview}

  def get_review(id), do: Repo.get(SafetyReview, id)
  def get_review_by_report(report_id), do: Repo.get_by(SafetyReview, report_id: report_id)

  def start_review(review_id) do
    transition(review_id, fn
      %SafetyReview{status: :PENDING} = review ->
        update_review(review, %{status: :IN_REVIEW, updated_at: DateTime.utc_now()})

      %SafetyReview{status: :IN_REVIEW} = review ->
        {:ok, review}

      _ ->
        {:error, :terminal_review}
    end)
  end

  def resolve_review(review_id, severity, resolution, notes) do
    with true <- severity in [:LOW, :MEDIUM, :HIGH, :CRITICAL],
         true <- valid_resolution?(resolution) do
      transition(review_id, fn
        %SafetyReview{status: status} = review when status in [:PENDING, :IN_REVIEW] ->
          now = DateTime.utc_now()

          update_review(review, %{
            status: :RESOLVED,
            severity_level: severity,
            resolution: resolution,
            review_notes: notes,
            reviewed_at: now,
            updated_at: now
          })

        %SafetyReview{
          status: :RESOLVED,
          severity_level: ^severity,
          resolution: ^resolution,
          review_notes: ^notes
        } = review ->
          {:ok, review}

        _ ->
          {:error, :conflicting_terminal_decision}
      end)
    else
      false -> {:error, :invalid_review_decision}
    end
  end

  def dismiss_review(review_id, resolution, notes) do
    if valid_resolution?(resolution) do
      transition(review_id, fn
        %SafetyReview{status: status} = review when status in [:PENDING, :IN_REVIEW] ->
          now = DateTime.utc_now()

          update_review(review, %{
            status: :DISMISSED,
            severity_level: nil,
            resolution: resolution,
            review_notes: notes,
            reviewed_at: now,
            updated_at: now
          })

        %SafetyReview{
          status: :DISMISSED,
          severity_level: nil,
          resolution: ^resolution,
          review_notes: ^notes
        } = review ->
          {:ok, review}

        _ ->
          {:error, :conflicting_terminal_decision}
      end)
    else
      {:error, :invalid_review_decision}
    end
  end

  defp transition(id, fun) do
    case Repo.get(SafetyReview, id) do
      nil -> {:error, :review_not_found}
      review -> fun.(review)
    end
  end

  defp update_review(review, attrs), do: review |> SafetyReview.changeset(attrs) |> Repo.update()
  defp valid_resolution?(value), do: is_binary(value) and String.trim(value) != ""
end
