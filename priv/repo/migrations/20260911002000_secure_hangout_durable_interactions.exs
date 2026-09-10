defmodule StrangertalksNew.Repo.Migrations.SecureHangoutDurableInteractions do
  use Ecto.Migration

  @tables ~w(
    hangout_content_items
    hangout_room_content
    hangout_reactions
    hangout_skip_votes
  )

  @api_roles ~w(anon authenticated service_role)

  def up do
    Enum.each(@tables, fn table ->
      execute("ALTER TABLE public.#{table} ENABLE ROW LEVEL SECURITY")

      Enum.each(@api_roles, fn role ->
        execute("""
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
            EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.#{table} FROM #{role}';
          END IF;
        END
        $$;
        """)
      end)
    end)
  end

  def down do
    raise "Hangouts durable-interaction security closure is intentionally irreversible"
  end
end
