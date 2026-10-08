defmodule StrangertalksNewWeb.AbuseSourceTeam2ETest do
  use ExUnit.Case, async: true

  alias StrangertalksNewWeb.AbuseSource

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  defp request(remote_ip, headers \\ []) do
    initial = %{conn(:get, "/api/participants") | remote_ip: remote_ip}

    Enum.reduce(headers, initial, fn {key, value}, acc ->
      put_req_header(acc, key, value)
    end)
  end

  test "public immediate peer address is authoritative even with forwarded headers" do
    conn =
      request({198, 51, 100, 11}, [
        {"x-forwarded-for", "203.0.113.14"},
        {"x-real-ip", "203.0.113.15"}
      ])

    assert {:ok, {:ip, "198.51.100.11"}} = AbuseSource.from_conn(conn)
  end

  test "private immediate peer accepts different forwarded client identities" do
    first =
      request({10, 0, 0, 9}, [
        {"x-forwarded-for", "203.0.113.19"}
      ])

    second =
      request({10, 0, 0, 9}, [
        {"x-forwarded-for", "203.0.113.20"}
      ])

    # This is isolated evidence of a CONDITIONAL trust boundary: whether an external
    # client can control this header depends on the deployed ingress/proxy topology.
    # It is NOT by itself proof of a live Render bypass.
    assert {:ok, {:ip, "203.0.113.19"}} = AbuseSource.from_conn(first)
    assert {:ok, {:ip, "203.0.113.20"}} = AbuseSource.from_conn(second)
  end

  test "private immediate peer selects rightmost public forwarded hop" do
    forwarded =
      request({192, 168, 1, 22}, [
        {"x-forwarded-for", "203.0.113.19, 198.51.100.25, 10.1.2.3"}
      ])

    assert {:ok, {:ip, "198.51.100.25"}} = AbuseSource.from_conn(forwarded)
  end

  test "malformed forwarded values fall back to observed peer" do
    malformed =
      request({10, 1, 2, 3}, [
        {"x-forwarded-for", "not-an-ip, also-not-an-ip"}
      ])

    assert {:ok, {:ip, "10.1.2.3"}} = AbuseSource.from_conn(malformed)
  end

  test "x-real-ip alone does not change observed source" do
    private_conn = request({10, 1, 2, 3}, [{"x-real-ip", "203.0.113.19"}])
    assert {:ok, {:ip, "10.1.2.3"}} = AbuseSource.from_conn(private_conn)
  end

  test "multiple forwarded headers do not override a directly observed public peer" do
    conn =
      request({198, 51, 100, 5}, [
        {"x-forwarded-for", "203.0.113.9, 10.0.0.1"},
        {"x-forwarded-for", "203.0.113.19"}
      ])

    assert {:ok, {:ip, "198.51.100.5"}} = AbuseSource.from_conn(conn)
  end

  test "private immediate hop currently selects the rightmost public entry across headers" do
    conn =
      request({10, 0, 0, 9}, [
        {"x-forwarded-for", "203.0.113.9, 10.0.0.1"},
        {"x-forwarded-for", "198.51.100.19"}
      ])

    # Characterization only: trust of incoming headers is not proven at Render ingress.
    assert {:ok, {:ip, "198.51.100.19"}} = AbuseSource.from_conn(conn)
  end

  test "IPv4-mapped IPv6 source must normalize to the same IPv4 rate-limit identity" do
    mapped =
      request({10, 0, 0, 9}, [{"x-forwarded-for", "::ffff:203.0.113.21"}])

    native =
      request({10, 0, 0, 9}, [{"x-forwarded-for", "203.0.113.21"}])

    assert AbuseSource.from_conn(mapped) == AbuseSource.from_conn(native)
  end

  test "mapped private IPv4 immediate peer has the same local-hop behavior as native IPv4" do
    native = request({127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.20"}])

    mapped =
      request({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}, [
        {"x-forwarded-for", "203.0.113.20"}
      ])

    assert AbuseSource.from_conn(mapped) == AbuseSource.from_conn(native)
  end

  test "public IPv6 peer is authoritative regardless of forwarded chain" do
    conn =
      request({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}, [
        {"x-forwarded-for", "203.0.113.19"}
      ])

    assert {:ok, {:ip, "2001:db8::1"}} = AbuseSource.from_conn(conn)
  end
end
