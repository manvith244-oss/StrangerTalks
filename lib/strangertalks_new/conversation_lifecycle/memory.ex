# filepath: lib/strangertalks_new/conversation_lifecycle/memory.ex
defmodule StrangertalksNew.Memory do
  @moduledoc """
  Ecto Schema definition for the `memories` table, enforcing strict microsecond precision,
  explicit foreign key mappings, and Elixir atom enums that match database CHECK constraints.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:memory_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "memories" do
    field :memory_status, Ecto.Enum, values: [:ACTIVE, :ARCHIVED, :DELETED]
    field :memory_type, Ecto.Enum, values: [:QUOTE, :REFLECTION, :MOMENT, :SHARED_MEMORY]
    field :door_type, Ecto.Enum, values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]
    field :visibility_type, Ecto.Enum, values: [:PRIVATE, :SHARED], default: :PRIVATE

    field :memory_category, Ecto.Enum,
      values: [:ADVICE, :REFLECTION, :DISCOVERY, :COMFORT, :HUMOR, :CONNECTION, :OTHER]

    field :deletion_reason, Ecto.Enum,
      values: [:PARTICIPANT_REQUEST, :RELATIONSHIP_REMOVED, :PRIVACY_REQUEST, :SYSTEM_RETENTION]

    field :title, :string
    field :memory_content, :string
    field :memory_summary, :string
    field :quoted_text, :string
    field :reflection_text, :string
    field :moment_description, :string
    field :private_notes, :string

    field :atmosphere_id, :binary_id
    field :atmosphere_name, :string
    field :collection_id, :binary_id
    field :collection_name, :string
    field :shared_relationship_id, :binary_id

    field :view_count, :integer, default: 0
    field :revisited_count, :integer, default: 0
    field :memory_significance_score, :decimal
    field :learning_processed, :boolean, default: false
    field :eligible_for_revisit, :boolean, default: true

    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :notes_updated_at, :utc_datetime_usec
    field :last_viewed_at, :utc_datetime_usec
    field :last_revisit_prompt_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :owner_participant, StrangertalksNew.Participant,
      foreign_key: :owner_participant_id,
      references: :participant_id

    belongs_to :conversation, StrangertalksNew.Conversation,
      foreign_key: :conversation_id,
      references: :conversation_id

    belongs_to :match, StrangertalksNew.Matching,
      foreign_key: :match_id,
      references: :match_id

    belongs_to :source_message, StrangertalksNew.Message,
      foreign_key: :source_message_id,
      references: :message_id
  end

  @required_fields [
    :memory_status,
    :owner_participant_id,
    :conversation_id,
    :match_id,
    :memory_type,
    :title,
    :memory_content,
    :door_type,
    :atmosphere_id,
    :atmosphere_name,
    :visibility_type,
    :view_count,
    :revisited_count,
    :memory_significance_score,
    :memory_category,
    :learning_processed,
    :eligible_for_revisit
  ]

  @optional_fields [
    :memory_summary,
    :source_message_id,
    :quoted_text,
    :reflection_text,
    :moment_description,
    :collection_id,
    :collection_name,
    :private_notes,
    :shared_relationship_id,
    :deletion_reason,
    :notes_updated_at,
    :last_viewed_at,
    :last_revisit_prompt_at,
    :deleted_at
  ]

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    # FIXED: Swapped out non-existent :min parameter configuration for Ecto canonical keyword constraints
    |> validate_number(:view_count, greater_than_or_equal_to: 0)
    |> validate_number(:revisited_count, greater_than_or_equal_to: 0)
    |> validate_score_range()
    |> foreign_key_constraint(:owner_participant_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:match_id)
    |> foreign_key_constraint(:source_message_id)
    |> put_manual_timestamps()
  end

  defp validate_score_range(changeset) do
    validate_change(changeset, :memory_significance_score, fn :memory_significance_score, score ->
      if Decimal.compare(score, Decimal.new("0.0")) != :lt and
           Decimal.compare(score, Decimal.new("1.0")) != :gt do
        []
      else
        [memory_significance_score: "must be between 0.0 and 1.0"]
      end
    end)
  end

  defp put_manual_timestamps(changeset) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset
    |> put_change(:created_at, now)
    |> put_change(:updated_at, now)
  end
end
