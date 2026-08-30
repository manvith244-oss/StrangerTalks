defmodule StrangertalksNew.AIService.BoundaryContractTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias StrangertalksNew.AIService.{CircuitBreaker, Client, Error, ResponseValidator}

  defp clock_breaker do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, breaker} = CircuitBreaker.start_link(clock: fn -> Agent.get(clock, & &1) end)
    {clock, breaker}
  end

  defp request(breaker, transport) do
    Client.request(
      base_url: "http://127.0.0.1:1",
      path: "/v1/boundary/probe",
      capability: "boundary_probe",
      payload: %{},
      service_credential: "boundary-service-secret",
      breaker: breaker,
      transport: transport
    )
  end

  defp envelope_from_headers(headers, status, code) do
    request_id = headers |> Map.new() |> Map.fetch!("x-st-request-id")

    body =
      if status == 200 do
        %{
          "request_id" => request_id,
          "status" => "ok",
          "result" => %{"value" => "boundary-ok"},
          "error_code" => nil,
          "error_message" => nil
        }
      else
        %{
          "request_id" => request_id,
          "status" => "error",
          "result" => nil,
          "error_code" => code,
          "error_message" => "sanitized"
        }
      end

    Jason.encode!(body)
  end

  test "frozen timeout and breaker constants are exact" do
    assert Client.outer_deadline_ms() == 17_000
    assert CircuitBreaker.failure_threshold() == 5
    assert CircuitBreaker.open_interval_ms() == 30_000
  end

  test "five consecutive eligible failures open the circuit and OPEN admits zero work" do
    {:ok, breaker} = CircuitBreaker.start_link()
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)

    for _ <- 1..5 do
      assert :ok = CircuitBreaker.record_outcome(breaker, {:error, "AI_SERVICE_UNAVAILABLE"})
    end

    assert %{mode: :open, failures: 5, probe_in_flight: false} = CircuitBreaker.snapshot(breaker)
    assert {:error, :open} = CircuitBreaker.checkout(breaker)
  end

  test "noneligible errors do not accumulate toward opening" do
    {:ok, breaker} = CircuitBreaker.start_link()
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)

    for _ <- 1..4 do
      CircuitBreaker.record_outcome(breaker, {:error, "AI_SERVICE_TIMEOUT"})
    end

    CircuitBreaker.record_outcome(breaker, {:error, "AI_PROVIDER_RATE_LIMITED"})
    assert %{mode: :closed, failures: 0} = CircuitBreaker.snapshot(breaker)
  end

  test "after 30 seconds concurrent HALF-OPEN checkouts admit exactly one probe" do
    {clock, breaker} = clock_breaker()
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    for _ <- 1..5 do
      CircuitBreaker.record_outcome(breaker, {:error, "AI_INTERNAL_ERROR"})
    end

    Agent.update(clock, fn _ -> 30_000 end)

    outcomes =
      1..20
      |> Task.async_stream(fn _ -> CircuitBreaker.checkout(breaker) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(outcomes, &(&1 == {:ok, :half_open})) == 1
    assert Enum.count(outcomes, &(&1 == {:error, :open})) == 19
  end

  test "HALF-OPEN eligible failure reopens with a fresh interval" do
    {clock, breaker} = clock_breaker()
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    for _ <- 1..5, do: CircuitBreaker.record_outcome(breaker, {:error, "AI_INTERNAL_ERROR"})
    Agent.update(clock, fn _ -> 30_000 end)
    assert {:ok, :half_open} = CircuitBreaker.checkout(breaker)
    CircuitBreaker.record_outcome(breaker, {:error, "AI_SERVICE_TIMEOUT"})
    assert %{mode: :open, opened_at_ms: 30_000} = CircuitBreaker.snapshot(breaker)
    assert {:error, :open} = CircuitBreaker.checkout(breaker)
  end

  test "HALF-OPEN noneligible error closes while preserving the caller error semantics" do
    {clock, breaker} = clock_breaker()
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    for _ <- 1..5, do: CircuitBreaker.record_outcome(breaker, {:error, "AI_INTERNAL_ERROR"})
    Agent.update(clock, fn _ -> 30_000 end)
    assert {:ok, :half_open} = CircuitBreaker.checkout(breaker)
    CircuitBreaker.record_outcome(breaker, {:error, "AI_PROVIDER_RATE_LIMITED"})
    assert %{mode: :closed, failures: 0, probe_in_flight: false} = CircuitBreaker.snapshot(breaker)
  end

  test "HALF-OPEN success closes" do
    {clock, breaker} = clock_breaker()
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    for _ <- 1..5, do: CircuitBreaker.record_outcome(breaker, {:error, "AI_INTERNAL_ERROR"})
    Agent.update(clock, fn _ -> 30_000 end)
    assert {:ok, :half_open} = CircuitBreaker.checkout(breaker)
    CircuitBreaker.record_outcome(breaker, :success)
    assert %{mode: :closed, failures: 0, probe_in_flight: false} = CircuitBreaker.snapshot(breaker)
  end

  test "client sends one attempt, strict empty payload, fresh correlation headers, and no credential in logs" do
    {:ok, breaker} = CircuitBreaker.start_link()
    {:ok, attempts} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(attempts), do: Agent.stop(attempts) end)

    transport = fn url, headers, payload, timeout ->
      Agent.update(attempts, &[{url, headers, payload, timeout} | &1])
      {:ok, %{status: 200, body: envelope_from_headers(headers, 200, nil)}}
    end

    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:client_result, request(breaker, transport)})
      end)

    assert_receive {:client_result, {:ok, %{request_id: request_id, result: %{"value" => "boundary-ok"}}}}
    assert {:ok, ^request_id} = Ecto.UUID.cast(request_id)
    assert log =~ request_id
    refute log =~ "boundary-service-secret"

    assert [{"http://127.0.0.1:1/v1/boundary/probe", headers, %{}, 17_000}] = Agent.get(attempts, & &1)
    header_map = Map.new(headers)
    assert header_map["x-st-request-id"] == request_id
    assert header_map["authorization"] == "Bearer boundary-service-secret"
    assert header_map["traceparent"] =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/
  end

  test "timeout, 429, and 5xx each perform exactly one client transport attempt" do
    cases = [
      {:timeout, nil, nil, "AI_SERVICE_TIMEOUT"},
      {:response, 429, "AI_PROVIDER_RATE_LIMITED", "AI_PROVIDER_RATE_LIMITED"},
      {:response, 500, "AI_INTERNAL_ERROR", "AI_INTERNAL_ERROR"}
    ]

    for {kind, status, response_code, expected_code} <- cases do
      {:ok, breaker} = CircuitBreaker.start_link()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _url, headers, _payload, _timeout ->
        Agent.update(attempts, &(&1 + 1))

        case kind do
          :timeout -> {:error, :timeout}
          :response -> {:ok, %{status: status, body: envelope_from_headers(headers, status, response_code)}}
        end
      end

      assert {:error, %Error{code: ^expected_code}} = request(breaker, transport)
      assert Agent.get(attempts, & &1) == 1
      Agent.stop(attempts)
      Agent.stop(breaker)
    end
  end

  test "connection-unavailable performs one attempt and maps to AI_SERVICE_UNAVAILABLE" do
    {:ok, breaker} = CircuitBreaker.start_link()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(attempts), do: Agent.stop(attempts) end)

    transport = fn _url, _headers, _payload, _timeout ->
      Agent.update(attempts, &(&1 + 1))
      {:error, :unavailable}
    end

    assert {:error, %Error{code: "AI_SERVICE_UNAVAILABLE"}} = request(breaker, transport)
    assert Agent.get(attempts, & &1) == 1
  end

  test "OPEN client circuit returns immediately with zero transport attempts" do
    {:ok, breaker} = CircuitBreaker.start_link()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    on_exit(fn -> if Process.alive?(attempts), do: Agent.stop(attempts) end)

    for _ <- 1..5, do: CircuitBreaker.record_outcome(breaker, {:error, "AI_SERVICE_UNAVAILABLE"})

    transport = fn _url, _headers, _payload, _timeout ->
      Agent.update(attempts, &(&1 + 1))
      {:error, :unavailable}
    end

    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{code: "AI_CIRCUIT_OPEN"}} = request(breaker, transport)
    elapsed = System.monotonic_time(:millisecond) - started
    assert Agent.get(attempts, & &1) == 0
    assert elapsed < 500
  end

  test "validator rejects every frozen malformed response family" do
    request_id = Ecto.UUID.generate()

    valid = %{
      "request_id" => request_id,
      "status" => "ok",
      "result" => %{"value" => "boundary-ok"},
      "error_code" => nil,
      "error_message" => nil
    }

    malformed = [
      {200, "{"},
      {200, Jason.encode!(Map.put(valid, "request_id", 123))},
      {200, Jason.encode!(Map.delete(valid, "error_message"))},
      {200, Jason.encode!(Map.put(valid, "extra", true))},
      {200, Jason.encode!(Map.put(valid, "version", "v2"))},
      {200, Jason.encode!(Map.put(valid, "result", %{"value" => String.duplicate("x", 70_000)}))}
    ]

    for {status, body} <- malformed do
      assert {:error, %Error{code: "AI_MALFORMED_RESPONSE"}} =
               ResponseValidator.validate(status, body, request_id)
    end
  end
end

defmodule StrangertalksNew.AIService.HealthIndependenceTest do
  use StrangertalksNewWeb.ConnCase, async: false

  test "Elixir readiness remains Postgres-only with no Python service involved", %{conn: conn} do
    conn = get(conn, "/health/ready")
    assert json_response(conn, 200) == %{"status" => "ready"}

    children = Supervisor.which_children(StrangertalksNew.Supervisor)
    refute Enum.any?(children, fn {id, _pid, _type, modules} ->
             inspect(id) =~ "AIService" or inspect(modules) =~ "AIService"
           end)
  end
end
