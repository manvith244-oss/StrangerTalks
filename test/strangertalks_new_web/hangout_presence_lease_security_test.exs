defmodule StrangertalksNewWeb.HangoutPresenceLeaseSecurityTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, RoomServer}
  alias StrangertalksNew.{Participants, Repo}
  alias StrangertalksNewWeb.{HangoutChannel, ParticipantToken, UserSocket}

  test "late termination of an older overlapping channel cannot falsify active presence" do
    Process.flag(:trap_exit, true)
    {room, [participant | _]} = active_room!()

    assert {:ok, _first_snapshot, first_socket} = join(participant, room.room_id)
    assert {:ok, _second_snapshot, second_socket} = join(participant, room.room_id)

    first_lease = first_socket.assigns.hangout_presence_lease_id
    second_lease = second_socket.assigns.hangout_presence_lease_id

    assert is_binary(first_lease)
    assert is_binary(second_lease)
    refute first_lease == second_lease
    assert membership!(room.room_id, participant.participant_id).status == :ACTIVE

    first_monitor = Process.monitor(first_socket.channel_pid)
    first_leave = leave(first_socket)
    assert_reply first_leave, :ok
    assert_receive {:DOWN, ^first_monitor, :process, _pid, _reason}

    still_active = membership!(room.room_id, participant.participant_id)
    assert still_active.status == :ACTIVE
    assert still_active.disconnect_count == 0

    second_monitor = Process.monitor(second_socket.channel_pid)
    second_leave = leave(second_socket)
    assert_reply second_leave, :ok
    assert_receive {:DOWN, ^second_monitor, :process, _pid, _reason}

    disconnected = membership!(room.room_id, participant.participant_id)
    assert disconnected.status == :DISCONNECTED
    assert disconnected.disconnect_count == 1
  end

  test "stale disconnect lease is ignored after a replacement lease has become authoritative" do
    {room, [participant | _]} = active_room!()
    old_lease = Ecto.UUID.generate()
    new_lease = Ecto.UUID.generate()

    assert {:ok, _snapshot} = RoomServer.reconnect(room.room_id, participant.participant_id, old_lease)
    assert {:ok, _snapshot} = RoomServer.reconnect(room.room_id, participant.participant_id, new_lease)

    assert {:ok, snapshot} = RoomServer.disconnect(room.room_id, participant.participant_id, old_lease)
    assert self_member(snapshot).status == :ACTIVE
    assert membership!(room.room_id, participant.participant_id).status == :ACTIVE

    assert {:ok, snapshot} = RoomServer.disconnect(room.room_id, participant.participant_id, new_lease)
    assert self_member(snapshot).status == :DISCONNECTED
    assert membership!(room.room_id, participant.participant_id).status == :DISCONNECTED
  end

  defp join(participant, room_id) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    subscribe_and_join(socket, HangoutChannel, "hangout:#{room_id}", %{})
  end

  defp active_room! do
    participants = for _ <- 1..3, do: participant!()

    {:ok, %{room: room}} =
      Hangouts.create_formed_room(
        Enum.map(participants, & &1.participant_id),
        %{
          language_tag: "en",
          experiment_arm: :GROUP_WITH_CONTENT,
          minimum_size: 3,
          target_size: 4,
          max_size: 6
        }
      )

    on_exit(fn ->
      case RoomServer.lookup(room.room_id) do
        {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
        _ -> :ok
      end
    end)

    {room, participants}
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp membership!(room_id, participant_id) do
    Repo.one!(
      from m in HangoutMembership,
        where: m.room_id == ^room_id and m.participant_id == ^participant_id
    )
  end

  defp self_member(snapshot), do: Enum.find(snapshot.members, & &1.self)
end
