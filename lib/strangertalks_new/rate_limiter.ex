defmodule StrangertalksNew.RateLimiter do
  @moduledoc """
  Volatile, single-node fixed-window limiter backed by ETS.

  Participant-scoped buckets remain volatile. Queue admission additionally
  consumes a durable source-scoped bucket bound by the authenticated socket,
  preventing fresh participant identities from multiplying queue allowance.
  """

  use GenServer

  alias StrangertalksNew.SourceRateLimiter
  alias StrangertalksNew.Telemetry

  @table __MODULE__
  @source_table Module.concat(__MODULE__, SourceBindings)
  @capacity 50_000
  @cleanup_interval_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def bind_source(participant_id, source_fingerprint)
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 do
    try do
      existing? = :ets.member(@source_table, participant_id)

      cond do
        not existing? and :ets.info(@source_table, :size) >= @capacity ->
          {:error, :source_binding_capacity}

        true ->
          true = :ets.insert(@source_table, {participant_id, source_fingerprint})
          :ok
      end
    rescue
      ArgumentError -> {:error, :source_binding_unavailable}
    end
  end

  def bind_source(_participant_id, _source_fingerprint), do: {:error, :invalid_source_binding}

  def allow(bucket, actor_key, limit, window_ms)
      when is_atom(bucket) and is_integer(limit) and limit > 0 and is_integer(window_ms) and
             window_ms > 0 do
    with :ok <- allow_source_scope(bucket, actor_key) do
      now = System.monotonic_time(:millisecond)
      key = {bucket, :crypto.hash(:sha256, :erlang.term_to_binary(actor_key))}
      window_started = now - Integer.mod(now, window_ms)
      expires_at = window_started + window_ms

      consume(key, limit, window_started, expires_at, now)
    end
  end

  def allow?(bucket, actor_key, limit, window_seconds) do
    allow(bucket, actor_key, limit, window_seconds * 1_000) == :ok
  end

  def size, do: :ets.info(@table, :size)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@source_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, nil}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp allow_source_scope(:queue_join, participant_id) when is_binary(participant_id) do
    try do
      case :ets.lookup(@source_table, participant_id) do
        [{^participant_id, source_fingerprint}] ->
          case SourceRateLimiter.allow_fingerprint(
                 source_fingerprint,
                 :queue_join_source,
                 30,
                 60_000
               ) do
            :ok ->
              :ok

            {:error, retry_after_ms} when is_integer(retry_after_ms) ->
              {:error, retry_after_ms}

            {:error, :enforcement_unavailable} ->
              {:error, @cleanup_interval_ms}
          end

        [] ->
          Telemetry.execute(
            [:queue, :abuse_rejected],
            %{count: 1},
            %{rejection_category: :source_binding_missing, bucket: :queue_join_source}
          )

          {:error, @cleanup_interval_ms}
      end
    rescue
      ArgumentError ->
        Telemetry.execute(
          [:queue, :abuse_rejected],
          %{count: 1},
          %{rejection_category: :source_binding_unavailable, bucket: :queue_join_source}
        )

        {:error, @cleanup_interval_ms}
    end
  end

  defp allow_source_scope(_bucket, _actor_key), do: :ok

  defp consume(key, limit, window_started, expires_at, now) do
    case :ets.lookup(@table, key) do
      [{^key, count, ^window_started, ^expires_at}] when count >= limit ->
        {:error, max(1, expires_at - now)}

      [{^key, _count, ^window_started, ^expires_at}] ->
        increment_existing(key, limit, window_started, expires_at, now)

      [{^key, count, old_window_started, old_expires_at}] ->
        replace_stale(
          key,
          count,
          old_window_started,
          old_expires_at,
          limit,
          window_started,
          expires_at,
          now
        )

      [] ->
        insert_window(key, limit, window_started, expires_at, now)
    end
  end

  defp insert_window(key, limit, window_started, expires_at, now) do
    cond do
      :ets.info(@table, :size) >= @capacity ->
        {:error, @cleanup_interval_ms}

      :ets.insert_new(@table, {key, 1, window_started, expires_at}) ->
        :ok

      true ->
        consume(key, limit, window_started, expires_at, now)
    end
  end

  defp increment_existing(key, limit, window_started, expires_at, now) do
    try do
      count = :ets.update_counter(@table, key, {2, 1})
      if count <= limit, do: :ok, else: {:error, max(1, expires_at - now)}
    rescue
      ArgumentError -> consume(key, limit, window_started, expires_at, now)
    end
  end

  defp replace_stale(
         key,
         count,
         old_window_started,
         old_expires_at,
         limit,
         window_started,
         expires_at,
         now
       ) do
    match_spec = [
      {
        {key, count, old_window_started, old_expires_at},
        [],
        [{:const, {key, 1, window_started, expires_at}}]
      }
    ]

    case :ets.select_replace(@table, match_spec) do
      1 -> :ok
      0 -> consume(key, limit, window_started, expires_at, now)
    end
  end

  defp schedule_cleanup,
    do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
