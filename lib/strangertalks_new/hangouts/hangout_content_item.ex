defmodule StrangertalksNew.Hangouts.HangoutContentItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:content_id, :string, autogenerate: false}

  schema "hangout_content_items" do
    field :kind, :string
    field :language_tag, :string
    field :source, :string
    field :safety_status, :string
    field :publication_status, :string
    field :body, :string
    field :options, {:array, :string}, default: []
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :content_id,
      :kind,
      :language_tag,
      :source,
      :safety_status,
      :publication_status,
      :body,
      :options,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :content_id,
      :kind,
      :language_tag,
      :source,
      :safety_status,
      :publication_status,
      :body,
      :created_at,
      :updated_at
    ])
    |> validate_length(:content_id, min: 1, max: 128)
    |> validate_length(:language_tag, min: 2, max: 35)
  end
end
