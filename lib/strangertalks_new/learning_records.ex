defmodule StrangertalksNew.LearningRecords do
  @moduledoc """
  Legacy LearningRecord access.

  The historical schema can persist participant-linked readiness and keystroke
  fields that are outside the Team 8 V1 privacy boundary. New V1 writes are
  therefore disabled. Existing rows remain readable for migration/forensic
  compatibility until a separately reviewed schema cleanup is approved.
  """

  alias StrangertalksNew.LearningRecord
  alias StrangertalksNew.Repo

  @doc "Legacy writer is deliberately disabled for V1."
  def create_learning_record(_attrs \\ %{}), do: {:error, :legacy_learning_record_write_disabled}

  def get_learning_record(id), do: Repo.get(LearningRecord, id)

  def change_learning_record(%LearningRecord{} = record, attrs \\ %{}) do
    LearningRecord.changeset(record, attrs)
  end
end
