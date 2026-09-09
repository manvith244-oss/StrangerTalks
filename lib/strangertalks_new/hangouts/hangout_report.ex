defmodule StrangertalksNew.Hangouts.HangoutReport do
  use Ecto.Schema
  import Ecto.Changeset

  @max_evidence_bytes 4_096
  @categories [:SPAM, :HARASSMENT, :SEXUAL_MISCONDUCT, :MALICIOUS_LINKS, :THREATS]
  @primary_key {:report_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hangout_reports" do
    belongs_to :room, StrangertalksNew.Hangouts.HangoutRoom,
      foreign_key: :room_id,
      references: :room_id

    belongs_to :reporting_participant, StrangertalksNew.Participant,
      foreign_key: :reporting_participant_id,
      references: :participant_id

    belongs_to :reported_participant, StrangertalksNew.Participant,
      foreign_key: :reported_participant_id,
      references: :participant_id

    field :category, Ecto.Enum, values: @categories
    field :status, Ecto.Enum, values: [:SUBMITTED, :UNDER_REVIEW, :RESOLVED, :DISMISSED]
    field :evidence, :string
    field :deduplication_key, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
  end

  def max_evidence_bytes, do: @max_evidence_bytes

  def changeset(report, attrs, room_id, reporting_participant_id, reported_participant_id \\ nil)
      when is_binary(room_id) and is_binary(reporting_participant_id) do
    report
    |> cast(attrs, [
      :category,
      :status,
      :evidence,
      :deduplication_key,
      :created_at,
      :updated_at,
      :resolved_at
    ])
    |> put_change(:room_id, room_id)
    |> put_change(:reporting_participant_id, reporting_participant_id)
    |> put_reported_participant(reported_participant_id)
    |> validate_required([:room_id, :reporting_participant_id, :category, :status, :created_at, :updated_at])
    |> validate_evidence()
    |> validate_self_reporting()
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:reporting_participant_id)
    |> foreign_key_constraint(:reported_participant_id)
    |> unique_constraint(:deduplication_key)
  end

  defp put_reported_participant(changeset, participant_id) when is_binary(participant_id),
    do: put_change(changeset, :reported_participant_id, participant_id)

  defp put_reported_participant(changeset, nil), do: changeset

  defp validate_evidence(changeset) do
    validate_change(changeset, :evidence, fn :evidence, evidence ->
      cond do
        not is_binary(evidence) -> [evidence: "is invalid"]
        not String.valid?(evidence) -> [evidence: "is invalid"]
        byte_size(evidence) > @max_evidence_bytes -> [evidence: "is too large"]
        true -> []
      end
    end)
  end

  defp validate_self_reporting(changeset) do
    reporting = get_field(changeset, :reporting_participant_id)
    reported = get_field(changeset, :reported_participant_id)

    if is_binary(reporting) and reporting == reported do
      add_error(changeset, :reported_participant_id, "cannot report yourself")
    else
      changeset
    end
  end
end
