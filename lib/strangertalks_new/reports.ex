defmodule StrangertalksNew.Reports do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Report

  def create_report(attrs \\ %{}) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  def get_report(id) do
    Repo.get(Report, id)
  end

  def change_report(%Report{} = report, attrs \\ %{}) do
    Report.changeset(report, attrs)
  end
end
