defmodule StrangertalksNew.AnalyticsRecords do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.AnalyticsRecord

  def create_analytics_record(attrs \\ %{}) do
    %AnalyticsRecord{}
    |> AnalyticsRecord.changeset(attrs)
    |> Repo.insert()
  end

  def get_analytics_record(id) do
    Repo.get(AnalyticsRecord, id)
  end

  def change_analytics_record(%AnalyticsRecord{} = record, attrs \\ %{}) do
    AnalyticsRecord.changeset(record, attrs)
  end
end
