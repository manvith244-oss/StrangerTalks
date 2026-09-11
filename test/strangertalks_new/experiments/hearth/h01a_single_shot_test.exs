defmodule StrangertalksNew.Experiments.Hearth.H01aSingleShotTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Experiments.Hearth.Authority

  setup do
    name = String.to_atom("hearth_h01a_single_shot_#{System.unique_integer([:positive])}")

    child_spec =
      Supervisor.child_spec(
        {Authority,
         name: name,
         bridge_ttl_ms: 1_000,
         submission_ttl_ms: 1_000,
         max_active_participants: 8},
        id: {:hearth_h01a_single_shot, name}
      )

    start_supervised!(child_spec)
    %{authority: name}
  end

  test "accepted treatment attempt is consumed even after disconnect", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Air fryer")
    assert {:ok, %{status: :waiting_removed}} = Authority.disconnect(authority, "alice")

    assert {:error, :already_participated} =
             Authority.submit(authority, "alice", "Running shoes")

    assert {:error, :already_participated} = Authority.connect_control(authority, "alice")
  end

  test "accepted control attempt is consumed even after waiting removal", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.connect_control(authority, "control-a")
    assert {:ok, %{status: :waiting_removed}} = Authority.disconnect(authority, "control-a")

    assert {:error, :already_participated} = Authority.connect_control(authority, "control-a")

    assert {:error, :already_participated} =
             Authority.submit(authority, "control-a", "Guitar")
  end

  test "completed room does not restore eligibility", %{authority: authority} do
    assert {:ok, %{status: :waiting}} = Authority.connect_control(authority, "a")

    assert {:ok, %{status: :room_ready, room_id: room_id}} =
             Authority.connect_control(authority, "b")

    assert {:ok, %{status: :room_dissolved}} = Authority.leave_room(authority, "a", room_id)

    assert {:error, :already_participated} = Authority.connect_control(authority, "a")
    assert {:error, :already_participated} = Authority.connect_control(authority, "b")
  end

  test "invalid input does not consume an attempt", %{authority: authority} do
    assert {:error, :invalid_contribution} = Authority.submit(authority, "alice", "")
    assert {:ok, %{status: :waiting}} = Authority.submit(authority, "alice", "Kindle")
  end

  test "capacity rejection does not consume an attempt" do
    name = String.to_atom("hearth_h01a_capacity_#{System.unique_integer([:positive])}")

    child_spec =
      Supervisor.child_spec(
        {Authority,
         name: name,
         bridge_ttl_ms: 1_000,
         submission_ttl_ms: 1_000,
         max_active_participants: 1},
        id: {:hearth_h01a_capacity, name}
      )

    start_supervised!(child_spec)

    assert {:ok, %{status: :waiting}} = Authority.connect_control(name, "first")
    assert {:error, :capacity} = Authority.connect_control(name, "second")
    assert {:ok, %{status: :waiting_removed}} = Authority.disconnect(name, "first")
    assert {:ok, %{status: :waiting}} = Authority.connect_control(name, "second")
  end
end
