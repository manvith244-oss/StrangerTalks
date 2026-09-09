defmodule StrangertalksNew.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:conversation_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :created_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    field :conversation_status, Ecto.Enum,
      values: [:PENDING, :ACTIVE, :PAUSED, :ENDED, :ABANDONED, :FAILED]

    field :door_type, Ecto.Enum, values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :ending_type, Ecto.Enum,
      values: [:NATURAL_END, :PARTICIPANT_LEFT, :TIMEOUT, :DISCONNECT, :BLOCK, :SAFETY_ACTION]

    field :ending_initiator, :binary_id

    field :atmosphere_id, :binary_id
    field :icebreaker_id, :binary_id
    field :transition_id, :binary_id
    field :primary_memory_id, :binary_id
    field :relationship_id, :binary_id

    field :message_count, :integer
    field :voice_note_count, :integer
    field :first_message_timestamp, :utc_datetime_usec
    field :last_message_timestamp, :utc_datetime_usec
    field :average_response_time, :float
    field :participation_balance_score, :decimal
    field :message_exchange_rate, :float
    field :conversation_depth_score, :decimal
    field :conversation_temperature, :decimal

    field :bridge_shown, :boolean
    field :bridge_used, :boolean
    field :bridge_ignored, :boolean
    field :bridge_effectiveness_score, :decimal

    field :conversation_completed, :boolean
    field :memory_created, :boolean
    field :relationship_created, :boolean
    field :reconnected_later, :boolean
    field :conversation_success_score, :decimal

    field :memory_count, :integer
    field :relationship_created_at_end, :boolean
    field :report_count, :integer
    field :block_count, :integer
    field :safety_flagged, :boolean
    field :safety_score, :decimal

    field :learning_processed, :boolean
    field :learning_version, :string
    field :learning_summary, :map

    field :duration_seconds, :integer
    field :time_to_first_message_seconds, :integer
    field :time_to_first_reply_seconds, :integer
    field :longest_silence_seconds, :integer

    belongs_to :match, StrangertalksNew.Matching, foreign_key: :match_id, references: :match_id

    belongs_to :participant_a, StrangertalksNew.Participant,
      foreign_key: :participant_a_id,
      references: :participant_id

    belongs_to :participant_b, StrangertalksNew.Participant,
      foreign_key: :participant_b_id,
      references: :participant_id
  end

  @required_fields [
    :created_at,
    :match_id,
    :participant_a_id,
    :participant_b_id,
    :conversation_status,
    :message_count,
    :voice_note_count,
    :bridge_shown,
    :bridge_used,
    :bridge_ignored,
    :conversation_completed,
    :memory_created,
    :relationship_created,
    :reconnected_later,
    :memory_count,
    :relationship_created_at_end,
    :report_count,
    :block_count,
    :safety_flagged,
    :learning_processed,
    :duration_seconds
  ]

  @optional_fields [
    :door_type,
    :ended_at,
    :average_response_time,
    :participation_balance_score,
    :message_exchange_rate,
    :conversation_depth_score,
    :conversation_temperature,
    :bridge_effectiveness_score,
    :conversation_success_score,
    :safety_score,
    :time_to_first_message_seconds,
    :time_to_first_reply_seconds,
    :longest_silence_seconds,
    :learning_version,
    :ending_type,
    :ending_initiator,
    :atmosphere_id,
    :icebreaker_id,
    :transition_id,
    :primary_memory_id,
    :relationship_id,
    :first_message_timestamp,
    :last_message_timestamp,
    :learning_summary
  ]

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_distinct_participants()
    |> check_constraint(:participant_b_id,
      name: :conversations_distinct_participants_check,
      message: "must identify two different participants"
    )
    |> foreign_key_constraint(:match_id)
    |> foreign_key_constraint(:match_id,
      name: :conversations_match_participants_fkey,
      message: "does not match durable Match participants"
    )
    |> foreign_key_constraint(:participant_a_id)
    |> foreign_key_constraint(:participant_b_id)
    |> unique_constraint(:conversation_id, name: :conversations_pkey)
    |> unique_constraint(:match_id, name: :conversations_match_id_index)
  end

  defp validate_distinct_participants(changeset) do
    participant_a_id = get_field(changeset, :participant_a_id)
    participant_b_id = get_field(changeset, :participant_b_id)

    if participant_a_id && participant_b_id && participant_a_id == participant_b_id do
      add_error(changeset, :participant_b_id, "must identify two different participants")
    else
      changeset
    end
  end
end
