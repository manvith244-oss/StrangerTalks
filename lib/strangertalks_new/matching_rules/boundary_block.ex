# filepath: lib/strangertalks_new/matching_rules/boundary_block.ex
defmodule StrangertalksNew.MatchingRules.BoundaryBlock do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "boundary_blocks" do
    belongs_to :blocker, StrangertalksNew.MatchingRules.Participant,
      foreign_key: :blocker_user_id,
      type: :binary_id,
      primary_key: true,
      references: :participant_id

    belongs_to :blocked, StrangertalksNew.MatchingRules.Participant,
      foreign_key: :blocked_user_id,
      type: :binary_id,
      primary_key: true,
      references: :participant_id

    field :created_at, :utc_datetime_usec
    field :timestamp, :utc_datetime_usec
    field :source_surface, :string
    field :active_status, :boolean, default: true
  end

  def changeset(boundary_block, attrs) do
    boundary_block
    |> cast(attrs, [:blocker_user_id, :blocked_user_id, :source_surface, :active_status])
    |> validate_required([:blocker_user_id, :blocked_user_id, :source_surface])
    |> unique_constraint([:blocker_user_id, :blocked_user_id], name: :boundary_blocks_pkey)
  end
end
