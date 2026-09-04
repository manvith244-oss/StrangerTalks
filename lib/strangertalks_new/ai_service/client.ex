defmodule StrangertalksNew.AIService.Client do
  @moduledoc false

  require Logger

  alias StrangertalksNew.AIService.{CircuitBreaker, Deadline, Error, ResponseValidator, Transport}

  @outer_deadline_ms 17_000

  @type transport_fun ::
          (String.t(), [{String.t(), String.t()}], map(), pos_integer() ->
             {:ok, %{status: non_neg_integer(), body: binary()}}
             | {:error, :timeout | :unavailable | :invalid_body})

  @spec outer_deadline_ms() :: pos_integer()
  def outer_deadline_ms, do: @outer_deadline_ms

  @spec request(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def request(opts) when is_list(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    path = Keyword.fetch!(opts, :path)
    capability = Keyword.fetch!(opts, :capability)
    payload = Keyword.fetch!(opts, :payload)
    service_credential = Keyword.fetch!(opts, :service_credential)
    breaker = Keyword.fetch!(opts, :breaker)
    tracestate = Keyword.get(opts, :tracestate)
    transport = Keyword.get(opts, :transport, &Transport.post/4)

    request_id = Ecto.UUID.generate()
    traceparent = new_traceparent()

    case CircuitBreaker.checkout(breaker) do
      {:error, :open} ->
        {:error, Error.new("AI_CIRCUIT_OPEN", request_id)}

      {:ok, _lease} ->
        headers = request_headers(request_id, service_credential, traceparent, tracestate)
        url = String.trim_trailing(base_url, "/") <> path

        Logger.info(
          "ai_service_request_started request_id=#{request_id} capability=#{capability}"
        )

        result =
          Deadline.run(
            fn -> transport.(url, headers, payload, @outer_deadline_ms) end,
            @outer_deadline_ms
          )
          |> normalize_deadline_result(request_id)

        record_breaker_outcome(breaker, result)

        Logger.info(
          "ai_service_request_finished request_id=#{request_id} capability=#{capability} result=#{result_label(result)}"
        )

        attach_request_id(result, request_id)
    end
  end

  defp normalize_deadline_result({:error, :timeout}, request_id),
    do: {:error, Error.new("AI_SERVICE_TIMEOUT", request_id)}

  defp normalize_deadline_result({:error, {:exit, _reason}}, request_id),
    do: {:error, Error.new("AI_SERVICE_UNAVAILABLE", request_id)}

  defp normalize_deadline_result({:ok, {:error, :timeout}}, request_id),
    do: {:error, Error.new("AI_SERVICE_TIMEOUT", request_id)}

  defp normalize_deadline_result({:ok, {:error, _reason}}, request_id),
    do: {:error, Error.new("AI_SERVICE_UNAVAILABLE", request_id)}

  defp normalize_deadline_result(
         {:ok, {:ok, %{status: status, body: body}}},
         request_id
       ) do
    ResponseValidator.validate(status, body, request_id)
  end

  defp normalize_deadline_result(_other, request_id),
    do: {:error, Error.new("AI_SERVICE_UNAVAILABLE", request_id)}

  defp record_breaker_outcome(breaker, {:ok, _result}),
    do: CircuitBreaker.record_outcome(breaker, :success)

  defp record_breaker_outcome(breaker, {:error, %Error{code: code}}),
    do: CircuitBreaker.record_outcome(breaker, {:error, code})

  defp attach_request_id({:ok, result}, request_id),
    do: {:ok, %{request_id: request_id, result: result}}

  defp attach_request_id({:error, %Error{} = error}, _request_id), do: {:error, error}

  defp request_headers(request_id, service_credential, traceparent, tracestate) do
    base = [
      {"x-st-request-id", request_id},
      {"authorization", "Bearer #{service_credential}"},
      {"traceparent", traceparent}
    ]

    if is_binary(tracestate) and tracestate != "" do
      [{"tracestate", tracestate} | base]
    else
      base
    end
  end

  defp new_traceparent do
    trace_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    parent_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "00-#{trace_id}-#{parent_id}-01"
  end

  defp result_label({:ok, _}), do: "ok"
  defp result_label({:error, %Error{code: code}}), do: code
end
