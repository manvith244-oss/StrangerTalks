defmodule StrangertalksNew.Evaluation.Store do
  @moduledoc """
  Immutable result storage and manifest generation for T-A13 evaluation runs.

  Rules:
  - Strict immutable result directory structure
  - Overwrite protection: NO retry may overwrite an existing result
  - Request/Response ID preservation
  - Immutable raw output storage
  - Per-run provenance manifest
  """

  def default_base_dir do
    Path.join(:code.priv_dir(:strangertalks_new), "evaluation/results")
  rescue
    _ ->
      Path.expand("priv/evaluation/results", File.cwd!())
  end

  def run_dir(base_dir, run_id) do
    base = to_string(base_dir)
    id = to_string(run_id)

    direct_path = Path.join(base, id)
    pilot_path = Path.join([base, "pilot", id])
    full_path = Path.join([base, "full", id])

    cond do
      File.exists?(pilot_path) -> pilot_path
      File.exists?(full_path) -> full_path
      File.exists?(direct_path) -> direct_path
      String.ends_with?(base, "/pilot") or String.ends_with?(base, "\\pilot") -> direct_path
      String.ends_with?(base, "/full") or String.ends_with?(base, "\\full") -> direct_path
      String.starts_with?(id, "pilot") -> pilot_path
      String.starts_with?(id, "full") -> full_path
      true -> direct_path
    end
  end

  def item_dir(base_dir, run_id, corpus, item_id) do
    Path.join([run_dir(base_dir, run_id), to_string(corpus), to_string(item_id)])
  end

  def result_path(base_dir, run_id, corpus, item_id, repeat_index, condition) do
    filename = "repeat_#{repeat_index}_#{condition}.json"
    Path.join(item_dir(base_dir, run_id, corpus, item_id), filename)
  end

  def raw_result_path(base_dir, run_id, corpus, item_id, repeat_index, condition) do
    filename = "repeat_#{repeat_index}_#{condition}_raw.json"
    Path.join(item_dir(base_dir, run_id, corpus, item_id), filename)
  end

  def write_result(
        base_dir,
        run_id,
        corpus,
        item_id,
        repeat_index,
        condition,
        structured_record,
        raw_payload
      ) do
    target_path = result_path(base_dir, run_id, corpus, item_id, repeat_index, condition)
    raw_path = raw_result_path(base_dir, run_id, corpus, item_id, repeat_index, condition)

    if File.exists?(target_path) or File.exists?(raw_path) do
      {:error, :result_already_exists}
    else
      dir = item_dir(base_dir, run_id, corpus, item_id)
      File.mkdir_p!(dir)

      # Ensure request_id and response_id are preserved
      request_id =
        structured_record[:request_id] || structured_record["request_id"] || Ecto.UUID.generate()

      response_id =
        structured_record[:response_id] || structured_record["response_id"] ||
          "resp-#{Ecto.UUID.generate()}"

      augmented_record =
        structured_record
        |> Map.put(:request_id, request_id)
        |> Map.put(:response_id, response_id)
        |> Map.put(:stored_at, DateTime.utc_now() |> DateTime.to_iso8601())

      augmented_raw = %{
        request_id: request_id,
        response_id: response_id,
        corpus: corpus,
        item_id: item_id,
        repeat_index: repeat_index,
        condition: condition,
        raw: raw_payload,
        stored_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(target_path, Jason.encode!(augmented_record, pretty: true))
      File.write!(raw_path, Jason.encode!(augmented_raw, pretty: true))

      {:ok,
       %{
         record_path: target_path,
         raw_path: raw_path,
         request_id: request_id,
         response_id: response_id
       }}
    end
  end

  def write_manifest(base_dir, run_id, manifest_data) do
    dir = run_dir(base_dir, run_id)
    File.mkdir_p!(dir)
    manifest_path = Path.join(dir, "manifest.json")

    manifest =
      Map.merge(manifest_data, %{
        manifest_version: "T-A13-V1",
        run_id: run_id,
        written_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    {:ok, manifest_path}
  end

  def read_manifest(base_dir, run_id) do
    manifest_path = Path.join(run_dir(base_dir, run_id), "manifest.json")

    if File.exists?(manifest_path) do
      {:ok, manifest_path |> File.read!() |> Jason.decode!()}
    else
      {:error, :manifest_not_found}
    end
  end
end
