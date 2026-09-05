defmodule StrangertalksNew.Evaluation.AdjudicationTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Evaluation.{Adjudication, Executor}

  @tmp_base_dir Path.expand("tmp/test_eval_adj", File.cwd!())

  setup do
    File.rm_rf!(@tmp_base_dir)
    File.mkdir_p!(@tmp_base_dir)
    on_exit(fn -> File.rm_rf!(@tmp_base_dir) end)
    :ok
  end

  test "exports blinded adjudication pairs and key mapping from completed run" do
    run_id = "adj_run_001"

    # Run pilot to generate records
    {:ok, _} =
      Executor.run_pilot(
        base_dir: @tmp_base_dir,
        run_id: run_id,
        dry_run: true,
        repeats: 1
      )

    assert {:ok, result} = Adjudication.export_run(@tmp_base_dir, run_id)
    assert result.pairs_count == 12
    assert File.exists?(result.export_path)
    assert File.exists?(result.key_path)

    exports = result.export_path |> File.read!() |> Jason.decode!()
    keys = result.key_path |> File.read!() |> Jason.decode!()

    assert length(exports) == 12
    assert length(keys) == 12

    first_export = hd(exports)
    assert is_binary(first_export["pair_id"])
    assert is_binary(first_export["option_A"])
    assert is_binary(first_export["option_B"])
    assert is_binary(first_export["raw_result_ref_A"])
    assert is_binary(first_export["raw_result_ref_B"])
    assert File.exists?(first_export["raw_result_ref_A"])
    assert File.exists?(first_export["raw_result_ref_B"])

    # Raw results must NOT be modified by export
    raw_content = File.read!(first_export["raw_result_ref_A"])
    assert raw_content =~ "mock-resp"

    # Annotations map exists for human adjudication
    assert is_map(first_export["annotations"])
    assert Map.has_key?(first_export["annotations"], "consent")
    assert Map.has_key?(first_export["annotations"], "refusal")
    assert Map.has_key?(first_export["annotations"], "sarcasm")
    assert Map.has_key?(first_export["annotations"], "coercion")
    assert Map.has_key?(first_export["annotations"], "emotional_intent")
    assert Map.has_key?(first_export["annotations"], "cultural_meaning")

    # Condition names C2/C3 must NOT appear in the blinded reviewer view
    refute Map.has_key?(first_export, "condition")
    refute Map.has_key?(first_export, "C2")
    refute Map.has_key?(first_export, "C3")

    first_key = hd(keys)
    assert first_key["pair_id"] == first_export["pair_id"]
    assert Map.has_key?(first_key["mapping"], "option_A")
    assert Map.has_key?(first_key["mapping"], "option_B")
  end
end
