defmodule StrangertalksNew.LearningRecords do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.LearningRecord

  def create_learning_record(attrs \\ %{}) do
    %LearningRecord{}
    |> LearningRecord.changeset(attrs)
    |> Repo.insert()
  end

  def get_learning_record(id) do
    Repo.get(LearningRecord, id)
  end

  def change_learning_record(%LearningRecord{} = record, attrs \\ %{}) do
    LearningRecord.changeset(record, attrs)
  end
end
