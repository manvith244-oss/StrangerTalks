defmodule StrangertalksNew.Repo.Migrations.CreateReportSafetyMedia do
  use Ecto.Migration

  def change do
    create table(:report_safety_media, primary_key: false) do
      add :safety_media_id, :binary_id, primary_key: true

      add :report_id,
          references(:reports,
            column: :report_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :media_bytes, :binary, null: false
      add :media_type, :string, null: false
      add :byte_size, :integer, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:report_safety_media, [:report_id])

    create constraint(:report_safety_media, :byte_size_limit,
             check: "byte_size > 0 AND byte_size <= 1048576"
           )

    create constraint(:report_safety_media, :media_type_check,
             check: "media_type IN ('image/jpeg', 'image/png', 'image/webp')"
           )
  end
end
