defmodule StrangertalksNew.AIService.Transport do
  @moduledoc false

  @type response :: %{status: non_neg_integer(), body: binary()}
  @type transport_result :: {:ok, response()} | {:error, :timeout | :unavailable | :invalid_body}

  @spec post(String.t(), [{String.t(), String.t()}], map(), pos_integer()) :: transport_result()
  def post(url, headers, payload, timeout_ms) do
    case Req.post(url,
           headers: headers,
           json: payload,
           retry: false,
           decode_body: false,
           receive_timeout: timeout_ms,
           connect_options: [timeout: min(timeout_ms, 5_000)]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when is_binary(body) ->
        {:ok, %{status: status, body: body}}

      {:ok, %Req.Response{}} ->
        {:error, :invalid_body}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end
end
