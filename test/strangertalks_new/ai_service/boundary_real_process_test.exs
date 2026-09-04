defmodule StrangertalksNew.AIService.BoundaryRealProcessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias StrangertalksNew.AIService.{CircuitBreaker, Client, Error, Transport}

  @service_credential "boundary-service-secret"

  defp configured? do
    is_binary(System.get_env("ST_AI_REAL_BASE_URL")) and
      is_binary(System.get_env("ST_AI_REAL_CASE"))
  end

  defp call(breaker, opts \\ []) do
    base_url = System.fetch_env!("ST_AI_REAL_BASE_URL")
    credential = Keyword.get(opts, :credential, @service_credential)
    transport = Keyword.get(opts, :transport, &Transport.post/4)

    Client.request(
      base_url: base_url,
      path: "/v1/boundary/probe",
      capability: "boundary_probe",
      payload: %{},
      service_credential: credential,
      breaker: breaker,
      transport: transport
    )
  end

  test "exact-SHA real TCP/Uvicorn boundary case" do
    if configured?() do
      run_case(System.fetch_env!("ST_AI_REAL_CASE"))
    else
      assert true
    end
  end

  defp run_case("success") do
    {:ok, breaker} = CircuitBreaker.start_link()
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:result, call(breaker)})
      end)

    assert_receive {:result,
                    {:ok, %{request_id: request_id, result: %{"value" => "boundary-ok"}}}},
                   20_000

    assert {:ok, ^request_id} = Ecto.UUID.cast(request_id)
    assert log =~ request_id
    refute log =~ @service_credential
    IO.puts("PROOF_REQUEST_ID=#{request_id}")
    Agent.stop(breaker)
  end

  defp run_case("rate_limited") do
    assert_real_error("AI_PROVIDER_RATE_LIMITED", 5_000)
  end

  defp run_case("internal_error") do
    assert_real_error("AI_INTERNAL_ERROR", 5_000)
  end

  defp run_case("provider_timeout") do
    assert_real_error("AI_PROVIDER_TIMEOUT", 17_000, 14_000)
  end

  defp run_case("invalid_json"), do: assert_real_error("AI_MALFORMED_RESPONSE", 5_000)
  defp run_case("wrong_types"), do: assert_real_error("AI_MALFORMED_RESPONSE", 5_000)
  defp run_case("missing_field"), do: assert_real_error("AI_MALFORMED_RESPONSE", 5_000)
  defp run_case("extra_field"), do: assert_real_error("AI_MALFORMED_RESPONSE", 5_000)
  defp run_case("oversized_body"), do: assert_real_error("AI_MALFORMED_RESPONSE", 5_000)

  defp run_case("slow_trickle") do
    assert_real_error("AI_SERVICE_TIMEOUT", 18_500, 16_000)
  end

  defp run_case("wrong_credential") do
    {:ok, breaker} = CircuitBreaker.start_link()

    assert {:error, %Error{code: "AI_AUTH_FAILED", request_id: request_id}} =
             call(breaker, credential: "participant-token-must-not-work")

    assert {:ok, ^request_id} = Ecto.UUID.cast(request_id)
    IO.puts("PROOF_REQUEST_ID=#{request_id}")
    Agent.stop(breaker)
  end

  defp run_case("connection_refused") do
    {:ok, breaker} = CircuitBreaker.start_link()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    transport = fn url, headers, payload, timeout ->
      Agent.update(attempts, &(&1 + 1))
      Transport.post(url, headers, payload, timeout)
    end

    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{code: "AI_SERVICE_UNAVAILABLE"}} = call(breaker, transport: transport)
    elapsed = System.monotonic_time(:millisecond) - started
    assert Agent.get(attempts, & &1) == 1
    assert elapsed < 5_000
    IO.puts("PROOF_TRANSPORT_ATTEMPTS=1")
    Agent.stop(attempts)
    Agent.stop(breaker)
  end

  defp run_case("circuit_open") do
    {:ok, breaker} = CircuitBreaker.start_link()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    for _ <- 1..5 do
      CircuitBreaker.record_outcome(breaker, {:error, "AI_SERVICE_UNAVAILABLE"})
    end

    transport = fn url, headers, payload, timeout ->
      Agent.update(attempts, &(&1 + 1))
      Transport.post(url, headers, payload, timeout)
    end

    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{code: "AI_CIRCUIT_OPEN"}} = call(breaker, transport: transport)
    elapsed = System.monotonic_time(:millisecond) - started
    assert Agent.get(attempts, & &1) == 0
    assert elapsed < 500
    IO.puts("PROOF_TRANSPORT_ATTEMPTS=0")
    Agent.stop(attempts)
    Agent.stop(breaker)
  end

  defp run_case(other), do: flunk("unsupported ST_AI_REAL_CASE=#{inspect(other)}")

  defp assert_real_error(expected_code, max_ms, min_ms \\ 0) do
    {:ok, breaker} = CircuitBreaker.start_link()
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: ^expected_code, request_id: request_id}} = call(breaker)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= min_ms
    assert elapsed < max_ms
    assert {:ok, ^request_id} = Ecto.UUID.cast(request_id)
    IO.puts("PROOF_REQUEST_ID=#{request_id}")
    IO.puts("PROOF_ELAPSED_MS=#{elapsed}")
    Agent.stop(breaker)
  end
end
