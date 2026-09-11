defmodule StrangertalksNew.Experiments.Hearth.AuthorityTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Experiments.Hearth.Authority

  setup do
    name = String.to_atom("hearth_authority_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Authority,
       name: name,
       bridge_ttl_ms: 50,
       submission_ttl_ms: 100,
       max_active_participants: 8,
       notifier: self()}
    )

    %{authority: name}
  end

  test "submission is bounded, private to authority state, and exposes only recent authorless samples",
       %{authority: authority} do
    assert {:error, :invalid_contribution} = Authority.submit(authority, "p1", "")

    assert {:error, :invalid_contribution} =
             Authority.submit(authority, "p1", String.duplicate("x", 101))

    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "p1", "Air fryer")
    assert {:ok, %{status: :bridge_offered}} = Authority.submit(authority, "p2", "Running shoes")

    recent = Authority.recent(authority, 3)
    assert Enum.sort(recent) == Enum.sort(["Air fryer", "Running shoes"])
    refute inspect(Authority.snapshot(authority)) =~ "Air fryer"
    refute inspect(Authority.snapshot(authority)) =~ "Running shoes"
  end

  test "second live submission produces one bridge and both users must step in", %{
    authority: authority
  } do
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    assert {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
             Authority.submit(authority, "bob", "Running shoes")

    assert {:ok, alice_offer} = Authority.offer(authority, "alice")
    assert {:ok, bob_offer} = Authority.offer(authority, "bob")
    assert alice_offer.bridge_id == bridge_id
    assert bob_offer.bridge_id == bridge_id

    assert {:ok, %{status: :waiting_for_partner}} =
             Authority.step_in(authority, "alice", bridge_id)

    assert {:ok, %{status: :room_ready, room_id: room_id}} =
             Authority.step_in(authority, "bob", bridge_id)

    assert is_binary(room_id)

    assert {:ok, %{room_id: ^room_id, own_anchor: "Air fryer", partner_anchor: "Running shoes"}} =
             Authority.room(authority, "alice")
  end

  test "control cohort pairs directly into the same ephemeral room transport", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.connect_control(authority, "control-a")

    assert {:ok, %{status: :room_ready, room_id: room_id, participant_ids: participants}} =
             Authority.connect_control(authority, "control-b")

    assert Enum.sort(participants) == ["control-a", "control-b"]

    assert {:ok,
            %{
              room_id: ^room_id,
              variant: :control,
              own_anchor: nil,
              partner_anchor: nil
            }} = Authority.room(authority, "control-a")

    assert {:ok, %{partner_id: "control-b", turn_number: 1}} =
             Authority.route_message(authority, "control-a", room_id)
  end

  test "room routing increments structural turns without accepting or retaining message bodies",
       %{authority: authority} do
    room_id = create_room(authority)

    assert {:ok, %{partner_id: "bob", turn_number: 1}} =
             Authority.route_message(authority, "alice", room_id)

    assert {:ok, %{partner_id: "alice", turn_number: 2}} =
             Authority.route_message(authority, "bob", room_id)

    snapshot = Authority.snapshot(authority)
    assert snapshot.room_count == 1
    assert snapshot.turn_count == 2
    refute inspect(snapshot) =~ "message"
  end

  test "explicit leave dissolves room immediately and returns only structural partner effects", %{
    authority: authority
  } do
    room_id = create_room(authority)
    {:ok, _} = Authority.route_message(authority, "alice", room_id)

    assert {:ok,
            %{
              status: :room_dissolved,
              room_id: ^room_id,
              partner_id: "bob",
              turn_count: 1,
              duration_ms: duration_ms
            }} = Authority.leave_room(authority, "alice", room_id)

    assert duration_ms >= 0
    assert {:error, :no_room} = Authority.room(authority, "bob")
    assert {:error, :no_room} = Authority.route_message(authority, "bob", room_id)
  end

  test "pass and disconnect dissolve a bridge and identify the neutral survivor reset", %{
    authority: authority
  } do
    {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
      Authority.submit(authority, "bob", "Running shoes")

    assert {:ok, %{status: :bridge_dissolved, partner_id: "bob"}} =
             Authority.pass(authority, "alice", bridge_id)

    assert {:error, :no_offer} = Authority.offer(authority, "bob")

    {:ok, %{status: :waiting}} = Authority.submit(authority, "carol", "Kindle")

    {:ok, %{status: :bridge_offered, bridge_id: bridge_id2}} =
      Authority.submit(authority, "dave", "Guitar")

    assert {:ok, %{status: :bridge_dissolved, partner_id: "dave"}} =
             Authority.disconnect(authority, "carol")

    assert {:error, :no_offer} = Authority.offer(authority, "dave")
    assert bridge_id2 != bridge_id
  end

  test "bridge expires actively and stale step-in cannot create a room", %{authority: authority} do
    {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
      Authority.submit(authority, "bob", "Running shoes")

    assert_receive {:hearth_bridge_expired, ^bridge_id, participants}, 250
    assert Enum.sort(participants) == ["alice", "bob"]
    assert {:error, :no_offer} = Authority.step_in(authority, "alice", bridge_id)
    assert {:error, :no_offer} = Authority.offer(authority, "bob")
  end

  test "active participant state has a hard configurable bound" do
    name = String.to_atom("hearth_bounded_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Authority,
       name: name, bridge_ttl_ms: 1_000, submission_ttl_ms: 1_000, max_active_participants: 2}
    )

    assert {:ok, %{status: :waiting}} = Authority.submit(name, "p1", "One")
    assert {:ok, %{status: :bridge_offered}} = Authority.submit(name, "p2", "Two")
    assert {:error, :capacity} = Authority.submit(name, "p3", "Three")
    assert Authority.snapshot(name).active_participant_count == 2
  end

  defp create_room(authority) do
    {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
      Authority.submit(authority, "bob", "Running shoes")

    {:ok, %{status: :waiting_for_partner}} = Authority.step_in(authority, "alice", bridge_id)

    {:ok, %{status: :room_ready, room_id: room_id}} =
      Authority.step_in(authority, "bob", bridge_id)

    room_id
  end
end
