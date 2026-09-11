defmodule StrangertalksNewWeb.HearthLabControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  setup do
    previous_app = Application.get_env(:strangertalks_new, :experiment_hearth_enabled, :missing)
    previous_system = System.get_env("EXPERIMENT_HEARTH_ENABLED")

    System.delete_env("EXPERIMENT_HEARTH_ENABLED")

    on_exit(fn ->
      case previous_app do
        :missing -> Application.delete_env(:strangertalks_new, :experiment_hearth_enabled)
        value -> Application.put_env(:strangertalks_new, :experiment_hearth_enabled, value)
      end

      case previous_system do
        nil -> System.delete_env("EXPERIMENT_HEARTH_ENABLED")
        value -> System.put_env("EXPERIMENT_HEARTH_ENABLED", value)
      end
    end)

    :ok
  end

  test "GET /lab/hearth is not exposed when the experiment is disabled", %{conn: conn} do
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, false)

    conn = get(conn, "/lab/hearth")

    assert response(conn, 404) == "Not Found"
  end

  test "GET /lab/hearth serves only the isolated lab bundle when explicitly enabled", %{conn: conn} do
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, true)

    conn = get(conn, "/lab/hearth")
    body = html_response(conn, 200)

    assert body =~ "StrangerTalks Hearth Lab"
    assert body =~ "/assets/hearth_lab.mjs"
    assert body =~ "Prototype 1"
  end
end
