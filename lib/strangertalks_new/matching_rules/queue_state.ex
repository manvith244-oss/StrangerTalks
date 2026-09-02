# filepath: lib/strangertalks_new/matching_rules/queue_state.ex
defmodule StrangertalksNew.MatchingRules.QueueState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:queue_state_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "queue_states" do
    belongs_to :participant, StrangertalksNew.MatchingRules.Participant,
      foreign_key: :participant_id,
      type: :binary_id,
      references: :participant_id

    field :readiness_snapshot_at, :utc_datetime_usec
    field :intent_vibe_vector, :map
    field :wait_duration_seconds, :integer, default: 0
    field :matched_strategy_applied, :string
  end

  @valid_strategies ["BOOTSTRAP", "COMPATIBILITY", "OPPORTUNITY", "SCARCITY", "MANUAL_OVERRIDE"]

  def changeset(queue_state, attrs) do
    queue_state
    |> cast(attrs, [
      :participant_id,
      :intent_vibe_vector,
      :wait_duration_seconds,
      :matched_strategy_applied
    ])
    |> validate_required([:participant_id, :intent_vibe_vector, :matched_strategy_applied])
    |> validate_inclusion(:matched_strategy_applied, @valid_strategies)
    |> validate_number(:wait_duration_seconds, greater_than_or_equal_to: 0)
    # FIXED: Map the raw PostgreSQL check constraint into a clean Ecto error tuple
    |> check_constraint(:matched_strategy_applied, name: :chk_match_strategy)
  end
end
