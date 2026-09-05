defmodule StrangertalksNew.Evaluation.Adjudication do
  @moduledoc """
  Blinded adjudication export tooling for T-A13 evaluation results.

  Pairs C2 and C3 results, randomizes/blinds presentation order (Option A vs Option B),
  and exports adjudication packets with separate unblinding keys.
  """

  alias StrangertalksNew.Evaluation.Store

  def export_run(base_dir, run_id, output_dir \\ nil) do
    run_path = Store.run_dir(base_dir, run_id)
    target_dir = output_dir || Path.join(run_path, "adjudication")
    File.mkdir_p!(target_dir)

    # Read all result records under the run dir
    records = read_run_records(run_path)

    # Pair by {corpus, item_id, repeat_index}
    paired =
      records
      |> Enum.group_by(fn r -> {r["corpus"], r["item_id"], r["repeat_index"]} end)
      |> Enum.filter(fn {_key, group} -> length(group) == 2 end)
      |> Enum.map(fn {{corpus, item_id, repeat_index}, group} ->
        c2 = Enum.find(group, &(&1["condition"] == "C2"))
        c3 = Enum.find(group, &(&1["condition"] == "C3"))

        pair_id = "PAIR-#{corpus}-#{item_id}-R#{repeat_index}"

        # Deterministic blinding based on pair_id
        flip? = :erlang.phash2(pair_id, 2) == 1

        {option_a, option_b, key_map} =
          if flip? do
            {c3["output"], c2["output"], %{"option_A" => "C3", "option_B" => "C2"}}
          else
            {c2["output"], c3["output"], %{"option_A" => "C2", "option_B" => "C3"}}
          end

        raw_ref_a =
          Store.raw_result_path(
            base_dir,
            run_id,
            corpus,
            item_id,
            repeat_index,
            key_map["option_A"]
          )

        raw_ref_b =
          Store.raw_result_path(
            base_dir,
            run_id,
            corpus,
            item_id,
            repeat_index,
            key_map["option_B"]
          )

        language = c2["language"] || c3["language"] || "unknown"

        adjudication_item = %{
          pair_id: pair_id,
          corpus: corpus,
          fixture_id: item_id,
          item_id: item_id,
          language: language,
          repeat_index: repeat_index,
          option_A: option_a,
          option_B: option_b,
          raw_result_ref_A: raw_ref_a,
          raw_result_ref_B: raw_ref_b,
          reviewer_1_judgment: nil,
          reviewer_2_judgment: nil,
          disagreement: false,
          adjudicated_judgment: nil,
          critical_invariant_failure: nil,
          safety_collision_judgment: nil,
          annotations: %{
            "consent" => nil,
            "refusal" => nil,
            "sarcasm" => nil,
            "coercion" => nil,
            "emotional_intent" => nil,
            "cultural_meaning" => nil
          }
        }

        key_item = %{
          pair_id: pair_id,
          corpus: corpus,
          fixture_id: item_id,
          item_id: item_id,
          language: language,
          repeat_index: repeat_index,
          mapping: key_map,
          raw_result_ref_A: raw_ref_a,
          raw_result_ref_B: raw_ref_b
        }

        {adjudication_item, key_item}
      end)

    export_items = Enum.map(paired, fn {adj, _key} -> adj end)
    key_items = Enum.map(paired, fn {_adj, key} -> key end)

    export_path = Path.join(target_dir, "adjudication_export.json")
    key_path = Path.join(target_dir, "adjudication_key.json")

    File.write!(export_path, Jason.encode!(export_items, pretty: true))
    File.write!(key_path, Jason.encode!(key_items, pretty: true))

    {:ok,
     %{
       export_path: export_path,
       key_path: key_path,
       pairs_count: length(export_items)
     }}
  end

  defp read_run_records(run_path) do
    Path.wildcard(Path.join([run_path, "*", "*", "repeat_*_C*.json"]))
    |> Enum.reject(&String.ends_with?(&1, "_raw.json"))
    |> Enum.map(fn path ->
      path |> File.read!() |> Jason.decode!()
    end)
  end
end
