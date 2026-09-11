defmodule StrangertalksNewWeb.HearthStandaloneSurfaceTest do
  use StrangertalksNewWeb.ConnCase, async: false

  @token StrangertalksNewWeb.HearthToken

  setup do
    previous_standalone =
      Application.get_env(:strangertalks_new, :experiment_hearth_standalone, :missing)

    previous_enabled = Application.get_env(:strangertalks_new, :experiment_hearth_enabled, :missing)

    on_exit(fn ->
      restore_env(:experiment_hearth_standalone, previous_standalone)
      restore_env(:experiment_hearth_enabled, previous_enabled)
    end)

    :ok
  end

  test "lab participant issuance stays dark outside standalone mode", %{conn: conn} do
    Application.put_env(:strangertalks_new, :experiment_hearth_standalone, false)
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, true)

    conn = post(conn, "/api/hearth/participants", %{})
    assert response(conn, 404) == "Not Found"
  end

  test "standalone enabled mode issues only ephemeral Hearth authority", %{conn: conn} do
    Application.put_env(:strangertalks_new, :experiment_hearth_standalone, true)
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, true)

    conn =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.40")
      |> post("/api/hearth/participants", %{})

    assert %{"participant_id" => participant_id, "token" => token} = json_response(conn, 201)
    assert is_binary(participant_id)
    assert is_binary(token)
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert Code.ensure_loaded?(@token)

    assert {:ok, %{participant_id: ^participant_id, source_fingerprint: source_fingerprint}} =
             apply(@token, :verify_authority, [token])

    assert is_binary(source_fingerprint)
    assert byte_size(source_fingerprint) == 32

    rendered = inspect(json_response(conn, 201))
    refute rendered =~ "203.0.113.40"
    refute rendered =~ Base.encode16(source_fingerprint)
  end

  test "experiment flag still vetoes issuance inside standalone mode", %{conn: conn} do
    Application.put_env(:strangertalks_new, :experiment_hearth_standalone, true)
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, false)

    conn = post(conn, "/api/hearth/participants", %{})
    assert response(conn, 404) == "Not Found"
  end

  defp restore_env(key, :missing), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
