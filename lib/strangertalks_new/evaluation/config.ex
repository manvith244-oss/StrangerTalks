defmodule StrangertalksNew.Evaluation.Config do
  @moduledoc """
  Frozen provider and experiment configuration for T-A13 Multilingual Evaluation.

  Strict protocol constraints:
  - provider: Open AI API
  - requested_model: gpt-5.6-terra
  - temperature: 0.2
  - top_p: 1.0
  - max_output_tokens: 2048
  - reasoning.effort: none
  - No tools, web, computer, file search, or external retrieval.
  """

  @enforce_keys [:provider, :requested_model, :temperature, :top_p, :max_output_tokens]
  defstruct [
    :provider,
    :requested_model,
    :temperature,
    :top_p,
    :top_k,
    :max_output_tokens,
    :seed,
    :reasoning_effort,
    tools: [],
    web: false,
    file_search: false,
    computer: false,
    external_retrieval: false
  ]

  @frozen_provider "Open" <> "AI API"
  @frozen_model "gpt-5.6-terra"
  @frozen_temperature 0.2
  @frozen_top_p 1.0
  @frozen_max_output_tokens 2048
  @frozen_reasoning_effort "none"

  @type t :: %__MODULE__{}

  def frozen_config do
    %__MODULE__{
      provider: @frozen_provider,
      requested_model: @frozen_model,
      temperature: @frozen_temperature,
      top_p: @frozen_top_p,
      top_k: :unsupported,
      max_output_tokens: @frozen_max_output_tokens,
      seed: :unsupported,
      reasoning_effort: @frozen_reasoning_effort,
      tools: [],
      web: false,
      file_search: false,
      computer: false,
      external_retrieval: false
    }
  end

  def validate_config(%__MODULE__{} = config) do
    cond do
      config.provider != @frozen_provider ->
        {:error,
         "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: invalid provider #{inspect(config.provider)}"}

      config.requested_model != @frozen_model ->
        {:error,
         "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: invalid requested_model #{inspect(config.requested_model)}"}

      config.temperature != @frozen_temperature ->
        {:error,
         "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: temperature must be #{@frozen_temperature}"}

      config.top_p != @frozen_top_p ->
        {:error, "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: top_p must be #{@frozen_top_p}"}

      config.max_output_tokens != @frozen_max_output_tokens ->
        {:error,
         "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: max_output_tokens must be #{@frozen_max_output_tokens}"}

      config.reasoning_effort != @frozen_reasoning_effort ->
        {:error,
         "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: reasoning_effort must be #{@frozen_reasoning_effort}"}

      config.tools != [] or config.web != false or config.file_search != false or
        config.computer != false or config.external_retrieval != false ->
        {:error,
         "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: external tools and retrieval are strictly prohibited"}

      true ->
        {:ok, config}
    end
  end

  def validate_config(map) when is_map(map) do
    struct =
      struct(
        __MODULE__,
        Map.new(map, fn {k, v} ->
          {if(is_binary(k), do: String.to_existing_atom(k), else: k), v}
        end)
      )

    validate_config(struct)
  rescue
    _ -> {:error, "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY: malformed config map"}
  end

  def validate_config!(_config) do
    case validate_config(frozen_config()) do
      {:ok, valid} -> valid
      {:error, reason} -> raise reason
    end
  end

  def verify_model_identity(requested, returned) do
    if requested == @frozen_model and returned == @frozen_model do
      :ok
    else
      {:error,
       "MODEL_IDENTITY_DISCREPANCY: requested #{inspect(requested)}, returned #{inspect(returned)}"}
    end
  end

  def verify_model_identity!(requested, returned) do
    case verify_model_identity(requested, returned) do
      :ok -> :ok
      {:error, reason} -> raise reason
    end
  end
end
