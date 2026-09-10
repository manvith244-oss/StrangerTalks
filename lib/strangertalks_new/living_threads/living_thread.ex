defmodule StrangertalksNew.LivingThreads.LivingThread do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:thread_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "living_threads" do
    belongs_to :starter_participant, StrangertalksNew.Participant,
      foreign_key: :starter_participant_id,
      references: :participant_id

    belongs_to :carrier_participant, StrangertalksNew.Participant,
      foreign_key: :carrier_participant_id,
      references: :participant_id

    field :status, Ecto.Enum,
      values: [:WAITING_FOR_B, :CONTINUED, :LIQUIDITY_FAILURE, :RESOLVED],
      default: :WAITING_FOR_B

    field :starter_body, :string
    field :continuation_body, :string
    field :opened_at, :utc_datetime_usec
    field :continuation_deadline_at, :utc_datetime_usec
    field :continued_at, :utc_datetime_usec
    field :resolves_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :time_remaining_at_continuation_seconds, :integer
  end

  def opening_changeset(thread, attrs, starter_participant_id)
      when is_binary(starter_participant_id) do
    thread
    |> cast(attrs, [:starter_body, :status, :opened_at, :continuation_deadline_at, :resolves_at])
    |> put_change(:starter_participant_id, starter_participant_id)
    |> validate_required([
      :starter_participant_id,
      :starter_body,
      :status,
      :opened_at,
      :continuation_deadline_at,
      :resolves_at
    ])
    |> validate_length(:starter_body, min: 1, max: 1000, count: :bytes)
    |> foreign_key_constraint(:starter_participant_id)
    |> unique_constraint(:starter_participant_id, name: :living_threads_one_per_starter_index)
    |> check_constraint(:status, name: :living_threads_status_check)
    |> check_constraint(:continuation_deadline_at, name: :living_threads_deadline_order_check)
    |> check_constraint(:starter_body, name: :living_threads_body_size_check)
  end

  def continuation_changeset(thread, attrs, carrier_participant_id)
      when is_binary(carrier_participant_id) do
    thread
    |> cast(attrs, [
      :status,
      :continuation_body,
      :continued_at,
      :time_remaining_at_continuation_seconds
    ])
    |> put_change(:carrier_participant_id, carrier_participant_id)
    |> validate_required([
      :carrier_participant_id,
      :status,
      :continuation_body,
      :continued_at,
      :time_remaining_at_continuation_seconds
    ])
    |> validate_length(:continuation_body, min: 1, max: 1000, count: :bytes)
    |> validate_number(:time_remaining_at_continuation_seconds,
      greater_than_or_equal_to: 0
    )
    |> foreign_key_constraint(:carrier_participant_id)
    |> unique_constraint(:carrier_participant_id, name: :living_threads_one_per_carrier_index)
    |> check_constraint(:carrier_participant_id, name: :living_threads_no_self_carry_check)
    |> check_constraint(:continuation_body, name: :living_threads_body_size_check)
    |> check_constraint(:carrier_participant_id, name: :living_threads_continuation_integrity_check)
  end

  def status_changeset(thread, attrs) do
    thread
    |> cast(attrs, [:status, :resolved_at])
    |> validate_required([:status])
    |> check_constraint(:status, name: :living_threads_status_check)
  end
end
