defmodule StrangertalksNewWeb.HangoutPresenceLeaseSecurityTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, PresenceAuthority, RoomServer}
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
    assert PresenceAuthority.live_channel_count(room.room_id, participant.participant_id) == 2
    assert membership!(room.room_id, participant.participant_id).status == :ACTIVE

    first_monitor = Process.monitor(first_socket.channel_pid)
    first_leave = leave(first_socket)
    assert_reply first_leave, :ok
    assert_receive {:DOWN, ^first_monitor, :process, _pid, _reason}

    still_active = membership!(room.room_id, participant.participant_id)
    assert still_active.status == :ACTIVE
    assert still_active.disconnect_count == 0
    assert PresenceAuthority.live_channel_count(room.room_id, participant.participant_id) == 1

    second_monitor = Process.monitor(second_socket.channel_pid)
    second_leave = leave(second_socket)
    assert_reply second_leave, :ok
    assert_receive {:DOWN, ^second_monitor, :process, _pid, _reason}

    disconnected = membership!(room.room_id, participant.participant_id)
    assert disconnected.status == :DISCONNECTED
    assert disconnected.disconnect_count == 1
    assert PresenceAuthority.live_channel_count(room.room_id, participant.participant_id) == 0
  end

  test "client cannot author or inject a presence lease" do
    {room, [participant | _]} = active_room!()
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    assert {:error, %{reason: "invalid_request"}} =
             subscribe_and_join(socket, HangoutChannel, "hangout:#{room.room_id}", %{
               "presence_lease_id" => Ecto.UUID.generate()
             })

    assert PresenceAuthority.live_channel_count(room.room_id, participant.participant_id) == 0
  end

  test "explicit leave revokes every overlapping channel so no left tab keeps receiving room events" do
    Process.flag(:trap_exit, true)
    {room, [participant | _]} = active_room!()

    assert {:ok, _first_snapshot, first_socket} = join(participant, room.room_id)
    assert {:ok, _second_snapshot, second_socket} = join(participant, room.room_id)
    assert PresenceAuthority.live_channel_count(room.room_id, participant.participant_id) == 2

    first_monitor = Process.monitor(first_socket.channel_pid)
    second_monitor = Process.monitor(second_socket.channel_pid)

    leave_ref = push(first_socket, "room:leave", %{})
    assert_reply leave_ref, :ok, %{status: "left"}
    assert_receive {:DOWN, ^first_monitor, :process, _pid, _reason}
    assert_receive {:DOWN, ^second_monitor, :process, _pid, _reason}

    left = membership!(room.room_id, participant.participant_id)
    assert left.status == :LEFT
    assert PresenceAuthority.live_channel_count(room.room_id, participant.participant_id) == 0
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
end
