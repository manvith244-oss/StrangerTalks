defmodule StrangertalksNew.Report do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:report_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reports" do
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    field :report_category, Ecto.Enum,
      values: [:SPAM, :HARASSMENT, :SEXUAL_MISCONDUCT, :MALICIOUS_LINKS, :THREATS]

    field :report_status, Ecto.Enum,
      values: [:SUBMITTED, :UNDER_REVIEW, :RESOLVED, :DISMISSED],
      default: :SUBMITTED

    field :resolution_outcome, Ecto.Enum,
      values: [:NO_ACTION, :WARNING, :COOLDOWN, :PERMANENT_BAN]

    field :reporter_context, :string
    field :deduplication_key, :string

    belongs_to :reporting_participant, StrangertalksNew.Participant,
      foreign_key: :reporting_participant_id,
      references: :participant_id

    belongs_to :reported_participant, StrangertalksNew.Participant,
      foreign_key: :reported_participant_id,
      references: :participant_id

    belongs_to :conversation, StrangertalksNew.Conversation,
      foreign_key: :conversation_id,
      references: :conversation_id

    belongs_to :reported_message, StrangertalksNew.Message,
      foreign_key: :reported_message_id,
      references: :message_id
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :created_at,
      :updated_at,
      :resolved_at,
      :reporting_participant_id,
      :reported_participant_id,
      :conversation_id,
      :reported_message_id,
      :report_category,
      :report_status,
      :resolution_outcome,
      :reporter_context,
      :deduplication_key
    ])
    |> validate_required([
      :created_at,
      :updated_at,
      :reporting_participant_id,
      :reported_participant_id,
      :conversation_id,
      :report_category,
      :report_status
    ])
    |> validate_self_reporting()
    |> foreign_key_constraint(:reporting_participant_id)
    |> foreign_key_constraint(:reported_participant_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:reported_message_id)
    |> unique_constraint(:deduplication_key)
  end

  defp validate_self_reporting(changeset) do
    reporting = get_field(changeset, :reporting_participant_id)
    reported = get_field(changeset, :reported_participant_id)

    if reporting && reported && reporting == reported do
      add_error(changeset, :reporting_participant_id, "cannot report yourself")
    else
      changeset
    end
  end
end
