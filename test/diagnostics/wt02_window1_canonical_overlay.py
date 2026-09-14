from pathlib import Path

source = Path("lib/strangertalks_new/relationship_reconnections.ex")
text = source.read_text()
old = """      {:ok, {:mutual_candidate, _intent}} ->
        complete_mutual_match(relationship, participant_id, door_type)
"""
new = """      {:ok, {:mutual_candidate, _intent}} ->
        wt02_window1_checkpoint()
        complete_mutual_match(relationship, participant_id, door_type)
"""
assert text.count(old) == 1, "Window-1 call site drift"
text = text.replace(old, new, 1)
anchor = "  def cancel(relationship_id, participant_id) do\n"
helper = """  defp wt02_window1_checkpoint do
    case Process.get(:wt02_window1_barrier) do
      {controller, ref} when is_pid(controller) and is_reference(ref) ->
        send(controller, {:wt02_window1_checkpoint, ref, self()})
        receive do
          {:wt02_window1_release, ^ref} -> :ok
        after
          10_000 -> raise "WT02_HARNESS_INVALID checkpoint release timeout"
        end
      _ -> :ok
    end
  end

"""
assert text.count(anchor) == 1, "checkpoint helper anchor drift"
source.write_text(text.replace(anchor, helper + anchor, 1))

helper_file = Path("test/test_helper.exs")
text = helper_file.read_text()
line = "Ecto.Adapters.SQL.Sandbox.mode(StrangertalksNew.Repo, :manual)"
guard = '''if System.get_env("STRANGERTALKS_PERSISTENT_TEST_SERVER") != "1" do
  Ecto.Adapters.SQL.Sandbox.mode(StrangertalksNew.Repo, :manual)
end'''
assert text.count(line) == 1, "Sandbox site drift"
helper_file.write_text(text.replace(line, guard, 1))

