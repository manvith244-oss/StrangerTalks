defmodule StrangertalksNew.Hangouts.HangoutSkipVote do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:skip_vote_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hangout_skip_votes" do
    belongs_to :room, StrangertalksNew.Hangouts.HangoutRoom,
      foreign_key: :room_id,
      references: :room_id

    belongs_to :room_content, StrangertalksNew.Hangouts.HangoutRoomContent,
      foreign_key: :room_content_id,
      references: :room_content_id

    belongs_to :membership, StrangertalksNew.Hangouts.HangoutMembership,
      foreign_key: :membership_id,
      references: :membership_id

    field :created_at, :utc_datetime_usec
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:room_id, :room_content_id, :membership_id, :created_at])
    |> validate_required([:room_id, :room_content_id, :membership_id, :created_at])
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:room_content_id)
    |> foreign_key_constraint(:membership_id)
    |> unique_constraint([:room_content_id, :membership_id],
      name: :hangout_skip_votes_content_membership_index
    )
  end
end
