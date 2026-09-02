defmodule StrangertalksNew.Matching do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:match_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "matches" do
    field :created_at, :utc_datetime_usec

    field :door_type, Ecto.Enum, values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :participant_a_door_type, Ecto.Enum,
      values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :participant_b_door_type, Ecto.Enum,
      values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :conversation_language, :string

    field :match_status, Ecto.Enum,
      values: [:CREATED, :TRANSITIONING, :ACTIVE, :ENDED, :FAILED, :EXPIRED]

    field :match_strategy, Ecto.Enum,
      values: [
        COMPATIBILITY: "COMPATIBILITY",
        OPPORTUNITY: "OPPORTUNITY",
        SCARCITY: "SCARCITY",
        MANUAL_OVERRIDE: "MANUAL_OVERRIDE",
        relationship_reconnect_v1: "RELATIONSHIP_RECONNECT_V1"
      ]

    field :failure_reason, Ecto.Enum,
      values: [
        :NO_RESPONSE,
        :DISCONNECT,
        :LEFT_DURING_TRANSITION,
        :LEFT_IMMEDIATELY,
        :TECHNICAL_FAILURE,
        :SAFETY_EVENT
      ]

    field :queue_id, :binary_id
    field :atmosphere_id, :binary_id
    field :icebreaker_id, :binary_id
    field :transition_experience_id, :binary_id

    field :compatibility_score, :decimal
    field :compatibility_version, :string
    field :opportunity_score, :decimal
    field :scarcity_adjustment, :decimal
    field :conversation_temperature, :decimal
    field :mutual_participation_score, :decimal
    field :conversation_health_score, :decimal
    field :match_quality_score, :decimal

    field :queue_entry_time, :utc_datetime_usec
    field :match_found_time, :utc_datetime_usec
    field :conversation_start_time, :utc_datetime_usec
    field :match_end_time, :utc_datetime_usec

    field :queue_duration_seconds, :integer
    field :conversation_duration_seconds, :integer

    field :conversation_started, :boolean
    field :conversation_completed, :boolean
    field :memory_created, :boolean
    field :relationship_created, :boolean
    field :reconnected_later, :boolean
    field :report_generated, :boolean
    field :block_generated, :boolean
    field :safety_review_required, :boolean
    field :learning_processed, :boolean

    field :learning_version, :string

    belongs_to :participant_a, StrangertalksNew.Participant,
      foreign_key: :participant_a_id,
      references: :participant_id

    belongs_to :participant_b, StrangertalksNew.Participant,
      foreign_key: :participant_b_id,
      references: :participant_id
  end

  @required_fields [
    :created_at,
    :participant_a_door_type,
    :participant_b_door_type,
    :match_status,
    :match_strategy,
    :participant_a_id,
    :participant_b_id,
    :queue_entry_time,
    :match_found_time,
    :queue_duration_seconds,
    :conversation_duration_seconds,
    :conversation_started,
    :conversation_completed,
    :memory_created,
    :relationship_created,
    :reconnected_later,
    :report_generated,
    :block_generated,
    :safety_review_required,
    :learning_processed
  ]

  @optional_fields [
    :door_type,
    :conversation_language,
    :failure_reason,
    :compatibility_version,
    :opportunity_score,
    :scarcity_adjustment,
    :conversation_temperature,
    :mutual_participation_score,
    :conversation_health_score,
    :match_quality_score,
    :learning_version,
    :compatibility_score,
    :queue_id,
    :atmosphere_id,
    :icebreaker_id,
    :transition_experience_id,
    :conversation_start_time,
    :match_end_time
  ]

  def changeset(matching, attrs) do
    attrs = backfill_entry_doors(attrs)

    changeset =
      matching
      |> cast(attrs, @required_fields ++ @optional_fields)
      |> validate_required(@required_fields)

    changeset =
      if get_field(changeset, :match_strategy) == :relationship_reconnect_v1,
        do: changeset,
        else: validate_required(changeset, [:compatibility_score])

    changeset
    |> check_constraint(:match_strategy, name: :match_strategy_check)
    |> check_constraint(:compatibility_score, name: :matches_compatibility_by_strategy_check)
    |> check_constraint(:conversation_language, name: :conversation_language_check)
    |> foreign_key_constraint(:participant_a_id)
    |> foreign_key_constraint(:participant_b_id)
    |> unique_constraint(:match_id, name: :matches_pkey)
  end

  defp backfill_entry_doors(attrs) do
    door = Map.get(attrs, :door_type) || Map.get(attrs, "door_type")

    if door do
      attrs
      |> Map.put_new(:participant_a_door_type, door)
      |> Map.put_new(:participant_b_door_type, door)
    else
      attrs
    end
  end
end
