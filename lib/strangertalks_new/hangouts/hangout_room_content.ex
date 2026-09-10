defmodule StrangertalksNew.Hangouts.HangoutRoomContent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:room_content_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hangout_room_content" do
    belongs_to :room, StrangertalksNew.Hangouts.HangoutRoom,
      foreign_key: :room_id,
      references: :room_id

    belongs_to :content_item, StrangertalksNew.Hangouts.HangoutContentItem,
      foreign_key: :content_id,
      references: :content_id,
      type: :string

    field :sequence, :integer
    field :started_at, :utc_datetime_usec
    field :kind, :string
    field :language_tag, :string
    field :source, :string
    field :safety_status, :string
    field :publication_status, :string
    field :body, :string
    field :options, {:array, :string}, default: []
    field :created_at, :utc_datetime_usec
  end

  def changeset(room_content, attrs) do
    room_content
    |> cast(attrs, [
      :room_id,
      :content_id,
      :sequence,
      :started_at,
      :kind,
      :language_tag,
      :source,
      :safety_status,
      :publication_status,
      :body,
      :options,
      :created_at
    ])
    |> validate_required([
      :room_id,
      :content_id,
      :sequence,
      :started_at,
      :kind,
      :language_tag,
      :source,
      :safety_status,
      :publication_status,
      :body,
      :created_at
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:content_id)
    |> unique_constraint([:room_id, :sequence],
      name: :hangout_room_content_room_sequence_index
    )
  end
end
