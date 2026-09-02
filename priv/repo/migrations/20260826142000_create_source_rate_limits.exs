defmodule StrangertalksNew.Repo.Migrations.CreateSourceRateLimits do
  use Ecto.Migration

  def change do
    create table(:source_rate_limits, primary_key: false) do
      add :source_fingerprint, :binary, null: false
      add :bucket, :string, null: false
      add :window_key, :bigint, null: false
      add :count, :integer, null: false
      add :expires_at_ms, :bigint, null: false
    end

    create unique_index(:source_rate_limits, [:source_fingerprint, :bucket, :window_key],
             name: :source_rate_limits_window_unique
           )

    create index(:source_rate_limits, [:expires_at_ms])

    create constraint(:source_rate_limits, :source_rate_limits_count_positive, check: "count > 0")
  end
end
