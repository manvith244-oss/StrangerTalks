defmodule StrangertalksNew.Reports.ReportEvidenceItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:evidence_item_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_source_kinds [:CONVERSATION, :HANGOUT]
  @valid_evidence_roles [:SELECTED, :CONTEXT_EXPANSION]

  schema "report_evidence_items" do
    field :source_kind, Ecto.Enum, values: @valid_source_kinds
    field :evidence_role, Ecto.Enum, values: @valid_evidence_roles
    field :source_item_id, :string
    field :source_sequence, :integer
    field :source_timestamp, :utc_datetime_usec
    field :content_snapshot, :string
    field :media_type, :string
    field :media_bytes, :binary
    field :byte_size, :integer
    field :captured_at, :utc_datetime_usec

    belongs_to :report, StrangertalksNew.Report,
      foreign_key: :report_id,
      references: :report_id

    belongs_to :subject, StrangertalksNew.Reports.SafetySubject,
      foreign_key: :subject_id,
      references: :subject_id
  end

  def changeset(evidence_item, attrs) do
    evidence_item
    |> cast(attrs, [
      :report_id,
      :subject_id,
      :source_kind,
      :evidence_role,
      :source_item_id,
      :source_sequence,
      :source_timestamp,
      :content_snapshot,
      :media_type,
      :media_bytes,
      :byte_size,
      :captured_at
    ])
    |> validate_required([
      :report_id,
      :source_kind,
      :evidence_role,
      :captured_at
    ])
    |> check_constraint(:source_kind, name: :report_evidence_items_source_kind_check)
    |> check_constraint(:evidence_role, name: :report_evidence_items_evidence_role_check)
    |> check_constraint(:byte_size, name: :report_evidence_items_byte_size_check)
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:subject_id)
  end
end
