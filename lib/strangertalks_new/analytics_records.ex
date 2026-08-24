defmodule StrangertalksNew.AnalyticsRecords do
  @moduledoc """
  Legacy AnalyticsRecord access.

  V1 no longer permits new rows through this historical wide-score schema. Team 8
  derives current intelligence read-only from canonical domain records instead.
  Existing rows remain readable for migration/forensic compatibility until a
  separately reviewed schema cleanup is approved.
  """

  alias StrangertalksNew.AnalyticsRecord
  alias StrangertalksNew.Repo

  @doc "Legacy writer is deliberately disabled for V1."
  def create_analytics_record(_attrs \\ %{}), do: {:error, :legacy_analytics_record_write_disabled}

  def get_analytics_record(id), do: Repo.get(AnalyticsRecord, id)

  def change_analytics_record(%AnalyticsRecord{} = record, attrs \\ %{}) do
    AnalyticsRecord.changeset(record, attrs)
  end
end
