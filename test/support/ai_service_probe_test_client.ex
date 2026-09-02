defmodule StrangertalksNew.AIServiceProbeTestClient do
  @moduledoc false

  alias StrangertalksNew.AIService.Client

  @spec call(keyword()) :: {:ok, map()} | {:error, StrangertalksNew.AIService.Error.t()}
  def call(opts) do
    Client.request(
      base_url: Keyword.fetch!(opts, :base_url),
      path: "/v1/boundary/probe",
      capability: "boundary_probe",
      payload: %{},
      service_credential: Keyword.fetch!(opts, :service_credential),
      breaker: Keyword.fetch!(opts, :breaker),
      tracestate: Keyword.get(opts, :tracestate),
      transport: Keyword.get(opts, :transport, &StrangertalksNew.AIService.Transport.post/4)
    )
  end
end
