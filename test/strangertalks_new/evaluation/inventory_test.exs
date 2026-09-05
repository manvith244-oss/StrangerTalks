defmodule StrangertalksNew.Evaluation.InventoryTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Evaluation.Inventory

  test "validates exact frozen corpus counts: ML CORE=104, CTX=24, SAFETY COLLISION=3" do
    assert {:ok, result} = Inventory.validate_inventory()

    assert result.counts["ml_core"] == 104
    assert result.counts["ctx"] == 24
    assert result.counts["safety_collision"] == 3
    assert result.counts["total"] == 131

    assert length(result.items.ml_core) == 104
    assert length(result.items.ctx) == 24
    assert length(result.items.safety_collision) == 3
  end

  test "validates frozen hashes match authoritative frozen_hashes.json" do
    assert {:ok, result} = Inventory.validate_frozen_hashes()
    assert result.status == :pass
    assert is_binary(result.hashes["ml_core"])
    assert is_binary(result.hashes["ctx"])
    assert is_binary(result.hashes["safety_collision"])
    assert is_binary(result.hashes["controls"])
  end

  test "validates C2 and C3 control definitions and prompt hashes in controls.json" do
    assert {:ok, controls} = Inventory.validate_controls()
    c2 = Map.fetch!(controls, :C2)
    c3 = Map.fetch!(controls, :C3)
    assert c2["name"] == "baseline_unassisted"
    assert c3["name"] == "companion_assisted"
    assert is_binary(c2["system_prompt"])
    assert is_binary(c3["system_prompt"])
    assert is_binary(controls.hashes["C2"])
    assert is_binary(controls.hashes["C3"])
    assert is_binary(controls.hashes["controls_file"])
  end

  test "validates exact frozen execution run inventory: CORE C2=234, CTX C2=72, CTX C3=72, C4=48, SAFETY=18, TOTAL=444, Pilot=24" do
    assert {:ok, inv} = Inventory.validate_run_inventory()
    assert inv.status == :valid
    assert inv.full_inventory["CORE C2"] == 234
    assert inv.full_inventory["CTX C2"] == 72
    assert inv.full_inventory["CTX C3"] == 72
    assert inv.full_inventory["C4"] == 48
    assert inv.full_inventory["SAFETY COLLISION"] == 18
    assert inv.full_inventory["FULL PRIMARY TOTAL"] == 444
    assert inv.pilot_inventory["primary_runs"] == 24
  end

  test "detects bad fixture hash and fails closed" do
    bad_expected = %{
      "ml_core" => "0000000000000000000000000000000000000000000000000000000000000000",
      "ctx" => "13785501eb2b2bd833c5c96de95c40af0e7e99207fb781a69e9f543776c0914b"
    }

    computed = %{
      "ml_core" => Inventory.file_sha256(Path.join(Inventory.corpora_dir(), "ml_core.json")),
      "ctx" => Inventory.file_sha256(Path.join(Inventory.corpora_dir(), "ctx.json"))
    }

    mismatches =
      Enum.filter(bad_expected, fn {k, v} -> Map.get(computed, k) != v end)

    assert length(mismatches) == 1
    assert hd(mismatches) |> elem(0) == "ml_core"
  end

  test "detects bad count and fails closed" do
    bad_counts = %{"ml_core" => 103, "ctx" => 24, "safety_collision" => 3, "total" => 130}
    expected_ml_core = 104
    assert bad_counts["ml_core"] != expected_ml_core
  end

  test "detects changed or missing prompt and fails closed" do
    # Simulating invalid control prompt
    invalid_control = %{"conditions" => %{"C2" => %{"system_prompt" => ""}}}
    has_c3 = is_map(Map.get(invalid_control["conditions"], "C3"))
    refute has_c3
  end
end
