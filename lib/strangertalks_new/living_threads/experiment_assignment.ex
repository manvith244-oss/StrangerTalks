defmodule StrangertalksNew.LivingThreads.ExperimentAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:CONSEQUENCE_A, :SPECTATOR_A, :CARRIER_B]
  @primary_key {:assignment_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "living_thread_experiment_assignments" do
    belongs_to :participant, StrangertalksNew.Participant,
      foreign_key: :participant_id,
      references: :participant_id

    belongs_to :observed_thread, StrangertalksNew.LivingThreads.LivingThread,
      foreign_key: :observed_thread_id,
      references: :thread_id

    field :role, Ecto.Enum, values: @roles
    field :assigned_at, :utc_datetime_usec
  end

  def roles, do: @roles

  def changeset(assignment, attrs, participant_id) when is_binary(participant_id) do
    assignment
    |> cast(attrs, [:role, :assigned_at, :observed_thread_id])
    |> put_change(:participant_id, participant_id)
    |> validate_required([:participant_id, :role, :assigned_at])
    |> foreign_key_constraint(:participant_id)
    |> foreign_key_constraint(:observed_thread_id)
    |> unique_constraint(:participant_id, name: :living_thread_assignments_participant_index)
    |> unique_constraint(:observed_thread_id,
      name: :living_thread_assignments_observed_thread_index
    )
    |> check_constraint(:role, name: :living_thread_assignments_role_check)
  end
end
