defmodule StrangertalksNew.LearningRecordTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.{LearningRecord, LearningRecords}

  test "legacy participant-linked LearningRecord writer is disabled for V1" do
    assert {:error, :legacy_learning_record_write_disabled} =
             LearningRecords.create_learning_record(%{
               record_type: :READINESS_EVALUATION,
               participant_id: Ecto.UUID.generate(),
               readiness_score: "5.0000",
               keystroke_latency_variance: "2.0000"
             })
  end

  test "legacy schema remains inspectable without creating new rows" do
    record = %LearningRecord{}
    changeset = LearningRecords.change_learning_record(record, %{outcome_signal: :ABANDONED})

    assert %Ecto.Changeset{} = changeset
    assert LearningRecords.get_learning_record(Ecto.UUID.generate()) == nil
  end
end
