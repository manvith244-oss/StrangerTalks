defmodule StrangertalksNewWeb.ExpressiveDiagnosticPrivacyTest do
  use StrangertalksNewWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  test "Feature 1D successful approved expressive static request retains no product identity diagnostics",
       %{conn: conn} do
    parent = self()
    handler_id = "expressive-static-privacy-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:phoenix, :endpoint, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:endpoint_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    path = "/assets/expressive/bright-spark.svg"
    url = "http://www.example.com#{path}"

    {conn, retained_log} =
      fn -> get(conn, path) end
      |> then(fn request ->
        result = Process.put(:expressive_static_conn, nil)

        log =
          capture_log([level: :info], fn ->
            Process.put(:expressive_static_conn, request.())
          end)

        {Process.get(:expressive_static_conn, result), log}
      end)

    assert response(conn, 200) =~ "<svg"
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/svg+xml"
    refute_receive {:endpoint_telemetry, _, _, _}

    forbidden = ["bright-spark", "bright-spark.svg", path, url, "A bright spark"]
    Enum.each(forbidden, &refute(String.contains?(retained_log, &1)))
    assert retained_log == ""
  end
end
