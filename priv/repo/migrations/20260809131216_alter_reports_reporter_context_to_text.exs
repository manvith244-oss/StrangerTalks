defmodule StrangertalksNew.Repo.Migrations.AlterReportsReporterContextToText do
  use Ecto.Migration

  def change do
    alter table(:reports) do
      modify :reporter_context, :text, null: true, from: :string
    end
  end
end
