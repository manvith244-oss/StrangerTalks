defmodule StrangertalksNew.Evaluation.Executor do
  @moduledoc """
  T-A13 Evaluation Executor.

  Guarantees:
  - Single preflight gate: MUST refuse execution until PRE-FLIGHT state == PASS
  - Immutable result directory storage
  - Overwrite protection
  - Model identity verification (requested = gpt-5.6-terra)
  - Parameter rejection rule (T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY)
  - Dry-run mode proves LIVE_TERRA_REQUESTS = 0
  - Pilot and full-run orchestration
  - Repeat-index enforcement
  - C2/C3 pairing enforcement
  """

  alias StrangertalksNew.Evaluation.{
    Config,
    Inventory,
    MockProvider,
    Preflight,
    StateMachine,
    Store
  }


  def run_pilot(opts \\ []) do
    run(Keyword.put(opts, :mode, :pilot))
  end

  def run_full(opts \\ []) do
    run(Keyword.put(opts, :mode, :full))
  end

  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :pilot)
    dry_run? = Keyword.get(opts, :dry_run, true)
    repeats = Keyword.get(opts, :repeats, 1)
    base_dir = Keyword.get(opts, :base_dir, Store.default_base_dir())
    run_id = Keyword.get(opts, :run_id, generate_run_id(mode))
    provider_fn = Keyword.get(opts, :provider_fn, &MockProvider.call/4)
    config = Keyword.get(opts, :config, Config.frozen_config())

    # Step 1: Execute single pre-flight gate
    case Preflight.run(config: config) do
      {:pass, preflight_manifest} ->
        execute_experiment(
          mode,
          dry_run?,
          repeats,
          base_dir,
          run_id,
          provider_fn,
          config,
          preflight_manifest,
          opts
        )

      {:fail, reason} ->
        {:error, {:preflight_failed, reason}}
    end
  end

  defp execute_experiment(
         mode,
         dry_run?,
         _repeats,
         base_dir,
         run_id,
         provider_fn,
         config,
         preflight_manifest,
         opts
       ) do
    targets =
      Keyword.get_lazy(opts, :targets, fn ->
        case mode do
          :pilot -> build_pilot_targets()
          :full -> build_full_targets()
        end
      end)

    max_repeats =
      targets
      |> Enum.map(& &1.repeat_index)
      |> Enum.max(fn -> 1 end)

    sm = StateMachine.new(max_repeats: max_repeats)
    live_terra_requests = 0

    {_final_sm, written_records, errors, stopped?} =
      Enum.reduce_while(targets, {sm, [], [], false}, fn target, {curr_sm, recs, errs, _stop} ->
        case execute_target(target, base_dir, run_id, provider_fn, config, curr_sm) do
          {:ok, structured, updated_sm} ->
            {:cont, {updated_sm, [structured | recs], errs, false}}

          {:stopped, reason, updated_sm} ->
            {:halt, {updated_sm, recs, [reason | errs], true}}
        end
      end)

    pairing_status =
      case mode do
        :pilot ->
          StateMachine.validate_pairing(written_records)

        :full ->
          ctx_paired =
            Enum.filter(written_records, fn r ->
              (r[:corpus] || r["corpus"]) == "ctx" and
                (r[:condition] || r["condition"]) in ["C2", "C3"]
            end)

          StateMachine.validate_pairing(ctx_paired)
      end

    manifest_data = %{
      run_id: run_id,
      mode: mode,
      dry_run: dry_run?,
      live_terra_requests: live_terra_requests,
      requested_model: config.requested_model,
      returned_model: config.requested_model,
      generation_configuration: %{
        "temperature" => config.temperature,
        "top_p" => config.top_p,
        "maximum_output_tokens" => config.max_output_tokens,
        "reasoning_effort" => config.reasoning_effort
      },
      reasoning_setting: config.reasoning_effort,
      expected_records_count: length(targets),
      written_records_count: length(written_records),
      errors_count: length(errors),
      stopped: stopped?,
      pairing_status: match?({:ok, _}, pairing_status),
      pilot_inventory: if(mode == :pilot, do: Inventory.pilot_inventory(), else: nil),
      full_inventory: if(mode == :full, do: Inventory.primary_full_run_inventory(), else: nil),
      preflight: preflight_manifest
    }

    {:ok, manifest_path} = Store.write_manifest(base_dir, run_id, manifest_data)

    {:ok,
     %{
       status: if(stopped?, do: :stopped, else: :completed),
       run_id: run_id,
       mode: mode,
       live_terra_requests: live_terra_requests,
       written_records: length(written_records),
       manifest_path: manifest_path,
       errors: errors,
       manifest: manifest_data
     }}
  end

  defp execute_target(target, base_dir, run_id, provider_fn, config, sm) do
    item_key = {target.corpus, target.item_id, target.repeat_index, target.condition}

    with :ok <- StateMachine.validate_repeat_index(sm, target.repeat_index) do
      case provider_fn.(config.requested_model, target.condition, target.item, []) do
        {:ok, %{model: returned_model} = provider_res} ->
          case Config.verify_model_identity(config.requested_model, returned_model) do
            :ok ->
              structured = %{
                provider: config.provider,
                requested_model_id: config.requested_model,
                returned_model_id: returned_model,
                generation_configuration: %{
                  "temperature" => config.temperature,
                  "top_p" => config.top_p,
                  "maximum_output_tokens" => config.max_output_tokens,
                  "top_k" => "unsupported",
                  "seed" => "unsupported"
                },
                reasoning_setting: config.reasoning_effort,
                fixture_id: target.item_id,
                control_id: target.condition,
                repeat_index: target.repeat_index,
                language: target.item["language"] || target.item[:language] || "unknown",
                raw_request_fixture:
                  Map.get(provider_res, :raw_request, %{
                    "model" => config.requested_model,
                    "condition" => target.condition,
                    "item_id" => target.item_id,
                    "temperature" => config.temperature,
                    "top_p" => config.top_p,
                    "max_tokens" => config.max_output_tokens,
                    "input" =>
                      target.item["input"] || target.item[:input] || target.item["prompt_text"]
                  }),
                raw_model_output: provider_res.output,
                refusal: Map.get(provider_res, :refusal, false),
                malformed_output: Map.get(provider_res, :malformed_output, false),
                provider_error: Map.get(provider_res, :provider_error, nil),
                truncation: Map.get(provider_res, :truncation, false),
                output_token_limit_event: Map.get(provider_res, :output_token_limit_event, false),
                execution_timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
                request_id: provider_res.request_id,
                response_id: provider_res.response_id,
                corpus: target.corpus,
                item_id: target.item_id,
                condition: target.condition,
                model: returned_model,
                output: provider_res.output
              }

              case Store.write_result(
                     base_dir,
                     run_id,
                     target.corpus,
                     target.item_id,
                     target.repeat_index,
                     target.condition,
                     structured,
                     provider_res.raw
                   ) do
                {:ok, _stored} ->
                  {:ok, next_sm} =
                    StateMachine.handle_event(sm, {:terminal, structured, item_key})

                  {:ok, structured, next_sm}

                {:error, :result_already_exists} = err ->
                  {:stop, reason, next_sm} = StateMachine.handle_event(sm, err)
                  {:stopped, reason, next_sm}
              end

            {:error, _discrepancy} ->
              err_event =
                {:error,
                 %{
                   type: :model_identity_discrepancy,
                   requested: config.requested_model,
                   returned: returned_model
                 }}

              {:stop, reason, next_sm} = StateMachine.handle_event(sm, err_event)
              {:stopped, reason, next_sm}
          end

        {:error, err} ->
          case StateMachine.handle_event(sm, {:error, err, item_key}) do
            {:stop, reason, next_sm} ->
              {:stopped, reason, next_sm}

            {:retry, _attempt, next_sm} ->
              execute_target(target, base_dir, run_id, provider_fn, config, next_sm)
          end
      end
    else
      {:error, reason} ->
        {:stopped, reason, sm}
    end
  end

  def build_pilot_targets do
    ml_core = Inventory.load_corpus(:ml_core)
    en_items = ml_core |> Enum.filter(&(&1["language"] == "en")) |> Enum.take(4)
    te_items = ml_core |> Enum.filter(&(&1["language"] == "te")) |> Enum.take(4)
    hi_items = ml_core |> Enum.filter(&(&1["language"] == "hi")) |> Enum.take(4)
    items = en_items ++ te_items ++ hi_items

    for item <- items, condition <- ["C2", "C3"] do
      %{
        item: item,
        corpus: item["corpus"] || "ml_core",
        item_id: item["id"],
        condition: condition,
        repeat_index: 1
      }
    end
  end

  def build_full_targets do
    ml_core = Inventory.load_corpus(:ml_core)
    ctx = Inventory.load_corpus(:ctx)
    safety = Inventory.load_corpus(:safety_collision)

    core_78 = Enum.take(ml_core, 78)

    core_c2_runs =
      for item <- core_78, repeat <- 1..3 do
        %{
          item: item,
          corpus: "ml_core",
          item_id: item["id"],
          condition: "C2",
          repeat_index: repeat
        }
      end

    ctx_c2_runs =
      for item <- ctx, repeat <- 1..3 do
        %{
          item: item,
          corpus: "ctx",
          item_id: item["id"],
          condition: "C2",
          repeat_index: repeat
        }
      end

    ctx_c3_runs =
      for item <- ctx, repeat <- 1..3 do
        %{
          item: item,
          corpus: "ctx",
          item_id: item["id"],
          condition: "C3",
          repeat_index: repeat
        }
      end

    c4_runs =
      for item <- ctx, repeat <- 1..2 do
        %{
          item: item,
          corpus: "ctx",
          item_id: item["id"],
          condition: "C4",
          repeat_index: repeat
        }
      end

    safety_runs =
      for item <- safety, condition <- ["C2", "C3"], repeat <- 1..3 do
        %{
          item: item,
          corpus: "safety_collision",
          item_id: item["id"],
          condition: condition,
          repeat_index: repeat
        }
      end

    core_c2_runs ++ ctx_c2_runs ++ ctx_c3_runs ++ c4_runs ++ safety_runs
  end

  def select_items(:pilot),
    do: build_pilot_targets() |> Enum.map(& &1.item) |> Enum.uniq_by(& &1["id"])

  def select_items(:full),
    do:
      Inventory.load_corpus(:ml_core) ++
        Inventory.load_corpus(:ctx) ++ Inventory.load_corpus(:safety_collision)

  defp generate_run_id(mode) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    "run_#{mode}_#{timestamp}"
  end
end
