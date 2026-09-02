defmodule StrangertalksNew.Repo.Migrations.AddMatchConversationLanguage do
  use Ecto.Migration

  def change do
    alter table(:matches) do
      add :conversation_language, :string, null: true
    end

    create constraint(:matches, :conversation_language_check,
             check: "conversation_language IS NULL OR conversation_language IN ('en','te','hi')"
           )
  end
end
