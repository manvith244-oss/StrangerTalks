defmodule StrangertalksNewWeb.HealthControllerTest do
  use StrangertalksNewWeb.ConnCase, async: true

  test "live reports only application-process liveness", %{conn: conn} do
    assert %{"status" => "live"} = conn |> get("/health/live") |> json_response(200)
  end

  test "ready verifies PostgreSQL connectivity without exposing details", %{conn: conn} do
    assert %{"status" => "ready"} = conn |> get("/health/ready") |> json_response(200)
  end
end