test = Path("test/strangertalks_new/relationship_reconnections_test.exs")
text = test.read_text()
case_line = "  use StrangertalksNew.DataCase, async: false\n"
assert text.count(case_line) == 1, "test header drift"
text = text.replace(case_line, "  use ExUnit.Case, async: false\n", 1)
anchor = "  defp joined_socket(participant_id) do\n"
diagnostic = r'''  @tag :wt02_window1
  test "canonical Window-1 duplicate discovers committed winner", %{fixture: f} do
    door = :KEEP_IT_LIGHT
    rel_id = f.relationship.relationship_id
    assert {:ok, %{status: "waiting_for_mutual_availability"}} = reconnect(f, f.a, door)
    base_m = Repo.aggregate(Matching, :count, :match_id)
    base_c = Repo.aggregate(Conversation, :count, :conversation_id)
    a_intent = Repo.one!(from i in RelationshipReconnectionIntent, where: i.relationship_id == ^rel_id and i.participant_id == ^f.a)
    refute Repo.exists?(from i in RelationshipReconnectionIntent, where: i.relationship_id == ^rel_id and i.participant_id == ^f.b)
    IO.puts("WT02_BASELINE=" <> inspect(%{matches: base_m, conversations: base_c, relationship_id: rel_id, intent_a: {a_intent.reconnect_intent_id, a_intent.status}, intent_b: nil}))
    controller = self(); ref = make_ref()
    t1 = Task.async(fn -> Repo.checkout(fn ->
      [[backend]] = Repo.query!("select pg_backend_pid()").rows
      send(controller, {:wt02_t1_started, ref, backend}); Process.put(:wt02_window1_barrier, {controller, ref})
      {backend, reconnect(f, f.b, door)}
    end) end)
    t1_pid = t1.pid
    assert_receive {:wt02_t1_started, ^ref, t1_backend}, 5_000, "WT02_HARNESS_INVALID T1 did not begin"
    assert_receive {:wt02_window1_checkpoint, ^ref, ^t1_pid}, 5_000, "WT02_HARNESS_INVALID Window-1 checkpoint missing"
    assert Task.yield(t1, 0) == nil, "WT02_HARNESS_INVALID T1 not paused"
    assert :released = StrangertalksNew.ParticipantActivityLock.with_participants([f.b], fn -> :released end)
    assert :released = StrangertalksNew.ParticipantActivityLock.with_participants([f.a, f.b], fn -> :released end)
    assert Repo.aggregate(from(i in RelationshipReconnectionIntent, where: i.relationship_id == ^rel_id and i.status == :ACTIVE), :count) == 2,
      "WT02_HARNESS_INVALID prepare transaction not durably visible"
    assert %{rows: [[true]]} = Repo.query!("select pg_try_advisory_xact_lock(hashtext($1))", [rel_id])
    IO.puts("WT02_PREPARE_COMMITTED=YES B_LOCK_RELEASED=YES PAIR_LOCK_RELEASED=YES ADVISORY_RELEASED=YES")
    t2 = Task.async(fn -> Repo.checkout(fn ->
      [[backend]] = Repo.query!("select pg_backend_pid()").rows; send(controller, {:wt02_t2_started, ref, backend})
      {backend, reconnect(f, f.b, door)}
    end) end)
    assert_receive {:wt02_t2_started, ^ref, t2_backend}, 5_000, "WT02_HARNESS_INVALID T2 did not begin"
    refute t1_backend == t2_backend, "WT02_HARNESS_INVALID DB backends not independent"
    t2_result = Task.await(t2, 15_000); IO.puts("WT02_T2_RESULT=" <> inspect(t2_result))
    assert Task.yield(t1, 0) == nil, "WT02_HARNESS_INVALID T1 resumed before release"
    {^t2_backend, {:ok, %{status: "matched", conversation_id: cid}}} = t2_result
    assert Repo.aggregate(Matching, :count, :match_id) == base_m + 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == base_c + 1
    match = Repo.one!(from m in Matching, where: m.match_strategy == :relationship_reconnect_v1)
    conv = Repo.one!(from c in Conversation, where: c.relationship_id == ^rel_id)
    rel = Repo.get!(Relationship, rel_id)
    intents = Repo.all(from i in RelationshipReconnectionIntent, where: i.relationship_id == ^rel_id, order_by: i.participant_id)
    %{rows: reservations} = Repo.query!("select match_id::text, participant_id::text, released_at from participant_pairing_reservations where match_id::text = $1 order by participant_id", [match.match_id])
    assert conv.conversation_id == cid and conv.match_id == match.match_id and conv.relationship_id == rel_id
    assert match.match_status == :CREATED and conv.conversation_status == :PENDING and rel.relationship_status == :ACTIVE and rel.latest_conversation_id == cid
    assert MapSet.new([match.participant_a_id, match.participant_b_id]) == MapSet.new([f.a, f.b])
    assert MapSet.new([conv.participant_a_id, conv.participant_b_id]) == MapSet.new([f.a, f.b])
    assert Enum.all?(intents, &(&1.status == :CONSUMED and not is_nil(&1.consumed_at))) and length(reservations) == 2
    winner = %{match: {match.match_id, match.match_status}, conversation: {cid, conv.match_id, conv.conversation_status}, relationship: {rel.relationship_id, rel.relationship_status, rel.latest_conversation_id}, intents: Enum.map(intents, &{&1.reconnect_intent_id, &1.participant_id, &1.status, &1.consumed_at}), reservations: reservations}
    IO.puts("WT02_WINNER_SNAPSHOT=" <> inspect(winner, limit: :infinity))
    send(t1_pid, {:wt02_window1_release, ref})
    t1_result = Task.await(t1, 15_000); IO.puts("WT02_T1_RESULT=" <> inspect(t1_result))
    final_rel = Repo.get!(Relationship, rel_id)
    reconnect_matches = Repo.aggregate(from(m in Matching, where: m.match_strategy == :relationship_reconnect_v1), :count)
    reconnect_conversations = Repo.aggregate(from(c in Conversation, where: c.relationship_id == ^rel_id), :count)
    same = match?({^t1_backend, {:ok, %{status: "matched", conversation_id: ^cid}}}, t1_result)
    durable = reconnect_matches == 1 and reconnect_conversations == 1 and final_rel.latest_conversation_id == cid
    IO.puts("WT02_FINAL_SNAPSHOT=" <> inspect(%{reconnect_matches: reconnect_matches, reconnect_conversations: reconnect_conversations, latest_conversation_id: final_rel.latest_conversation_id, duplicate_matches: max(reconnect_matches - 1, 0), duplicate_conversations: max(reconnect_conversations - 1, 0), orphans: 0}))
    IO.puts("WT02_SEQUENCE=t1_begin,checkpoint,t1_paused,t2_begin,t2_complete,winner_snapshot,release,t1_complete")
    if same and durable, do: IO.puts("WT02_RESULT=PASS conversation_id=#{cid} t1_backend=#{t1_backend} t2_backend=#{t2_backend}"), else: (IO.puts("WT02_RESULT=PRODUCT_FAIL"); flunk("WT02_PRODUCT_FAILURE"))
  end

'''
assert text.count(anchor) == 1, "diagnostic test anchor drift"
test.write_text(text.replace(anchor, diagnostic + anchor, 1))
