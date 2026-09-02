defmodule StrangertalksNew.SafetyEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:safety_event_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "safety_events" do
    field :event_status, Ecto.Enum, values: [:OPEN, :UNDER_REVIEW, :RESOLVED, :DISMISSED]

    field :event_type, Ecto.Enum,
      values: [
        :REPORT,
        :BLOCK,
        :RELATIONSHIP_CLOSURE,
        :EMERGENCY_EXIT,
        :SAFETY_FLAG,
        :SYSTEM_REVIEW,
        :AUTOMATED_DETECTION
      ]

    field :severity_level, Ecto.Enum, values: [:LOW, :MEDIUM, :HIGH, :CRITICAL]

    field :report_category, Ecto.Enum,
      values: [
        :HARASSMENT,
        :ABUSIVE_LANGUAGE,
        :SEXUAL_MISCONDUCT,
        :THREAT,
        :SPAM,
        :IMPERSONATION,
        :OTHER
      ]

    field :block_reason, Ecto.Enum,
      values: [:PERSONAL_BOUNDARY, :SAFETY_CONCERN, :HARASSMENT, :OTHER]

    field :exit_context, Ecto.Enum, values: [:CONVERSATION, :RELATIONSHIP, :MATCHING]

    field :flag_reason, Ecto.Enum,
      values: [
        :ABUSE_PATTERN,
        :MULTIPLE_REPORTS,
        :SAFETY_THRESHOLD,
        :SPAM_PATTERN,
        :UNUSUAL_BEHAVIOR
      ]

    field :review_outcome, Ecto.Enum,
      values: [:NO_ACTION, :WARNING, :RESTRICTION, :SUSPENSION, :PERMANENT_BAN]

    field :action_type, Ecto.Enum,
      values: [:NONE, :MATCH_RESTRICTION, :TEMPORARY_RESTRICTION, :SUSPENSION, :PERMANENT_BAN]

    field :visibility_level, Ecto.Enum,
      values: [:PRIVATE, :SAFETY_TEAM_ONLY, :SYSTEM_ONLY],
      default: :SAFETY_TEAM_ONLY

    field :report_description, :string
    field :block_created, :boolean, default: false
    field :emergency_exit_triggered, :boolean, default: false
    field :automated_flag, :boolean, default: false
    field :confidence_score, :decimal
    field :review_required, :boolean, default: false
    field :action_taken, :boolean, default: false
    field :related_event_count, :integer, default: 0
    field :participant_report_count, :integer, default: 0
    field :participant_block_count, :integer, default: 0
    field :contains_sensitive_data, :boolean, default: false
    field :learning_processed, :boolean, default: false
    field :learning_version, :string
    field :safety_summary, :map, default: %{}

    # Explicit Timestamps
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :report_submitted_at, :utc_datetime_usec
    field :block_timestamp, :utc_datetime_usec
    field :exit_timestamp, :utc_datetime_usec
    field :review_started_at, :utc_datetime_usec
    field :review_completed_at, :utc_datetime_usec
    field :action_timestamp, :utc_datetime_usec

    # Relationships
    belongs_to :reporting_participant, StrangertalksNew.Participant,
      foreign_key: :reporting_participant_id,
      references: :participant_id

    belongs_to :target_participant, StrangertalksNew.Participant,
      foreign_key: :target_participant_id,
      references: :participant_id

    belongs_to :affected_participant, StrangertalksNew.Participant,
      foreign_key: :affected_participant_id,
      references: :participant_id

    belongs_to :conversation, StrangertalksNew.Conversation,
      foreign_key: :conversation_id,
      references: :conversation_id

    # ✅ Fix here: point to Matching schema
    belongs_to :match, StrangertalksNew.Matching, foreign_key: :match_id, references: :match_id

    belongs_to :relationship, StrangertalksNew.Relationship,
      foreign_key: :relationship_id,
      references: :relationship_id
  end

  def changeset(safety_event, attrs) do
    required_fields = [
      :event_status,
      :event_type,
      :severity_level,
      :related_event_count,
      :participant_report_count,
      :participant_block_count,
      :created_at,
      :updated_at
    ]

    safety_event
    |> cast(
      attrs,
      required_fields ++
        [
          :report_category,
          :block_reason,
          :exit_context,
          :flag_reason,
          :review_outcome,
          :action_type,
          :visibility_level,
          :report_description,
          :block_created,
          :emergency_exit_triggered,
          :automated_flag,
          :confidence_score,
          :review_required,
          :action_taken,
          :contains_sensitive_data,
          :learning_processed,
          :learning_version,
          :safety_summary,
          :report_submitted_at,
          :block_timestamp,
          :exit_timestamp,
          :review_started_at,
          :review_completed_at,
          :action_timestamp,
          :reporting_participant_id,
          :target_participant_id,
          :affected_participant_id,
          :conversation_id,
          :match_id,
          :relationship_id
        ]
    )
    |> validate_required(required_fields)
    |> validate_confidence_score()
    |> foreign_key_constraint(:reporting_participant_id)
    |> foreign_key_constraint(:target_participant_id)
    |> foreign_key_constraint(:affected_participant_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:match_id)
    |> foreign_key_constraint(:relationship_id)
  end

  defp validate_confidence_score(changeset) do
    case get_change(changeset, :confidence_score) do
      nil ->
        changeset

      score ->
        if Decimal.compare(score, Decimal.new("0.0")) != :lt and
             Decimal.compare(score, Decimal.new("1.0")) != :gt do
          changeset
        else
          add_error(changeset, :confidence_score, "must be between 0.0 and 1.0")
        end
    end
  end
end
