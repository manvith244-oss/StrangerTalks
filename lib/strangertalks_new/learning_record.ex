defmodule StrangertalksNew.LearningRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:learning_record_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "learning_records" do
    field :record_type, Ecto.Enum,
      values: [:ICEBREAKER_LEARNING, :ATMOSPHERE_ADAPTATION, :READINESS_EVALUATION]

    field :bridge_used, :string
    field :bridge_category, Ecto.Enum, values: [:UNIVERSAL, :CONTEXT, :SPECIALIZED]
    field :bridge_effectiveness_score, :decimal
    field :complexity_level, Ecto.Enum, values: [:LOW, :MEDIUM, :HIGH]

    field :atmosphere_environment, Ecto.Enum,
      values: [
        :LATE_NIGHT_LIBRARY,
        :RAIN_WINDOW,
        :COFFEE_SHOP,
        :TRAIN_JOURNEY,
        :AURORA,
        :NIGHT_OBSERVATORY,
        :SOFT_HORIZON
      ]

    field :readiness_score, :decimal
    field :keystroke_latency_variance, :decimal
    field :outcome_signal, Ecto.Enum, values: [:SUCCESS, :FAILURE, :ABANDONED, :TIMEOUT]

    field :created_at, :utc_datetime_usec

    # Structural Associations
    belongs_to :participant, StrangertalksNew.Participant,
      foreign_key: :participant_id,
      references: :participant_id

    belongs_to :match, StrangertalksNew.Matching, foreign_key: :match_id, references: :match_id

    belongs_to :conversation, StrangertalksNew.Conversation,
      foreign_key: :conversation_id,
      references: :conversation_id
  end

  def changeset(learning_record, attrs) do
    learning_record
    |> cast(attrs, [
      :record_type,
      :bridge_used,
      :bridge_category,
      :bridge_effectiveness_score,
      :complexity_level,
      :atmosphere_environment,
      :readiness_score,
      :keystroke_latency_variance,
      :outcome_signal,
      :created_at,
      :participant_id,
      :match_id,
      :conversation_id
    ])
    |> validate_required([:record_type, :created_at])
    |> validate_decimal_bounds(:bridge_effectiveness_score)
    |> validate_decimal_bounds(:readiness_score)
    |> validate_decimal_bounds(:keystroke_latency_variance)
    |> validate_conditional_dependencies()
  end

  defp validate_decimal_bounds(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case Decimal.compare(value, Decimal.new("0.0000")) == :lt or
             Decimal.compare(value, Decimal.new("9.9999")) == :gt do
        true -> [{field, "must be between 0.0000 and 9.9999"}]
        false -> []
      end
    end)
  end

  defp validate_conditional_dependencies(changeset) do
    case get_field(changeset, :record_type) do
      :ICEBREAKER_LEARNING ->
        changeset
        |> validate_required([:bridge_used, :bridge_category])

      :READINESS_EVALUATION ->
        changeset
        |> validate_required([:keystroke_latency_variance, :readiness_score])

      _ ->
        changeset
    end
  end
end
