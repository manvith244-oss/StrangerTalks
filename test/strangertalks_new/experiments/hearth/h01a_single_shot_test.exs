defmodule StrangertalksNew.Experiments.Hearth.H01aSingleShotTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Experiments.Hearth.Authority

  setup do
    name = String.to_atom("hearth_h01a_single_shot_#{System.unique_integer([:positive])}")

    child_spec =
      Supervisor.child_spec(
        {Authority,
         name: name,
         bridge_ttl_ms: 50,
         submission_ttl_ms: 50,
         max_active_participants: 16,
         notifier: self()},
        id: {:hearth_h01a_single_shot, name}
      )

    start_supervised!(child_spec)
    %{authority: name}
  end

  test "treatment participant cannot begin a second attempt after passing", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    assert {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
             Authority.submit(authority, "bob", "Running shoes")

    assert {:ok, %{status: :bridge_dissolved}} = Authority.pass(authority, "alice", bridge_id)

    assert {:error, :already_participated} =
             Authority.submit(authority, "alice", "Kindle")
  end

  test "both room participants remain consumed after the room ends", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")

    assert {:ok, %{status: :bridge_offered, bridge_id: bridge_id}} =
             Authority.submit(authority, "bob", "Running shoes")

    assert {:ok, %{status: :waiting_for_partner}} =
             Authority.step_in(authority, "alice", bridge_id)

    assert {:ok, %{status: :room_ready, room_id: room_id}} =
             Authority.step_in(authority, "bob", bridge_id)

    assert {:ok, %{status: :room_dissolved}} = Authority.leave_room(authority, "alice", room_id)

    assert {:error, :already_participated} =
             Authority.submit(authority, "alice", "Kindle")

    assert {:error, :already_participated} =
             Authority.submit(authority, "bob", "Guitar")
  end

  test "control participant cannot begin a second attempt after disconnect", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.connect_control(authority, "control-a")
    assert {:ok, %{status: :waiting_removed}} = Authority.disconnect(authority, "control-a")

    assert {:error, :already_participated} =
             Authority.connect_control(authority, "control-a")
  end

  test "expired waiting attempt cannot be retried", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")
    assert_receive {:hearth_waiting_expired, "alice"}, 250

    assert {:error, :already_participated} =
             Authority.submit(authority, "alice", "Kindle")
  end
end
