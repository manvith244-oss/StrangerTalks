defmodule StrangertalksNew.Hangouts.HangoutMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:membership_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hangout_memberships" do
    belongs_to :room, StrangertalksNew.Hangouts.HangoutRoom,
      foreign_key: :room_id,
      references: :room_id

    belongs_to :participant, StrangertalksNew.Participant,
      foreign_key: :participant_id,
      references: :participant_id

    field :status, Ecto.Enum, values: [:ACTIVE, :DISCONNECTED, :LEFT, :REMOVED], default: :ACTIVE
    field :temporary_identity_slot, :integer
    field :temporary_identity_label, :string
    field :temporary_identity_emoji, :string
    field :joined_at, :utc_datetime_usec
    field :left_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :disconnect_count, :integer, default: 0
  end

  def changeset(membership, attrs, room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    membership
    |> cast(attrs, [
      :status,
      :temporary_identity_slot,
      :temporary_identity_label,
      :temporary_identity_emoji,
      :joined_at,
      :left_at,
      :last_seen_at,
      :disconnect_count
    ])
    |> put_change(:room_id, room_id)
    |> put_change(:participant_id, participant_id)
    |> validate_required([
      :room_id,
      :participant_id,
      :status,
      :temporary_identity_slot,
      :temporary_identity_label,
      :temporary_identity_emoji,
      :joined_at,
      :last_seen_at
    ])
    |> validate_number(:temporary_identity_slot, greater_than_or_equal_to: 0)
    |> validate_number(:disconnect_count, greater_than_or_equal_to: 0)
    |> validate_length(:temporary_identity_label, min: 1, max: 32)
    |> validate_length(:temporary_identity_emoji, min: 1, max: 16)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:participant_id)
    |> unique_constraint([:room_id, :participant_id],
      name: :hangout_memberships_room_participant_index
    )
    |> unique_constraint([:room_id, :temporary_identity_slot],
      name: :hangout_memberships_room_identity_slot_index
    )
    |> unique_constraint(:participant_id,
      name: :hangout_memberships_one_active_room_per_participant_index
    )
  end
end
