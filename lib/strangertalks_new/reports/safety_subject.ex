defmodule StrangertalksNew.Reports.SafetySubject do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:subject_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_roles [:REPORTER, :REPORTED, :EVIDENCE_AUTHOR]

  schema "safety_subjects" do
    field :subject_role, Ecto.Enum, values: @valid_roles
    field :source_temporary_identity_slot, :integer
    field :created_at, :utc_datetime_usec

    belongs_to :report, StrangertalksNew.Report,
      foreign_key: :report_id,
      references: :report_id

    belongs_to :source_participant, StrangertalksNew.Participant,
      foreign_key: :source_participant_id,
      references: :participant_id

    has_many :authored_evidence_items, StrangertalksNew.Reports.ReportEvidenceItem,
      foreign_key: :subject_id
  end

  def changeset(subject, attrs) do
    subject
    |> cast(attrs, [
      :report_id,
      :subject_role,
      :source_participant_id,
      :source_temporary_identity_slot,
      :created_at
    ])
    |> validate_required([:report_id, :subject_role, :created_at])
    |> check_constraint(:subject_role, name: :safety_subjects_role_check)
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:source_participant_id)
  end
end
