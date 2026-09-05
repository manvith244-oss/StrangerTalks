defmodule StrangertalksNew.Evaluation.StateMachineTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Evaluation.{Errors, StateMachine}

  test "immediately stops on 429 credit_balance_exhausted" do
    sm = StateMachine.new()
    error_event = {:error, Errors.credit_balance_exhausted()}

    assert {:stop, :credit_balance_exhausted, new_sm} = StateMachine.handle_event(sm, error_event)
    assert new_sm.status == :stopped
  end

  test "immediately stops on MODEL_IDENTITY_DISCREPANCY" do
    sm = StateMachine.new()
    error_event = {:error, Errors.model_identity_discrepancy("gpt-5.6-terra", "gpt-4o")}

    assert {:stop, :model_identity_discrepancy, new_sm} =
             StateMachine.handle_event(sm, error_event)

    assert new_sm.status == :stopped
  end

  test "immediately stops on T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY" do
    sm = StateMachine.new()
    error_event = {:error, Errors.configuration_incompatibility("temperature mismatch")}

    assert {:stop, :config_incompatibility, new_sm} = StateMachine.handle_event(sm, error_event)
    assert new_sm.status == :stopped
  end

  test "immediately stops if result already exists (no overwrite allowed)" do
    sm = StateMachine.new()
    error_event = {:error, :result_already_exists}

    assert {:stop, :result_already_exists, new_sm} = StateMachine.handle_event(sm, error_event)
    assert new_sm.status == :stopped
  end

  test "enforces repeat index bounds" do
    sm = StateMachine.new(max_repeats: 3)

    assert :ok = StateMachine.validate_repeat_index(sm, 1)
    assert :ok = StateMachine.validate_repeat_index(sm, 2)
    assert :ok = StateMachine.validate_repeat_index(sm, 3)

    assert {:error, _} = StateMachine.validate_repeat_index(sm, 0)
    assert {:error, _} = StateMachine.validate_repeat_index(sm, 4)
    assert {:error, _} = StateMachine.validate_repeat_index(sm, "1")
  end

  test "enforces C2 and C3 pairing" do
    paired_records = [
      %{
        "corpus" => "ml_core",
        "item_id" => "ML-CORE-001",
        "repeat_index" => 1,
        "condition" => "C2"
      },
      %{
        "corpus" => "ml_core",
        "item_id" => "ML-CORE-001",
        "repeat_index" => 1,
        "condition" => "C3"
      }
    ]

    assert {:ok, 1} = StateMachine.validate_pairing(paired_records)

    incomplete_records = [
      %{
        "corpus" => "ml_core",
        "item_id" => "ML-CORE-001",
        "repeat_index" => 1,
        "condition" => "C2"
      }
    ]

    assert {:error, reason} = StateMachine.validate_pairing(incomplete_records)
    assert reason =~ "C2/C3 pairing incomplete"
  end
end
