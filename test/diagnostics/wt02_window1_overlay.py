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
assert text.count(old) == 1, "mutual-candidate checkpoint site drift"
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

# The normal test helper always puts Repo into SQL Sandbox manual mode. This
# diagnostic intentionally runs Repo with DBConnection.ConnectionPool so T1/T2
# can commit independently; make only the disposable diagnostic copy skip that
# Sandbox-only call when the already-existing persistent-test flag is enabled.
test_helper = Path("test/test_helper.exs")
text = test_helper.read_text()
sandbox_line = "Ecto.Adapters.SQL.Sandbox.mode(StrangertalksNew.Repo, :manual)"
sandbox_guard = """if System.get_env("STRANGERTALKS_PERSISTENT_TEST_SERVER") != "1" do
  Ecto.Adapters.SQL.Sandbox.mode(StrangertalksNew.Repo, :manual)
end"""
assert text.count(sandbox_line) == 1, "test helper Sandbox line drift"
test_helper.write_text(text.replace(sandbox_line, sandbox_guard, 1))

test = Path("test/strangertalks_new/relationship_reconnections_test.exs")
text = test.read_text()
case_line = "  use StrangertalksNew.DataCase, async: false\n"
assert text.count(case_line) == 1, "DataCase header drift"
text = text.replace(case_line, "  use ExUnit.Case, async: false\n", 1)
anchor = "  defp joined_socket(participant_id) do\n"
diagnostic = r'''  @tag :wt02_window1
  test "deterministic Window-1 duplicate discovers winner", %{fixture: f} do
    door = :KEEP_IT_LIGHT
    assert {:ok, %{status: "waiting_for_mutual_availability"}} = reconnect(f, f.a, door)
    base_m = Repo.aggregate(Matching, :count, :match_id)
    base_c = Repo.aggregate(Conversation, :count, :conversation_id)
    controller = self()
    ref = make_ref()

    t1 = Task.async(fn ->
      Ecto.Adapters.SQL.checkout(Repo, fn ->
        [[backend]] = Repo.query!("select pg_backend_pid()").rows
        send(controller, {:wt02_t1_connection, ref, backend})
        Process.put(:wt02_window1_barrier, {controller, ref})
        {backend, reconnect(f, f.b, door)}
      end)
    end)

    assert_receive {:wt02_t1_connection, ^ref, t1_backend}, 5_000,
                   "WT02_HARNESS_INVALID T1 connection missing"
    assert_receive {:wt02_window1_checkpoint, ^ref, t1_pid}, 5_000,
                   "WT02_HARNESS_INVALID checkpoint missing"
    assert t1_pid == t1.pid
    assert Task.yield(t1, 0) == nil, "WT02_HARNESS_INVALID T1 not paused"
    assert :released = StrangertalksNew.ParticipantActivityLock.with_participants([f.b], fn -> :released end),
           "WT02_HARNESS_INVALID B lock held"
    assert :released = StrangertalksNew.ParticipantActivityLock.with_participants([f.a, f.b], fn -> :released end),
           "WT02_HARNESS_INVALID pair lock held"
    assert Repo.aggregate(from(i in RelationshipReconnectionIntent,
             where: i.relationship_id == ^f.relationship.relationship_id and i.status == :ACTIVE), :count) == 2,
           "WT02_HARNESS_INVALID prepare transaction not durably visible"
    IO.puts("WT02_PHASE=checkpoint_verified")

    t2 = Task.async(fn ->
      Ecto.Adapters.SQL.checkout(Repo, fn ->
        [[backend]] = Repo.query!("select pg_backend_pid()").rows
        {backend, reconnect(f, f.b, door)}
      end)
    end)

    t2_result = Task.await(t2, 15_000)
    IO.inspect(t2_result, label: "WT02_T2_RESULT")
    {t2_backend, {:ok, %{status: "matched", conversation_id: cid}}} = t2_result
    refute t1_backend == t2_backend, "WT02_HARNESS_INVALID DB connections not independent"
    assert Task.yield(t1, 0) == nil, "WT02_HARNESS_INVALID T1 resumed before release"

    assert Repo.aggregate(Matching, :count, :match_id) == base_m + 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == base_c + 1
    match = Repo.one!(from m in Matching, where: m.match_strategy == :relationship_reconnect_v1)
    conv = Repo.one!(from c in Conversation, where: c.relationship_id == ^f.relationship.relationship_id)
    rel = Repo.get!(Relationship, f.relationship.relationship_id)
    intents = Repo.all(from i in RelationshipReconnectionIntent,
      where: i.relationship_id == ^rel.relationship_id, order_by: i.participant_id)
    participant_states = Repo.all(from p in StrangertalksNew.Participant,
      where: p.participant_id in ^[f.a, f.b], select: {p.participant_id, p.presence_state})
    %{rows: reservations} = Repo.query!(
      "SELECT match_id, participant_id, released_at FROM participant_pairing_reservations WHERE match_id = $1::uuid ORDER BY participant_id",
      [match.match_id])

    assert conv.conversation_id == cid
    assert conv.match_id == match.match_id
    assert match.match_status == :CREATED
    assert conv.conversation_status == :PENDING
    assert rel.latest_conversation_id == cid
    assert Enum.map(intents, & &1.status) == [:CONSUMED, :CONSUMED]
    assert Enum.all?(intents, & &1.consumed_at)
    assert length(reservations) == 2
    IO.inspect(%{match: {match.match_id, match.match_status}, conversation: {cid, conv.conversation_status},
      relationship: {rel.relationship_id, rel.latest_conversation_id},
      intents: Enum.map(intents, &{&1.reconnect_intent_id, &1.status, &1.consumed_at}),
      participants: participant_states, reservations: reservations}, label: "WT02_WINNER_SNAPSHOT")

    send(t1.pid, {:wt02_window1_release, ref})
    t1_result = Task.await(t1, 15_000)
    IO.inspect(t1_result, label: "WT02_T1_RESULT")
    {^t1_backend, {:ok, %{status: "matched", conversation_id: ^cid}}} = t1_result
    assert Repo.aggregate(Matching, :count, :match_id) == base_m + 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == base_c + 1
    assert Repo.get!(Relationship, rel.relationship_id).latest_conversation_id == cid
    IO.puts("WT02_SEQUENCE=checkpoint,t1_paused,t2_complete,snapshot,release,t1_complete")
    IO.puts("WT02_RESULT=PASS conversation_id=#{cid} t1_backend=#{t1_backend} t2_backend=#{t2_backend}")
  end

'''
assert text.count(anchor) == 1, "diagnostic test anchor drift"
test.write_text(text.replace(anchor, diagnostic + anchor, 1))