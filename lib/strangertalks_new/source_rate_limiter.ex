defmodule StrangertalksNew.SourceRateLimiter do
  @moduledoc """
  Durable, source-scoped fixed-window enforcement for pre-identity abuse controls.

  Only an HMAC fingerprint of the source is persisted. Raw IP/source values and
  participant identifiers are never written to this rate-limit table.
  """

  alias Ecto.Adapters.SQL
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Telemetry

  @cleanup_sql "DELETE FROM source_rate_limits WHERE expires_at_ms <= $1"
  @consume_sql """
  INSERT INTO source_rate_limits AS limits
    (source_fingerprint, bucket, window_key, count, expires_at_ms)
  VALUES ($1, $2, $3, 1, $4)
  ON CONFLICT (source_fingerprint, bucket, window_key)
  DO UPDATE SET
    count = limits.count + 1,
    expires_at_ms = EXCLUDED.expires_at_ms
  WHERE limits.count < $5
  RETURNING count
  """

  def fingerprint(source) do
    with {:ok, key} <- hmac_key() do
      {:ok, :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary({:source_v1, source}))}
    end
  rescue
    _error -> {:error, :enforcement_unavailable}
  end

  def transact_source(source, policies, operation_fun)
      when is_list(policies) and is_function(operation_fun, 1) do
    with {:ok, source_fingerprint} <- fingerprint(source),
         {:ok, value} <- transact_fingerprint(source_fingerprint, policies, operation_fun) do
      {:ok, value, source_fingerprint}
    end
  end

  def transact_fingerprint(source_fingerprint, policies, operation_fun)
      when is_binary(source_fingerprint) and byte_size(source_fingerprint) == 32 and
             is_list(policies) and is_function(operation_fun, 1) do
    safe_transaction(fn ->
      cleanup_expired!()
      Enum.each(policies, &consume_policy!(source_fingerprint, &1))

      case operation_fun.(source_fingerprint) do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
        _other -> Repo.rollback(:enforcement_unavailable)
      end
    end)
  end

  def transact_fingerprint(_source_fingerprint, _policies, _operation_fun),
    do: {:error, :enforcement_unavailable}

  def allow_fingerprint(source_fingerprint, bucket, limit, window_ms)
      when is_binary(source_fingerprint) and byte_size(source_fingerprint) == 32 and
             is_atom(bucket) and is_integer(limit) and limit > 0 and is_integer(window_ms) and
             window_ms > 0 do
    case transact_fingerprint(
           source_fingerprint,
           [{bucket, limit, window_ms}],
           fn _fingerprint -> {:ok, :allowed} end
         ) do
      {:ok, :allowed} ->
        :ok

      {:error, {:rate_limited, ^bucket, retry_after_ms}} ->
        emit_rejection(bucket, :rate_limited)
        {:error, retry_after_ms}

      {:error, :enforcement_unavailable} ->
        emit_rejection(bucket, :enforcement_unavailable)
        {:error, :enforcement_unavailable}

      {:error, _reason} ->
        emit_rejection(bucket, :enforcement_unavailable)
        {:error, :enforcement_unavailable}
    end
  end

  def allow_fingerprint(_source_fingerprint, bucket, _limit, _window_ms) when is_atom(bucket) do
    emit_rejection(bucket, :enforcement_unavailable)
    {:error, :enforcement_unavailable}
  end

  defp safe_transaction(fun) do
    Repo.transaction(fun)
  rescue
    _error -> {:error, :enforcement_unavailable}
  catch
    :exit, _reason -> {:error, :enforcement_unavailable}
  end

  defp cleanup_expired! do
    now_ms = System.system_time(:millisecond)

    case SQL.query(Repo, @cleanup_sql, [now_ms]) do
      {:ok, _result} -> :ok
      {:error, _reason} -> Repo.rollback(:enforcement_unavailable)
    end
  end

  defp consume_policy!(source_fingerprint, {bucket, limit, window_ms})
       when is_atom(bucket) and is_integer(limit) and limit > 0 and is_integer(window_ms) and
              window_ms > 0 do
    now_ms = System.system_time(:millisecond)
    window_key = div(now_ms, window_ms)
    expires_at_ms = (window_key + 1) * window_ms

    case SQL.query(Repo, @consume_sql, [
           source_fingerprint,
           Atom.to_string(bucket),
           window_key,
           expires_at_ms,
           limit
         ]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        Repo.rollback({:rate_limited, bucket, max(1, expires_at_ms - now_ms)})

      {:error, _reason} ->
        Repo.rollback(:enforcement_unavailable)
    end
  end

  defp consume_policy!(_source_fingerprint, _invalid_policy),
    do: Repo.rollback(:enforcement_unavailable)

  defp hmac_key do
    configured = Application.get_env(:strangertalks_new, :source_rate_limit_hmac_key)
    endpoint_config = Application.get_env(:strangertalks_new, StrangertalksNewWeb.Endpoint, [])

    endpoint_secret =
      case endpoint_config do
        config when is_list(config) -> Keyword.get(config, :secret_key_base)
        config when is_map(config) -> Map.get(config, :secret_key_base)
        _other -> nil
      end

    key = if valid_hmac_key?(configured), do: configured, else: endpoint_secret

    if valid_hmac_key?(key), do: {:ok, key}, else: {:error, :enforcement_unavailable}
  end

  defp valid_hmac_key?(key), do: is_binary(key) and byte_size(key) >= 32

  defp emit_rejection(:queue_join_source, category) do
    Telemetry.execute(
      [:queue, :abuse_rejected],
      %{count: 1},
      %{rejection_category: category, bucket: :queue_join_source}
    )
  end

  defp emit_rejection(:socket_connect_source, category) do
    Telemetry.execute(
      [:socket, :abuse_rejected],
      %{count: 1},
      %{rejection_category: category, bucket: :socket_connect_source}
    )
  end

  defp emit_rejection(bucket, category) do
    Telemetry.execute(
      [:abuse, :source_rate_limit_rejected],
      %{count: 1},
      %{rejection_category: category, bucket: bucket}
    )
  end
end
