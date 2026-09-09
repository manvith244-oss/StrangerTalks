defmodule StrangertalksNew.Hangouts.HangoutMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @max_body_bytes 16_384
  @primary_key {:message_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hangout_messages" do
    belongs_to :room, StrangertalksNew.Hangouts.HangoutRoom,
      foreign_key: :room_id,
      references: :room_id

    belongs_to :membership, StrangertalksNew.Hangouts.HangoutMembership,
      foreign_key: :membership_id,
      references: :membership_id

    field :sequence, :integer
    field :client_message_id, :string
    field :body, :string
    field :created_at, :utc_datetime_usec
  end

  def max_body_bytes, do: @max_body_bytes

  def changeset(message, attrs, room_id, membership_id, sequence)
      when is_binary(room_id) and is_binary(membership_id) and is_integer(sequence) do
    message
    |> cast(attrs, [:client_message_id, :body, :created_at])
    |> put_change(:room_id, room_id)
    |> put_change(:membership_id, membership_id)
    |> put_change(:sequence, sequence)
    |> validate_required([:room_id, :membership_id, :sequence, :client_message_id, :body, :created_at])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:client_message_id, min: 1, max: 128)
    |> validate_body()
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:membership_id)
    |> unique_constraint([:room_id, :sequence], name: :hangout_messages_room_sequence_index)
    |> unique_constraint([:membership_id, :client_message_id],
      name: :hangout_messages_membership_client_message_index
    )
  end

  defp validate_body(changeset) do
    validate_change(changeset, :body, fn :body, body ->
      cond do
        not is_binary(body) -> [body: "is invalid"]
        not String.valid?(body) -> [body: "is invalid"]
        String.trim(body) == "" -> [body: "can't be blank"]
        byte_size(body) > @max_body_bytes -> [body: "is too large"]
        true -> []
      end
    end)
  end
end
