defmodule StrangertalksNew.Hangouts.HangoutRoom do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:room_id, :binary_id, autogenerate: true}

  schema "hangout_rooms" do
    field :created_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    field :status, Ecto.Enum, values: [:FORMING, :ACTIVE, :ENDING, :ENDED], default: :FORMING
    field :language_tag, :string

    field :experiment_arm, Ecto.Enum,
      values: [:GROUP_NO_CONTENT, :GROUP_WITH_CONTENT],
      default: :GROUP_WITH_CONTENT

    field :minimum_size, :integer, default: 3
    field :target_size, :integer, default: 4
    field :max_size, :integer, default: 6
    field :message_sequence, :integer, default: 0
    field :content_sequence, :integer, default: 0
    field :current_content_id, :string
    field :current_content_started_at, :utc_datetime_usec
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :created_at,
      :activated_at,
      :ended_at,
      :status,
      :language_tag,
      :experiment_arm,
      :minimum_size,
      :target_size,
      :max_size,
      :message_sequence,
      :content_sequence,
      :current_content_id,
      :current_content_started_at
    ])
    |> validate_required([
      :created_at,
      :status,
      :language_tag,
      :experiment_arm,
      :minimum_size,
      :target_size,
      :max_size
    ])
    |> validate_length(:language_tag, min: 2, max: 35)
    |> validate_format(:language_tag, ~r/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/)
    |> validate_length(:current_content_id, max: 128)
    |> validate_number(:minimum_size, greater_than_or_equal_to: 2, less_than_or_equal_to: 12)
    |> validate_number(:target_size, greater_than_or_equal_to: 2, less_than_or_equal_to: 12)
    |> validate_number(:max_size, greater_than_or_equal_to: 2, less_than_or_equal_to: 12)
    |> validate_number(:message_sequence, greater_than_or_equal_to: 0)
    |> validate_number(:content_sequence, greater_than_or_equal_to: 0)
    |> validate_capacity_order()
  end

  defp validate_capacity_order(changeset) do
    minimum_size = get_field(changeset, :minimum_size)
    target_size = get_field(changeset, :target_size)
    max_size = get_field(changeset, :max_size)

    changeset =
      if is_integer(minimum_size) and is_integer(target_size) and minimum_size > target_size do
        add_error(changeset, :minimum_size, "must be less than or equal to target size")
      else
        changeset
      end

    if is_integer(target_size) and is_integer(max_size) and target_size > max_size do
      add_error(changeset, :target_size, "must be less than or equal to max size")
    else
      changeset
    end
  end
end
