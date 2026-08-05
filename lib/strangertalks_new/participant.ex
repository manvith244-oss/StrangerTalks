defmodule StrangertalksNew.Participant do
  use Ecto.Schema

  @primary_key {:participant_id, :binary_id, autogenerate: true}
  schema "participants" do
    field :presence_state, Ecto.Enum,
      values: [
        :OFFLINE,
        :ONLINE,
        :MATCHING,
        :IN_CONVERSATION,
        :VIEWING_MEMORIES,
        :VIEWING_RELATIONSHIPS
      ],
      default: :OFFLINE

    field :last_active_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end
end
