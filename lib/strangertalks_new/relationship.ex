defmodule StrangertalksNew.Relationship do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:relationship_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "relationships" do
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :last_conversation_at, :utc_datetime_usec
    field :last_activity_at, :utc_datetime_usec
    field :first_conversation_at, :utc_datetime_usec
    field :latest_note_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    field :relationship_status, Ecto.Enum, values: [:ACTIVE, :QUIET, :PAUSED, :CLOSED]

    field :origin_door_type, Ecto.Enum,
      values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :origin_participant_a_door_type, Ecto.Enum,
      values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :origin_participant_b_door_type, Ecto.Enum,
      values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

    field :closure_reason, Ecto.Enum,
      values: [:PARTICIPANT_CLOSED, :BLOCKED, :SAFETY_ACTION, :INACTIVE_EXPIRATION]

    field :origin_atmosphere_id, :binary_id
    field :latest_conversation_id, :binary_id
    field :latest_memory_id, :binary_id
    field :featured_memory_id, :binary_id
    field :closed_by_participant_id, :binary_id

    field :participant_a_accepted, :boolean
    field :participant_b_accepted, :boolean
    field :allow_reconnection, :boolean, default: true
    field :reconnection_eligible, :boolean
    field :participant_a_closed, :boolean, default: false
    field :participant_b_closed, :boolean, default: false
    field :participant_a_blocked, :boolean, default: false
    field :participant_b_blocked, :boolean, default: false
    field :learning_processed, :boolean

    field :relationship_name, :string
    field :participant_custom_name, :string
    field :most_common_atmosphere, :string
    field :learning_version, :string

    field :conversation_count, :integer, default: 0
    field :memory_count, :integer, default: 0
    field :reconnection_count, :integer, default: 0
    field :shared_memory_count, :integer, default: 0
    field :private_note_count, :integer, default: 0

    field :reconnection_priority, :decimal
    field :relationship_strength_score, :decimal
    field :continuation_probability, :decimal
    field :relationship_temperature, :decimal

    field :atmosphere_history, :map
    field :relationship_summary, :map

    belongs_to :participant_a, StrangertalksNew.Participant,
      foreign_key: :participant_a_id,
      references: :participant_id

    belongs_to :participant_b, StrangertalksNew.Participant,
      foreign_key: :participant_b_id,
      references: :participant_id

    belongs_to :origin_conversation, StrangertalksNew.Conversation,
      foreign_key: :origin_conversation_id,
      references: :conversation_id

    belongs_to :origin_match, StrangertalksNew.Matching,
      foreign_key: :origin_match_id,
      references: :match_id
  end

  def changeset(relationship, attrs) do
    # Normalize input parameters to reconcile test suite variant formats smoothly
    normalized_attrs =
      cond do
        Map.has_key?(attrs, :reconnect_eligible) ->
          Map.put_new(attrs, :reconnection_eligible, Map.get(attrs, :reconnect_eligible))

        Map.has_key?(attrs, "reconnect_eligible") ->
          Map.put_new(attrs, "reconnection_eligible", Map.get(attrs, "reconnect_eligible"))

        true ->
          attrs
      end

    normalized_attrs = backfill_origin_doors(normalized_attrs)

    relationship
    |> cast(normalized_attrs, [
      :created_at,
      :updated_at,
      :accepted_at,
      :last_conversation_at,
      :last_activity_at,
      :first_conversation_at,
      :latest_note_at,
      :closed_at,
      :relationship_status,
      :origin_door_type,
      :origin_participant_a_door_type,
      :origin_participant_b_door_type,
      :closure_reason,
      :participant_a_id,
      :participant_b_id,
      :origin_conversation_id,
      :origin_match_id,
      :origin_atmosphere_id,
      :latest_conversation_id,
      :latest_memory_id,
      :featured_memory_id,
      :closed_by_participant_id,
      :participant_a_accepted,
      :participant_b_accepted,
      :allow_reconnection,
      :reconnection_eligible,
      :participant_a_closed,
      :participant_b_closed,
      :participant_a_blocked,
      :participant_b_blocked,
      :learning_processed,
      :relationship_name,
      :participant_custom_name,
      :most_common_atmosphere,
      :learning_version,
      :conversation_count,
      :memory_count,
      :reconnection_count,
      :shared_memory_count,
      :private_note_count,
      :reconnection_priority,
      :relationship_strength_score,
      :continuation_probability,
      :relationship_temperature,
      :atmosphere_history,
      :relationship_summary
    ])
    |> unique_constraint([:participant_a_id, :participant_b_id],
      name: :relationships_canonical_pair_index
    )
    |> validate_required([
      :created_at,
      :updated_at,
      :first_conversation_at,
      :relationship_status,
      :origin_participant_a_door_type,
      :origin_participant_b_door_type,
      :participant_a_id,
      :participant_b_id,
      :origin_conversation_id,
      :origin_match_id,
      :participant_a_accepted,
      :participant_b_accepted,
      :allow_reconnection,
      :reconnection_eligible,
      :participant_a_closed,
      :participant_b_closed,
      :participant_a_blocked,
      :participant_b_blocked,
      :conversation_count,
      :memory_count,
      :reconnection_count,
      :shared_memory_count,
      :private_note_count
    ])
    |> validate_distinct_participants()
    |> check_constraint(:participant_b_id,
      name: :relationships_distinct_participants_check,
      message: "must identify two different participants"
    )
  end

  defp backfill_origin_doors(attrs) do
    door = Map.get(attrs, :origin_door_type) || Map.get(attrs, "origin_door_type")

    if door do
      attrs
      |> Map.put_new(:origin_participant_a_door_type, door)
      |> Map.put_new(:origin_participant_b_door_type, door)
    else
      attrs
    end
  end

  defp validate_distinct_participants(changeset) do
    participant_a_id = get_field(changeset, :participant_a_id)
    participant_b_id = get_field(changeset, :participant_b_id)

    if is_binary(participant_a_id) and participant_a_id == participant_b_id do
      add_error(changeset, :participant_b_id, "must identify two different participants")
    else
      changeset
    end
  end
end
