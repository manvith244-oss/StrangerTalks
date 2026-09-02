defmodule StrangertalksNew.SafetyReview do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:safety_review_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "safety_reviews" do
    field :status, Ecto.Enum, values: [:PENDING, :IN_REVIEW, :RESOLVED, :DISMISSED]
    field :severity_level, Ecto.Enum, values: [:LOW, :MEDIUM, :HIGH, :CRITICAL]
    field :resolution, :string
    field :review_notes, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :reviewed_at, :utc_datetime_usec
    belongs_to :report, StrangertalksNew.Report, references: :report_id
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :report_id,
      :status,
      :severity_level,
      :resolution,
      :review_notes,
      :created_at,
      :updated_at,
      :reviewed_at
    ])
    |> validate_required([:report_id, :status, :created_at, :updated_at])
    |> foreign_key_constraint(:report_id)
    |> unique_constraint(:report_id)
  end
end
