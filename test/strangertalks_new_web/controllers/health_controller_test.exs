defmodule StrangertalksNewWeb.HealthControllerTest do
  use StrangertalksNewWeb.ConnCase, async: true

  test "live reports only application-process liveness", %{conn: conn} do
    assert %{"status" => "live"} = conn |> get("/health/live") |> json_response(200)
  end

  test "ready verifies PostgreSQL connectivity without exposing details", %{conn: conn} do
    assert %{"status" => "ready"} = conn |> get("/health/ready") |> json_response(200)
  end

  test "version exposes only safe release identity", %{conn: conn} do
    response = conn |> get("/health/version") |> json_response(200)

    assert %{"status" => "ok", "git_sha" => git_sha} = response
    assert is_binary(git_sha)
    assert Map.keys(response) |> Enum.sort() == ["git_sha", "status"]
  end
end
