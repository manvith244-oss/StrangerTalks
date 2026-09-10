defmodule StrangertalksNew.LivingThreads.PilotEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @event_types [
    :THREAD_SEEN,
    :THREAD_CONTRIBUTED,
    :THREAD_REOPENED,
    :THREAD_RESOLVED,
    :NEW_THREAD_JOINED,
    :KNOWN_PERSON_DEBRIEF
  ]

  @primary_key {:event_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "living_thread_pilot_events" do
    belongs_to :participant, StrangertalksNew.Participant,
      foreign_key: :participant_id,
      references: :participant_id

    belongs_to :thread, StrangertalksNew.LivingThreads.LivingThread,
      foreign_key: :thread_id,
      references: :thread_id

    field :event_type, Ecto.Enum, values: @event_types
    field :metadata, :map, default: %{}
    field :deduplication_key, :string
    field :occurred_at, :utc_datetime_usec
  end

  def changeset(event, attrs, participant_id, thread_id \\ nil)
      when is_binary(participant_id) do
    event
    |> cast(attrs, [:event_type, :metadata, :deduplication_key, :occurred_at])
    |> put_change(:participant_id, participant_id)
    |> put_thread(thread_id)
    |> validate_required([:participant_id, :event_type, :metadata, :occurred_at])
    |> foreign_key_constraint(:participant_id)
    |> foreign_key_constraint(:thread_id)
    |> unique_constraint(:deduplication_key,
      name: :living_thread_pilot_events_deduplication_index
    )
    |> check_constraint(:event_type, name: :living_thread_pilot_event_type_check)
  end

  defp put_thread(changeset, thread_id) when is_binary(thread_id),
    do: put_change(changeset, :thread_id, thread_id)

  defp put_thread(changeset, nil), do: changeset
end
