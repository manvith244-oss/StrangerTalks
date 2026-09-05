defmodule StrangertalksNew.Evaluation.Inventory do
  @moduledoc """
  Validates evaluation fixtures, frozen corpus hashes, and prompt controls for T-A13.

  Enforces frozen corpus counts:
  - ML CORE = 104
  - CTX = 24
  - SAFETY COLLISION = 3
  Total items: 131
  """

  @expected_counts %{
    "ml_core" => 104,
    "ctx" => 24,
    "safety_collision" => 3,
    "total" => 131
  }

  @primary_full_run_inventory %{
    "CORE C2" => 234,
    "CTX C2" => 72,
    "CTX C3" => 72,
    "C4" => 48,
    "SAFETY COLLISION" => 18,
    "FULL PRIMARY TOTAL" => 444
  }

  @pilot_inventory %{
    "primary_runs" => 24
  }

  def primary_full_run_inventory, do: @primary_full_run_inventory
  def pilot_inventory, do: @pilot_inventory

  def validate_run_inventory do
    computed_sum =
      @primary_full_run_inventory["CORE C2"] +
        @primary_full_run_inventory["CTX C2"] +
        @primary_full_run_inventory["CTX C3"] +
        @primary_full_run_inventory["C4"] +
        @primary_full_run_inventory["SAFETY COLLISION"]

    cond do
      computed_sum != @primary_full_run_inventory["FULL PRIMARY TOTAL"] ->
        {:error, "Primary full run sum #{computed_sum} does not match 444"}

      @pilot_inventory["primary_runs"] != 24 ->
        {:error, "Pilot runs count does not match 24"}

      true ->
        {:ok,
         %{
           status: :valid,
           full_inventory: @primary_full_run_inventory,
           pilot_inventory: @pilot_inventory
         }}
    end
  end

  def base_priv_dir do
    Path.join(:code.priv_dir(:strangertalks_new), "evaluation")
  rescue
    _ ->
      Path.expand("priv/evaluation", File.cwd!())
  end

  def corpora_dir, do: Path.join(base_priv_dir(), "corpora")
  def prompts_dir, do: Path.join(base_priv_dir(), "prompts")
  def frozen_hashes_path, do: Path.join(base_priv_dir(), "frozen_hashes.json")

  def load_corpus(name) when name in [:ml_core, "ml_core"] do
    read_json!(Path.join(corpora_dir(), "ml_core.json"))
  end

  def load_corpus(name) when name in [:ctx, "ctx"] do
    read_json!(Path.join(corpora_dir(), "ctx.json"))
  end

  def load_corpus(name) when name in [:safety_collision, "safety_collision"] do
    read_json!(Path.join(corpora_dir(), "safety_collision.json"))
  end

  def load_controls do
    read_json!(Path.join(prompts_dir(), "controls.json"))
  end

  def load_frozen_hashes do
    read_json!(frozen_hashes_path())
  end

  def validate_inventory do
    ml_core = load_corpus(:ml_core)
    ctx = load_corpus(:ctx)
    safety = load_corpus(:safety_collision)

    counts = %{
      "ml_core" => length(ml_core),
      "ctx" => length(ctx),
      "safety_collision" => length(safety),
      "total" => length(ml_core) + length(ctx) + length(safety)
    }

    cond do
      counts["ml_core"] != @expected_counts["ml_core"] ->
        {:error,
         "Corpus count mismatch for ML CORE: expected #{@expected_counts["ml_core"]}, got #{counts["ml_core"]}"}

      counts["ctx"] != @expected_counts["ctx"] ->
        {:error,
         "Corpus count mismatch for CTX: expected #{@expected_counts["ctx"]}, got #{counts["ctx"]}"}

      counts["safety_collision"] != @expected_counts["safety_collision"] ->
        {:error,
         "Corpus count mismatch for SAFETY COLLISION: expected #{@expected_counts["safety_collision"]}, got #{counts["safety_collision"]}"}

      counts["total"] != @expected_counts["total"] ->
        {:error,
         "Total corpus count mismatch: expected #{@expected_counts["total"]}, got #{counts["total"]}"}

      true ->
        {:ok,
         %{
           status: :valid,
           counts: counts,
           items: %{
             ml_core: ml_core,
             ctx: ctx,
             safety_collision: safety
           }
         }}
    end
  end

  def validate_frozen_hashes do
    frozen = load_frozen_hashes()
    expected_hashes = frozen["hashes"]

    computed_hashes = %{
      "ml_core" => file_sha256(Path.join(corpora_dir(), "ml_core.json")),
      "ctx" => file_sha256(Path.join(corpora_dir(), "ctx.json")),
      "safety_collision" => file_sha256(Path.join(corpora_dir(), "safety_collision.json")),
      "controls" => file_sha256(Path.join(prompts_dir(), "controls.json"))
    }

    mismatches =
      Enum.filter(expected_hashes, fn {key, expected_hash} ->
        computed = Map.get(computed_hashes, key)
        computed != expected_hash
      end)

    if mismatches == [] do
      {:ok, %{status: :pass, hashes: computed_hashes}}
    else
      {:error, "Frozen hash mismatch detected for: #{inspect(mismatches)}"}
    end
  end

  def validate_controls do
    controls = load_controls()
    conditions = get_in(controls, ["conditions"]) || %{}

    has_c2 = is_map(Map.get(conditions, "C2"))
    has_c3 = is_map(Map.get(conditions, "C3"))

    c2_prompt = get_in(conditions, ["C2", "system_prompt"])
    c3_prompt = get_in(conditions, ["C3", "system_prompt"])

    cond do
      not has_c2 ->
        {:error, "Missing C2 condition definition in controls.json"}

      not has_c3 ->
        {:error, "Missing C3 condition definition in controls.json"}

      not is_binary(c2_prompt) or String.trim(c2_prompt) == "" ->
        {:error, "Invalid C2 system prompt"}

      not is_binary(c3_prompt) or String.trim(c3_prompt) == "" ->
        {:error, "Invalid C3 system prompt"}

      true ->
        c2_hash = :crypto.hash(:sha256, c2_prompt) |> Base.encode16(case: :lower)
        c3_hash = :crypto.hash(:sha256, c3_prompt) |> Base.encode16(case: :lower)
        file_hash = file_sha256(Path.join(prompts_dir(), "controls.json"))

        {:ok,
         %{
           C2: Map.get(conditions, "C2"),
           C3: Map.get(conditions, "C3"),
           hashes: %{
             "C2" => c2_hash,
             "C3" => c3_hash,
             "controls_file" => file_hash
           }
         }}
    end
  end

  def file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
