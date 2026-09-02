defmodule StrangertalksNew.Accounts.PrivateAccount do
  use Ecto.Schema
  @primary_key {:account_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "private_accounts" do
    belongs_to :participant, StrangertalksNew.Participant, references: :participant_id
    field :last_signed_in_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
