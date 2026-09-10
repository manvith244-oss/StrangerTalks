defmodule StrangertalksNew.Repo.Migrations.AddHangoutCurrentContentId do
  use Ecto.Migration

  def change do
    alter table(:hangout_rooms) do
      add :current_content_id, :string
    end
  end
end
