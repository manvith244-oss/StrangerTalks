defmodule Mix.Tasks.Strangertalks.Eval do
  use Mix.Task

  @shortdoc "Runs T-A13 evaluation preflight, inventory validation, and dry-run execution"

  @moduledoc """
  T-A13 evaluation operational CLI.

      mix strangertalks.eval preflight
      mix strangertalks.eval inventory
      mix strangertalks.eval dry_run pilot
      mix strangertalks.eval dry_run full
      mix strangertalks.eval export_adjudication RUN_ID
  """

  alias StrangertalksNew.Evaluation.{Adjudication, Executor, Inventory, Preflight, Store}

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["preflight"] ->
        case Preflight.run() do
          {:pass, manifest} ->
            Mix.shell().info("T-A13 PRE-FLIGHT: PASS")
            Mix.shell().info(Jason.encode!(manifest, pretty: true))

          {:fail, reason} ->
            Mix.raise("T-A13 PRE-FLIGHT FAILURE: #{inspect(reason)}")
        end

      ["inventory"] ->
        case Inventory.validate_inventory() do
          {:ok, %{counts: counts}} ->
            {:ok, %{hashes: hashes}} = Inventory.validate_frozen_hashes()
            {:ok, run_inv} = Inventory.validate_run_inventory()
            Mix.shell().info("T-A13 INVENTORY VALID:")
            Mix.shell().info("Corpus counts: #{inspect(counts)}")
            Mix.shell().info("Frozen hashes: #{inspect(hashes)}")
            Mix.shell().info("Primary full-run inventory: #{inspect(run_inv.full_inventory)}")
            Mix.shell().info("Pilot inventory: #{inspect(run_inv.pilot_inventory)}")

          {:error, reason} ->
            Mix.raise("T-A13 INVENTORY FAILURE: #{reason}")
        end

      ["dry_run", "pilot"] ->
        Mix.shell().info("Starting T-A13 dry-run pilot...")

        case Executor.run_pilot(dry_run: true) do
          {:ok, result} ->
            Mix.shell().info("PILOT COMPLETED SUCCESSFULLY")
            Mix.shell().info("LIVE_TERRA_REQUESTS=0")
            Mix.shell().info(Jason.encode!(result.manifest, pretty: true))

          {:error, reason} ->
            Mix.raise("PILOT EXECUTION FAILED: #{inspect(reason)}")
        end

      ["dry_run", "full"] ->
        Mix.shell().info("Starting T-A13 dry-run full run...")

        case Executor.run_full(dry_run: true) do
          {:ok, result} ->
            Mix.shell().info("FULL DRY-RUN COMPLETED SUCCESSFULLY")
            Mix.shell().info("LIVE_TERRA_REQUESTS=0")
            Mix.shell().info(Jason.encode!(result.manifest, pretty: true))

          {:error, reason} ->
            Mix.raise("FULL RUN EXECUTION FAILED: #{inspect(reason)}")
        end

      ["export_adjudication", run_id] ->
        base_dir = Store.default_base_dir()

        case Adjudication.export_run(base_dir, run_id) do
          {:ok, result} ->
            Mix.shell().info("ADJUDICATION EXPORT SUCCESSFUL: #{result.pairs_count} pairs")
            Mix.shell().info("Export: #{result.export_path}")
            Mix.shell().info("Key: #{result.key_path}")

          {:error, reason} ->
            Mix.raise("ADJUDICATION EXPORT FAILED: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("Invalid evaluation task command. See 'mix help strangertalks.eval'")
    end
  end
end
