defmodule StrangertalksNew.Telemetry do
  @moduledoc """
  StrangerTalks Telemetry & Observability Foundation.

  ## Canonical Namespace
  All custom domain events are emitted under the prefix:
  `[:strangertalks_new, <domain>, <operation>, ...]`

  ## Event Structure
  - Spans:
    - `[:strangertalks_new, <domain>, <operation>, :start]`
    - `[:strangertalks_new, <domain>, <operation>, :stop]`
    - `[:strangertalks_new, <domain>, <operation>, :exception]`
  - Instantaneous Events:
    - `[:strangertalks_new, <domain>, <event>]`

  ## Measurements
  Numeric values suitable for aggregation:
  - `duration` (monotonic native/millisecond time)
  - `count` (integer)
  - `queue_length`, `bytes`, `memory`

  ## Metadata & Low-Cardinality Rules
  Metadata must be bounded and low-cardinality for safe aggregation:
  - Allowed: `:result` (`:success | :failure`), `:reason_code` (DomainError codes), `:door_type`, `:conversation_status`, `:sync_status`
  - Prohibited as metric tags: `:participant_id`, `:conversation_id`, `:client_message_id`, `:voice_note_id`, `:epoch_id`, PIDs, IP addresses

  ## Privacy Invariants (Absolute Ban)
  Telemetry measurements and metadata must NEVER contain:
  - Message text / conversation content
  - Voice-note audio, binaries, or transcripts
  - Typing content or free-text inputs
  - Authentication tokens, passwords, cookies, session secrets
  """

  require Logger

  @banned_metadata_keys MapSet.new([
                          :content,
                          :text,
                          :message,
                          :body,
                          :binary,
                          :audio,
                          :token,
                          :password,
                          :secret,
                          :authorization,
                          :bearer,
                          :cookie,
                          :session,
                          :csrf_token,
                          :params,
                          :cast_params,
                          :assigns,
                          :socket,
                          :user_agent,
                          :ip,
                          :ip_address,
                          :participant_id,
                          :conversation_id,
                          :match_id,
                          :message_id,
                          :client_message_id,
                          :reply_to_client_message_id,
                          :reply_snippet,
                          :reply_author_relation,
                          :quoted_text,
                          :snippet,
                          :voice_note_id,
                          :epoch_id,
                          :target_client_message_id,
                          :desired_reaction,
                          :reaction,
                          :reaction_code,
                          :code,
                          :emoji,
                          :desired_emoji,
                          :revision,
                          :expected_reaction_revision,
                          :self_reaction,
                          :peer_reaction,
                          :pid,
                          :process,
                          :process_id
                        ])

  @banned_metadata_key_names MapSet.new(Enum.map(@banned_metadata_keys, &Atom.to_string/1))

  @doc """
  Safely emits a telemetry event under the `[:strangertalks_new | event_suffix]` prefix.
  Sanitizes metadata to prevent sensitive or high-cardinality payload leakage.
  Never raises on handler failure.
  """
  def execute(event_suffix, measurements \\ %{}, metadata \\ %{}) when is_list(event_suffix) do
    event_name = [:strangertalks_new | event_suffix]
    sanitized_measurements = sanitize_measurements(measurements)
    sanitized_metadata = sanitize_metadata(metadata)

    try do
      :telemetry.execute(event_name, sanitized_measurements, sanitized_metadata)
    rescue
      _error ->
        Logger.warning("Telemetry execution failed", operation: :telemetry_execute)
        :ok
    end
  end

  @doc """
  Emits a failure event with the canonical bounded DomainError code for the reason.
  """
  def failure(event_suffix, reason, metadata \\ %{})
      when is_list(event_suffix) and is_map(metadata) do
    reason_code = StrangertalksNew.DomainError.from_error(reason).code
    execute(event_suffix, %{count: 1}, Map.put(metadata, :reason_code, reason_code))
  end

  @doc """
  Executes a block within a telemetry span (`:start`, `:stop`, `:exception`).
  Measures duration in monotonic native time.
  """
  def span(event_suffix, start_metadata \\ %{}, work_fun)
      when is_list(event_suffix) and is_function(work_fun, 0) do
    start_time = System.monotonic_time()
    execute(event_suffix ++ [:start], %{system_time: System.system_time()}, start_metadata)

    try do
      result = work_fun.()
      duration = System.monotonic_time() - start_time
      execute(event_suffix ++ [:stop], %{duration: duration}, start_metadata)
      result
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        execute(
          event_suffix ++ [:exception],
          %{duration: duration},
          Map.put(start_metadata, :kind, kind)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Filters metadata to strip known banned/PII keys and preserve bounded context.
  """
  def sanitize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      if sensitive_metadata_key?(key) do
        acc
      else
        Map.put(acc, key, sanitize_value(key, value))
      end
    end)
  end

  def sanitize_metadata(_), do: %{}

  defp sanitize_measurements(measurements) when is_map(measurements) do
    Enum.reduce(measurements, %{}, fn {key, value}, acc ->
      if is_number(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp sanitize_measurements(_), do: %{count: 1}

  defp sanitize_value(_key, val) when is_atom(val) or is_boolean(val) or is_number(val), do: val

  defp sanitize_value(:reason_code, val) when is_binary(val) do
    if StrangertalksNew.DomainError.canonical_code?(val), do: val, else: :redacted
  end

  defp sanitize_value(_key, _val), do: :redacted

  defp sensitive_metadata_key?(key) when is_atom(key) or is_binary(key) do
    normalized_key =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    MapSet.member?(@banned_metadata_keys, key) or
      MapSet.member?(@banned_metadata_key_names, normalized_key) or
      String.ends_with?(normalized_key, "_id") or
      String.contains?(normalized_key, "token") or
      String.contains?(normalized_key, "secret") or
      String.contains?(normalized_key, "password") or
      String.contains?(normalized_key, "cookie")
  end

  defp sensitive_metadata_key?(_key), do: true
end
