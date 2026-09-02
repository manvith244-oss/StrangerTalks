defmodule StrangertalksNew.Repo do
  use Ecto.Repo,
    otp_app: :strangertalks_new,
    adapter: Ecto.Adapters.Postgres
end
