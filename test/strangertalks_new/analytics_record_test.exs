defmodule StrangertalksNew.AnalyticsRecordTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.{AnalyticsRecord, AnalyticsRecords}

  test "legacy AnalyticsRecord writer is disabled for V1" do
    assert {:error, :legacy_analytics_record_write_disabled} =
             AnalyticsRecords.create_analytics_record(%{
               participant_satisfaction_score: "1.0000",
               trust_score: "1.0000",
               queue_agent_accuracy: "1.0000"
             })
  end

  test "legacy schema remains inspectable without creating new rows" do
    record = %AnalyticsRecord{}
    changeset = AnalyticsRecords.change_analytics_record(record, %{trend_direction: :UP})

    assert %Ecto.Changeset{} = changeset
    assert AnalyticsRecords.get_analytics_record(Ecto.UUID.generate()) == nil
  end
end
