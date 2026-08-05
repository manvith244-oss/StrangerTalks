# filepath: lib/strangertalks_new/matching_rules/participant.ex
defmodule StrangertalksNew.MatchingRules.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:participant_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "participants" do
    field :created_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :presence_state, :string, default: "OFFLINE"
    field :current_door, :string, default: nil
    field :bootstrap_sessions_completed, :integer, default: 0
    field :is_bootstrap_frozen, :boolean, default: false
    field :frozen_reentry_count, :integer, default: 0
    field :last_freeze_at, :utc_datetime_usec

    has_many :queue_states, StrangertalksNew.MatchingRules.QueueState,
      foreign_key: :participant_id
  end

  @valid_doors ["JUST_TALK", "KEEP_IT_LIGHT", "EXPLORE", "SOMETHING_REAL"]
  @valid_states [
    "ONLINE",
    "MATCHING",
    "IN_CONVERSATION",
    "VIEWING_MEMORIES",
    "VIEWING_RELATIONSHIPS",
    "OFFLINE"
  ]

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :presence_state,
      :current_door,
      :bootstrap_sessions_completed,
      :is_bootstrap_frozen,
      :frozen_reentry_count,
      :last_freeze_at
    ])
    |> validate_inclusion(:current_door, @valid_doors)
    |> validate_inclusion(:presence_state, @valid_states)
    |> validate_number(:bootstrap_sessions_completed, greater_than_or_equal_to: 0)
    |> validate_number(:frozen_reentry_count, greater_than_or_equal_to: 0)
  end
end
