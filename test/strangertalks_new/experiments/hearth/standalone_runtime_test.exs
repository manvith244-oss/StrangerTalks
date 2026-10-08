defmodule StrangertalksNew.Experiments.Hearth.StandaloneRuntimeTest do
  use ExUnit.Case, async: false

  @application StrangertalksNew.Application
  @runtime StrangertalksNew.Experiments.Hearth.Runtime
  @token StrangertalksNewWeb.HearthToken
  @telemetry_logger StrangertalksNew.Experiments.Hearth.TelemetryLogger
  @standalone_gate StrangertalksNewWeb.HearthStandaloneGate

  setup do
    previous_standalone =
      Application.get_env(:strangertalks_new, :experiment_hearth_standalone, :missing)

    on_exit(fn ->
      case previous_standalone do
        :missing -> Application.delete_env(:strangertalks_new, :experiment_hearth_standalone)
        value -> Application.put_env(:strangertalks_new, :experiment_hearth_standalone, value)
      end
    end)

    :ok
  end

  test "standalone application children exclude Repo and canonical transport" do
    assert function_exported?(@application, :children_for_mode, 1)

    children = apply(@application, :children_for_mode, [:hearth_standalone])
    rendered = inspect(children)

    assert rendered =~ "StrangertalksNewWeb.Endpoint"
    assert rendered =~ "StrangertalksNew.RateLimiter"
    assert rendered =~ "StrangertalksNew.Experiments.Hearth.Supervisor"
    assert rendered =~ "StrangertalksNew.Experiments.Hearth.TelemetryLogger"

    refute rendered =~ "StrangertalksNew.Repo"
    refute rendered =~ "StrangertalksNewWeb.TransportSupervisor"
    refute rendered =~ "ConversationDynamicSupervisor"
    refute rendered =~ "StrangertalksNew.Hangouts"
  end

  test "standalone runtime switch is explicit and defaults off" do
    assert Code.ensure_loaded?(@runtime)
    assert function_exported?(@runtime, :standalone?, 0)

    Application.put_env(:strangertalks_new, :experiment_hearth_standalone, false)
    refute apply(@runtime, :standalone?, [])

    Application.put_env(:strangertalks_new, :experiment_hearth_standalone, true)
    assert apply(@runtime, :standalone?, [])
  end

  test "Hearth token signs and verifies ephemeral authority without Repo lookup" do
    assert Code.ensure_loaded?(@token)
    assert function_exported?(@token, :sign, 2)
    assert function_exported?(@token, :verify_authority, 1)

    participant_id = Ecto.UUID.generate()
    source_fingerprint = :crypto.hash(:sha256, "h01a-source")
    token = apply(@token, :sign, [participant_id, source_fingerprint])

    assert {:ok, %{participant_id: ^participant_id, source_fingerprint: ^source_fingerprint}} =
             apply(@token, :verify_authority, [token])
  end

  test "telemetry exporter accepts only frozen structural fields" do
    assert Code.ensure_loaded?(@telemetry_logger)
    assert function_exported?(@telemetry_logger, :safe_payload, 3)

    secret = "SECRET_H01A_PAYLOAD_90117"

    payload =
      apply(@telemetry_logger, :safe_payload, [
        :experiment_turn,
        %{count: 1, monotonic_time: 123_456},
        %{
          variant: :treatment,
          turn_number: 7,
          participant_id: secret,
          content: secret,
          anchor: secret
        }
      ])

    assert payload == %{
             event: "experiment_turn",
             measurements: %{count: 1},
             metadata: %{variant: "treatment", turn_number: 7}
           }

    refute Jason.encode!(payload) =~ secret
    assert :drop == apply(@telemetry_logger, :safe_payload, [:unknown_event, %{count: 1}, %{}])
  end

  test "standalone HTTP gate exposes only the Hearth lab surface" do
    assert Code.ensure_loaded?(@standalone_gate)
    assert function_exported?(@standalone_gate, :init, 1)
    assert function_exported?(@standalone_gate, :call, 2)

    Application.put_env(:strangertalks_new, :experiment_hearth_standalone, true)
    opts = apply(@standalone_gate, :init, [[]])

    blocked =
      Plug.Test.conn("GET", "/")
      |> apply_gate(opts)

    assert blocked.halted
    assert blocked.status == 404

    allowed_lab =
      Plug.Test.conn("GET", "/lab/hearth")
      |> apply_gate(opts)

    refute allowed_lab.halted

    allowed_identity =
      Plug.Test.conn("POST", "/api/hearth/participants")
      |> apply_gate(opts)

    refute allowed_identity.halted
  end

  test "lab bundle uses standalone identity, standalone socket, and terminal one-shot UX" do
    js = File.read!("priv/static/assets/hearth_lab.mjs")
    html = File.read!("priv/static/hearth_lab.html")

    assert js =~ "/api/hearth/participants"
    assert js =~ "new Socket(\"/hearth_socket\""
    assert js =~ "localStorage"
    assert js =~ "finishAttempt"
    refute js =~ "fetch(\"/api/participants\""
    refute js =~ "new Socket(\"/socket\""

    assert html =~ ~s(id="done-screen")
    refute js =~ "Thanks. The next encounter starts clean."
  end

  defp apply_gate(conn, opts), do: apply(@standalone_gate, :call, [conn, opts])
end
