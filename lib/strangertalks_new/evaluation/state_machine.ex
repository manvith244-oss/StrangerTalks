defmodule StrangertalksNew.Evaluation.StateMachine do
  @moduledoc """
  Retry and stop state machine for T-A13 execution.

  Rules:
  - Immediate stop on 429 credit_balance_exhausted
  - Immediate stop on MODEL_IDENTITY_DISCREPANCY
  - Immediate stop on T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY
  - No retry may overwrite an existing result
  - Bounded transient retries (max 3)
  - Repeat-index enforcement
  - C2/C3 pairing enforcement
  """

  @default_max_retries 3
  @default_max_repeats 3

  defstruct status: :idle,
            stop_reason: nil,
            max_retries: @default_max_retries,
            max_repeats: @default_max_repeats,
            attempts: %{},
            records: []

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    %__MODULE__{
      status: :ready,
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      max_repeats: Keyword.get(opts, :max_repeats, @default_max_repeats)
    }
  end

  def validate_repeat_index(target, max_repeats \\ @default_max_repeats)

  def validate_repeat_index(%__MODULE__{} = sm, index) do
    validate_repeat_index(index, sm.max_repeats)
  end

  def validate_repeat_index(index, max_repeats) do
    if is_integer(index) and index in 1..max_repeats do
      :ok
    else
      {:error, "Invalid repeat index #{inspect(index)}. Must be an integer in 1..#{max_repeats}"}
    end
  end

  def handle_event(%__MODULE__{status: :stopped} = sm, _event) do
    {:stop, sm.stop_reason, sm}
  end

  def handle_event(%__MODULE__{} = sm, {:error, %{code: "credit_balance_exhausted"} = err}) do
    new_sm = %{sm | status: :stopped, stop_reason: {:credit_balance_exhausted, err}}
    {:stop, :credit_balance_exhausted, new_sm}
  end

  def handle_event(%__MODULE__{} = sm, {:error, %{type: :model_identity_discrepancy} = err}) do
    new_sm = %{sm | status: :stopped, stop_reason: {:model_identity_discrepancy, err}}
    {:stop, :model_identity_discrepancy, new_sm}
  end

  def handle_event(%__MODULE__{} = sm, {:error, %{type: :configuration_incompatibility} = err}) do
    new_sm = %{sm | status: :stopped, stop_reason: {:config_incompatibility, err}}
    {:stop, :config_incompatibility, new_sm}
  end

  def handle_event(%__MODULE__{} = sm, {:error, :result_already_exists} = err) do
    new_sm = %{sm | status: :stopped, stop_reason: {:result_already_exists, err}}
    {:stop, :result_already_exists, new_sm}
  end

  def handle_event(
        %__MODULE__{} = sm,
        {:error, %{type: :api_error, retryable: true} = err, item_key}
      ) do
    attempt_count = Map.get(sm.attempts, item_key, 0) + 1
    new_attempts = Map.put(sm.attempts, item_key, attempt_count)

    if attempt_count <= sm.max_retries do
      {:retry, attempt_count, %{sm | attempts: new_attempts}}
    else
      new_sm = %{
        sm
        | status: :stopped,
          stop_reason: {:max_retries_exceeded, item_key, err},
          attempts: new_attempts
      }

      {:stop, :max_retries_exceeded, new_sm}
    end
  end

  def handle_event(%__MODULE__{} = sm, {:terminal, result, item_key}) do
    {:ok, %{sm | records: [result | sm.records], attempts: Map.delete(sm.attempts, item_key)}}
  end

  def validate_pairing(records) when is_list(records) do
    grouped =
      Enum.group_by(records, fn r ->
        {r[:corpus] || r["corpus"], r[:item_id] || r["item_id"],
         r[:repeat_index] || r["repeat_index"]}
      end)

    missing =
      Enum.filter(grouped, fn {_key, group} ->
        conditions = Enum.map(group, &(&1[:condition] || &1["condition"])) |> Enum.sort()
        conditions != ["C2", "C3"]
      end)

    if missing == [] do
      {:ok, map_size(grouped)}
    else
      {:error, "C2/C3 pairing incomplete for #{length(missing)} items"}
    end
  end
end
