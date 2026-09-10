defmodule StrangertalksNew.PublicRpcEffectiveAuthorityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Repo

  @api_roles ~w(anon authenticated service_role)
  @probe "public.__strangertalks_rpc_default_probe()"

  test "a newly created public function is executable only by its owner until explicitly granted" do
    Repo.query!("DROP FUNCTION IF EXISTS #{@probe}")
    Repo.query!("CREATE FUNCTION #{@probe} RETURNS integer LANGUAGE sql AS 'SELECT 1'")

    try do
      current_role = Repo.query!("SELECT current_user").rows |> hd() |> hd()

      [[owner_role]] =
        Repo.query!(
          """
          SELECT owner_role.rolname
          FROM pg_proc p
          JOIN pg_roles owner_role ON owner_role.oid = p.proowner
          WHERE p.oid = $1::regprocedure
          """,
          [@probe]
        ).rows

      assert owner_role == current_role,
             "future public-function probe must be owned by the migration/application role"

      assert has_function_execute?(current_role),
             "function owner must retain legitimate EXECUTE authority"

      [[public_execute]] =
        Repo.query!(
          """
          SELECT EXISTS (
            SELECT 1
            FROM pg_proc p
            CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl
            WHERE p.oid = $1::regprocedure
              AND acl.grantee = 0
              AND acl.privilege_type = 'EXECUTE'
          )
          """,
          [@probe]
        ).rows

      refute public_execute,
             "new public functions must not be executable by PUBLIC"

      for role <- existing_roles(@api_roles) do
        refute has_function_execute?(role),
               "new public functions must not be executable by #{role} unless explicitly granted"
      end
    after
      Repo.query!("DROP FUNCTION IF EXISTS #{@probe}")
    end
  end

  defp has_function_execute?(role) do
    [[allowed]] =
      Repo.query!(
        "SELECT has_function_privilege($1::name, $2::text, 'EXECUTE')",
        [role, @probe]
      ).rows

    allowed
  end

  defp existing_roles(roles) do
    Repo.query!("SELECT rolname FROM pg_roles WHERE rolname = ANY($1::text[])", [roles]).rows
    |> List.flatten()
  end
end
