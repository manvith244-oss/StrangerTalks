defmodule StrangertalksNew.Evaluation.Preflight do
  @moduledoc """
  Single pre-flight gate for T-A13 Multilingual Evaluation.

  Strict rule:
  The executor MUST refuse corpus execution until PRE-FLIGHT state == PASS.
  """

  alias StrangertalksNew.Evaluation.{Config, Inventory}

  def run(opts \\ []) do
    config = Keyword.get(opts, :config, Config.frozen_config())

    with {:ok, config} <- Config.validate_config(config),
         {:ok, inventory} <- Inventory.validate_inventory(),
         {:ok, hash_check} <- Inventory.validate_frozen_hashes(),
         {:ok, controls} <- Inventory.validate_controls() do
      manifest = %{
        protocol: "T-A13-V1",
        preflight_state: "PASS",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        provider_state: "WAITING_ON_AUTHORIZED_TERRA_EXECUTION_SURFACE",
        live_terra_requests: 0,
        config: Map.from_struct(config),
        corpus_counts: inventory.counts,
        frozen_hashes: hash_check.hashes,
        controls: Map.keys(controls)
      }

      {:pass, manifest}
    else
      {:error, reason} ->
        {:fail, reason}
    end
  end

  def run!(opts \\ []) do
    case run(opts) do
      {:pass, manifest} -> manifest
      {:fail, reason} -> raise "T-A13 PRE-FLIGHT FAILURE: #{inspect(reason)}"
    end
  end
end
