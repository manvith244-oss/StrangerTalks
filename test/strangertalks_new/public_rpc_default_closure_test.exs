defmodule StrangertalksNew.PublicRpcDefaultClosureTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Repo

  @api_roles ~w(anon authenticated service_role)

  test "future public functions created by the migration role do not inherit Data API execute authority" do
    current_role = Repo.query!("SELECT current_user").rows |> hd() |> hd()

    execute_grantees =
      Repo.query!(
        """
        SELECT COALESCE(grantee_role.rolname, 'PUBLIC')
        FROM pg_roles AS owner_role
        LEFT JOIN pg_default_acl AS d
          ON d.defaclrole = owner_role.oid
         AND d.defaclnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
         AND d.defaclobjtype = 'f'
        CROSS JOIN LATERAL aclexplode(
          COALESCE(d.defaclacl, acldefault('f', owner_role.oid))
        ) AS acl
        LEFT JOIN pg_roles AS grantee_role ON grantee_role.oid = acl.grantee
        WHERE owner_role.rolname = $1
          AND acl.privilege_type = 'EXECUTE'
        ORDER BY 1
        """,
        [current_role]
      ).rows
      |> List.flatten()

    assert current_role in execute_grantees,
           "migration/application owner must retain EXECUTE on future public functions"

    refute "PUBLIC" in execute_grantees,
           "future public functions must not inherit EXECUTE for PUBLIC"

    for role <- existing_roles(@api_roles) do
      refute role in execute_grantees,
             "future public functions must not inherit EXECUTE for #{role}"
    end
  end

  defp existing_roles(roles) do
    Repo.query!("SELECT rolname FROM pg_roles WHERE rolname = ANY($1::text[])", [roles]).rows
    |> List.flatten()
  end
end
