defmodule StrangertalksNew.Repo.Migrations.AddReportMediaOriginTruth do
  use Ecto.Migration

  def up do
    alter table(:reports) do
      add :media_origin, :string
    end

    create constraint(:reports, :reports_media_origin_check,
             check: "media_origin IS NULL OR media_origin IN ('NO_MEDIA', 'MEDIA_ORIGIN')"
           )

    execute("""
    UPDATE reports AS report
    SET media_origin = 'MEDIA_ORIGIN'
    WHERE EXISTS (
      SELECT 1
      FROM report_safety_media AS safety_media
      WHERE safety_media.report_id = report.report_id
    )
    """)
  end

  def down do
    drop constraint(:reports, :reports_media_origin_check)

    alter table(:reports) do
      remove :media_origin
    end
  end
end
