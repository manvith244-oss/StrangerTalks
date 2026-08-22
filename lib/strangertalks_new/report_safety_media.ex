defmodule StrangertalksNew.ReportSafetyMedia do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:safety_media_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "report_safety_media" do
    field :media_bytes, :binary
    field :media_type, :string
    field :byte_size, :integer
    field :created_at, :utc_datetime_usec

    belongs_to :report, StrangertalksNew.Report,
      foreign_key: :report_id,
      references: :report_id
  end

  def changeset(safety_media, attrs) do
    safety_media
    |> cast(attrs, [:media_bytes, :media_type, :byte_size, :created_at, :report_id])
    |> validate_required([:media_bytes, :media_type, :byte_size, :created_at, :report_id])
    |> validate_inclusion(:media_type, ["image/jpeg", "image/png", "image/webp", "video/mp4"])
    |> validate_media_bounds()
    |> foreign_key_constraint(:report_id)
    |> unique_constraint(:report_id)
  end

  defp validate_media_bounds(changeset) do
    media_bytes = get_field(changeset, :media_bytes)
    byte_size = get_field(changeset, :byte_size)
    media_type = get_field(changeset, :media_type)

    cond do
      is_nil(media_bytes) or is_nil(byte_size) or is_nil(media_type) ->
        changeset

      byte_size != byte_size(media_bytes) ->
        add_error(changeset, :byte_size, "does not match actual media bytes size")

      media_type in ["image/jpeg", "image/png", "image/webp"] and
          (byte_size <= 0 or byte_size > 1_048_576) ->
        add_error(changeset, :byte_size, "must be between 1 and 1048576 bytes for images")

      media_type == "video/mp4" and (byte_size <= 0 or byte_size > 5_242_880) ->
        add_error(changeset, :byte_size, "must be between 1 and 5242880 bytes for video/mp4")

      true ->
        changeset
    end
  end
end
