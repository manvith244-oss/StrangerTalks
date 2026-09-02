defmodule StrangertalksNew.Repo.Migrations.AlterReportSafetyMediaForVideo do
  use Ecto.Migration

  def up do
    drop constraint(:report_safety_media, :byte_size_limit)
    drop constraint(:report_safety_media, :media_type_check)

    create constraint(:report_safety_media, :media_type_check,
             check: "media_type IN ('image/jpeg', 'image/png', 'image/webp', 'video/mp4')"
           )

    create constraint(:report_safety_media, :byte_size_equality,
             check: "byte_size = octet_length(media_bytes)"
           )

    create constraint(:report_safety_media, :byte_size_limit,
             check:
               "(media_type IN ('image/jpeg', 'image/png', 'image/webp') AND octet_length(media_bytes) > 0 AND octet_length(media_bytes) <= 1048576) OR (media_type = 'video/mp4' AND octet_length(media_bytes) > 0 AND octet_length(media_bytes) <= 5242880)"
           )
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM report_safety_media
        WHERE media_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
           OR octet_length(media_bytes) > 1048576
      ) THEN
        RAISE EXCEPTION 'Cannot rollback migration: incompatible video or oversized safety media records exist in report_safety_media';
      END IF;
    END $$;
    """

    drop constraint(:report_safety_media, :byte_size_limit)
    drop constraint(:report_safety_media, :byte_size_equality)
    drop constraint(:report_safety_media, :media_type_check)

    create constraint(:report_safety_media, :byte_size_limit,
             check: "byte_size > 0 AND byte_size <= 1048576"
           )

    create constraint(:report_safety_media, :media_type_check,
             check: "media_type IN ('image/jpeg', 'image/png', 'image/webp')"
           )
  end
end
