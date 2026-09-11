defmodule StrangertalksNew.Experiments.Hearth.AuthorityTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Experiments.Hearth.Authority

  setup do
    name = String.to_atom("hearth_authority_#{System.unique_integer([:positive])}")
    start_supervised!({Authority, name: name, bridge_ttl_ms: 50, submission_ttl_ms: 100})
    %{authority: name}
  end

  test "submission is bounded, private to authority state, and exposes only recent authorless samples", %{authority: authority} do
    assert {:error, :invalid_contribution} = Authority.submit(authority, "p1", "")
    assert {:error, :invalid_contribution} = Authority.submit(authority, "p1", String.duplicate("x", 101))

    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "p1", "Air fryer")
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "p2", "Running shoes")

    recent = Authority.recent(authority, 3)
    assert Enum.sort(recent) == Enum.sort(["Air fryer", "Running shoes"])
    refute inspect(Authority.snapshot(authority)) =~ "Air fryer"
    refute inspect(Authority.snapshot(authority)) =~ "Running shoes"
  end

  test "second live submission produces one bridge and both users must step in", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    assert {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
             Authority.submit(authority, "bob", "Running shoes")

    assert {:ok, alice_offer} = Authority.offer(authority, "alice")
    assert {:ok, bob_offer} = Authority.offer(authority, "bob")
    assert alice_offer.bridge_id == bridge_id
    assert bob_offer.bridge_id == bridge_id

    assert {:ok, %{status: :waiting_for_partner}} = Authority.step_in(authority, "alice", bridge_id)
    assert {:ok, %{status: :room_ready, room_id: room_id}} = Authority.step_in(authority, "bob", bridge_id)
    assert is_binary(room_id)

    assert {:ok, %{room_id: ^room_id, own_anchor: "Air fryer", partner_anchor: "Running shoes"}} =
             Authority.room(authority, "alice")
  end

  test "pass and disconnect dissolve a bridge without orphaning the survivor", %{authority: authority} do
    {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")
    {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} = Authority.submit(authority, "bob", "Running shoes")

    assert :ok = Authority.pass(authority, "alice", bridge_id)
    assert {:error, :no_offer} = Authority.offer(authority, "bob")

    {:ok, %{status: :waiting}} = Authority.submit(authority, "carol", "Kindle")
    {:ok, %{status: :bridge_offered, bridge_id: bridge_id2}} = Authority.submit(authority, "dave", "Guitar")
    assert :ok = Authority.disconnect(authority, "carol")
    assert {:error, :no_offer} = Authority.offer(authority, "dave")
    assert bridge_id2 != bridge_id
  end

  test "bridge expires and stale step-in cannot create a room", %{authority: authority} do
    {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")
    {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} = Authority.submit(authority, "bob", "Running shoes")

    Process.sleep(80)

    assert {:error, :expired} = Authority.step_in(authority, "alice", bridge_id)
    assert {:error, :no_offer} = Authority.offer(authority, "bob")
  end
end
