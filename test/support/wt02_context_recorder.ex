defmodule StrangertalksNew.WT02ContextRecorder do
  use GenServer
  import Ecto.Query
  alias StrangertalksNew.{Conversation, Matching, Relationship, RelationshipReconnectionIntent, Repo}
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.ConversationLifecycle.RecoverySweeper
  @target "concurrent second-intent attempts still create one Match and one Conversation"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(opts), do: {:ok, %{opts: opts, tests: [], modules: [], context: nil, started: nil}}

  def pre_reset do
    keys = Agent.get(QueueState, &(&1 |> Map.keys() |> Enum.sort()))
    Process.put(:wt02_pre, %{monotonic: System.monotonic_time(),
      queue_state: %{pid: pid(QueueState), entry_count: length(keys), key_fingerprint: hash(keys), bounded_keys: Enum.take(keys, 16)},
      conversation_supervisor: supervisor(), conversation_registry: registry_all(), recovery_sweeper: process_info(RecoverySweeper)})
  end

  def after_setup do
    n = Agent.get(QueueState, &map_size/1)
    Process.put(:wt02_after, %{queue_state_entry_count: n, queue_state_expected_empty: n == 0})
  end

  def post_race(f, results) do
    base = %{pre_reset: Process.get(:wt02_pre), after_setup: Process.get(:wt02_after), results: results,
      post_race: nil, observation_error: nil}

    context =
      try do
        %{base | post_race: post_race_snapshot(f, results)}
      rescue
        error in [DBConnection.EncodeError, Ecto.NoResultsError, Ecto.Query.CastError, Postgrex.Error] ->
          %{base | observation_error: inspect(error.__struct__)}
      end

    GenServer.call(__MODULE__, {:context, context})
  end

  defp post_race_snapshot(f, results) do
    rel = Repo.one!(from r in Relationship, where: r.relationship_id == ^f.relationship.relationship_id,
      select: %{relationship_id: r.relationship_id, relationship_status: r.relationship_status, latest_conversation_id: r.latest_conversation_id,
        conversation_count: r.conversation_count, reconnection_count: r.reconnection_count})
    intents = Repo.all(from i in RelationshipReconnectionIntent, where: i.relationship_id == ^rel.relationship_id,
      select: %{id: i.reconnect_intent_id, participant_id: i.participant_id, door_type: i.door_type, status: i.status})
    matches = Repo.all(from m in pair(Matching, f), select: %{match_id: m.match_id, status: m.match_status, strategy: m.match_strategy})
    conversations = Repo.all(from c in pair(Conversation, f),
      select: %{conversation_id: c.conversation_id, match_id: c.match_id, relationship_id: c.relationship_id, status: c.conversation_status})
    reservations = Repo.query!("SELECT match_id::text, participant_id::text, released_at::text FROM participant_pairing_reservations WHERE participant_id IN ($1::uuid,$2::uuid)", [Ecto.UUID.dump!(f.a), Ecto.UUID.dump!(f.b)]).rows
    win = Enum.find_value(results, fn {:ok, %{status: "matched", conversation_id: id}} -> id; _ -> nil end)
    q = Agent.get(QueueState, &Map.take(&1, [f.a, f.b]))
    match_ids = MapSet.new(matches, & &1.match_id)
    %{queue_state: %{fixture_participant_entries: q}, conversation_supervisor: supervisor(), conversation_registry: registry_one(win),
      recovery_sweeper: process_info(RecoverySweeper), durable: %{relationship: rel, reconnect_intents: intents, matches: matches,
        conversations: conversations, reservations: reservations,
        duplicates: %{reconnect_matches: Enum.count(matches, &(&1.strategy == :relationship_reconnect_v1)),
          relationship_conversations: Enum.count(conversations, &(&1.relationship_id == rel.relationship_id))},
        bounded_orphans: Enum.reject(conversations, &MapSet.member?(match_ids, &1.match_id))}}
  end

  def handle_call({:context, c}, _from, s), do: {:reply, :ok, %{s | context: c}}
  def handle_cast({:test_started, t}, s), do: {:noreply, %{s | started: if(target?(t), do: System.monotonic_time(), else: s.started)}}
  def handle_cast({:test_finished, t}, s) do
    if target?(t), do: write_artifact(s, t)
    e = %{module: t.module, test: t.name, async: t.tags[:async], outcome: outcome(t.state), duration: t.time,
      formatter_finished_received_monotonic: System.monotonic_time()}
    {:noreply, %{s | tests: ring(s.tests, e, 32)}}
  end
  def handle_cast({:module_finished, m}, s) do
    e = %{module: m.name, async: case m.tests do [t | _] -> t.tags[:async]; _ -> false end, test_count: length(m.tests),
      duration: Enum.sum(Enum.map(m.tests, & &1.time)), formatter_finished_received_monotonic: System.monotonic_time()}
    {:noreply, %{s | modules: ring(s.modules, e, 4)}}
  end
  def handle_cast(_, s), do: {:noreply, s}

  defp write_artifact(s, t) do
    c = s.context || %{}; results = Map.get(c, :results, [])
    complete = match?([_, _], results) and Enum.all?(results, &valid_result?/1)
    valid = complete and not is_nil(Map.get(c, :post_race)) and is_nil(Map.get(c, :observation_error))
    ok = valid and Enum.all?(results, &match?({:ok, %{status: "matched"}}, &1))
    class = cond do
      not valid -> "INVALID_OBSERVATION"
      Enum.any?(results, &match?({:error, :reconnection_unavailable}, &1)) -> "UNAVAILABLE_ROUTE_NOT_YET_LOCALIZED"
      ok -> "NONE"
      true -> "DB_EXCEPTION_RESCUE_OBSERVED"
    end
    artifact = %{schema_version: 1, identity: identity(s.opts),
      target: %{module: t.module, test: t.name, async: t.tags[:async], formatter_test_started_received_monotonic: s.started,
        pre_reset_monotonic: get_in(c, [:pre_reset, :monotonic]), test_outcome: outcome(t.state), duration: t.time,
        t1_result: Enum.at(results, 0), t2_result: Enum.at(results, 1)},
      predecessors: %{recent_tests: s.tests, recent_modules: s.modules, immediately_preceding_module: List.last(s.modules)},
      pre_reset: Map.get(c, :pre_reset), after_setup: Map.get(c, :after_setup), post_race: Map.get(c, :post_race),
      classification: %{existing_error_class: class, observation_valid: valid, observation_error: Map.get(c, :observation_error),
        target_contract_satisfied: ok, artifact_written_at: DateTime.utc_now()}}
    path = System.fetch_env!("WT02_ARTIFACT"); File.mkdir_p!(Path.dirname(path)); File.write!(path, Jason.encode!(clean(artifact), pretty: true))
  end

  defp identity(opts), do: %{git_sha: System.get_env("WT02_TEAM6_SHA"), seed: System.get_env("WT02_SEED"), max_cases: opts[:max_cases],
    schedulers_online: System.schedulers_online(), MIX_TEST_PARTITION: System.get_env("MIX_TEST_PARTITION"), elixir_version: System.version(),
    otp_version: System.otp_release(), postgres_version: System.get_env("WT02_POSTGRES_VERSION"),
    runner_identity: "#{System.get_env("GITHUB_RUN_ID")}:#{System.get_env("GITHUB_JOB")}:#{System.get_env("GITHUB_SHA")}"}
  defp pair(schema, f) do
    from x in schema,
      where:
        (x.participant_a_id == ^f.a and x.participant_b_id == ^f.b) or
          (x.participant_a_id == ^f.b and x.participant_b_id == ^f.a)
  end
  defp valid_result?({:ok, result}), do: is_map(result)
  defp valid_result?({:error, _reason}), do: true
  defp valid_result?(_), do: false
  defp target?(t), do: t.module == StrangertalksNew.RelationshipReconnectionsTest and String.contains?(to_string(t.name), @target)
  defp ring(xs, x, n), do: Enum.take(xs ++ [x], -n)
  defp outcome(nil), do: "passed"
  defp outcome({x, _}), do: to_string(x)
  defp outcome(x), do: inspect(x)
  defp pid(name), do: name |> Process.whereis() |> inspect()
  defp supervisor do
    c = DynamicSupervisor.count_children(StrangertalksNew.ConversationDynamicSupervisor); p = Process.whereis(StrangertalksNew.ConversationDynamicSupervisor)
    %{pid: inspect(p), alive: p != nil, active_children: c.active, workers: c.workers}
  end
  defp registry_all do
    es = Registry.select(StrangertalksNew.DistributedRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.filter(fn {k, _} -> is_binary(k) and String.starts_with?(k, "conversation:") end)
      |> Enum.map(fn {k, p} -> %{conversation_id: String.replace_prefix(k, "conversation:", ""), pid: inspect(p), alive: Process.alive?(p),
        message_queue_len: elem(Process.info(p, :message_queue_len) || {:message_queue_len, -1}, 1)} end)
    %{total_conversation_entries: length(es), entries: es}
  end
  defp registry_one(nil), do: []
  defp registry_one(id), do: Registry.lookup(StrangertalksNew.DistributedRegistry, "conversation:#{id}") |> Enum.map(fn {p, _} -> %{conversation_id: id, pid: inspect(p), alive: Process.alive?(p)} end)
  defp process_info(name) do
    p = Process.whereis(name); info = if p, do: Process.info(p, [:message_queue_len, :reductions, :current_function]), else: []
    %{pid: inspect(p), alive: p != nil, message_queue_len: info[:message_queue_len], reductions: info[:reductions], current_function: inspect(info[:current_function])}
  end
  defp hash(x), do: :crypto.hash(:sha256, :erlang.term_to_binary(x)) |> Base.encode16(case: :lower)
  defp clean(%DateTime{} = x), do: DateTime.to_iso8601(x)
  defp clean(%_{} = x), do: inspect(x)
  defp clean(x) when is_map(x), do: Map.new(x, fn {k, v} -> {to_string(k), clean(v)} end)
  defp clean(x) when is_list(x), do: Enum.map(x, &clean/1)
  defp clean(x) when x in [true, false, nil], do: x
  defp clean(x) when is_atom(x) or is_tuple(x) or is_pid(x), do: inspect(x)
  defp clean(x), do: x
end
