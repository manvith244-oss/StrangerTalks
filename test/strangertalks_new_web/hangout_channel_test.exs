defmodule StrangertalksNewWeb.HangoutChannelTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, HangoutMessage, HangoutRoom, RoomServer}
  alias StrangertalksNew.{Participants, Repo}
  alias StrangertalksNewWeb.{HangoutChannel, ParticipantToken, UserSocket}

  test "UserSocket routes hangout topics and authenticated ACTIVE members join with a redacted snapshot" do
    source = File.read!("lib/strangertalks_new_web/user_socket.ex")
    assert source =~ ~s(channel "hangout:*")
    assert source =~ "StrangertalksNewWeb.HangoutChannel"

    {room, participants} = active_room!()
    participant = hd(participants)

    assert :error = connect(UserSocket, %{})

    assert {:ok, snapshot, socket} =
             participant
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    assert socket.assigns.participant_id == participant.participant_id
    assert socket.assigns.hangout_room_id == room.room_id
    assert snapshot.room_id == room.room_id
    assert snapshot.status == :ACTIVE
    assert length(snapshot.members) == 3
    assert Enum.count(snapshot.members, & &1.self) == 1

    assert_redacted_snapshot(snapshot, participants, room.room_id)
  end

  test "non-members and terminal memberships cannot join an active Hangout" do
    {room, [active, left, removed]} = active_room!()
    outsider = participant!()

    assert {:error, %{reason: "not_hangout_member"}} =
             outsider
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    assert {:ok, _membership} = Hangouts.leave_room(room.room_id, left.participant_id)

    removed_membership = membership!(room.room_id, removed.participant_id)

    removed_membership
    |> HangoutMembership.changeset(
      %{status: :REMOVED, left_at: DateTime.utc_now(), last_seen_at: DateTime.utc_now()},
      room.room_id,
      removed.participant_id
    )
    |> Repo.update!()

    assert {:error, %{reason: "not_hangout_member"}} =
             left
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    assert {:error, %{reason: "not_hangout_member"}} =
             removed
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    assert {:ok, _snapshot, _socket} =
             active
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})
  end

  test "DISCONNECTED member reconnects through canonical authority with the same identity and sequences" do
    {room, [participant | _]} = active_room!()

    room
    |> HangoutRoom.changeset(%{content_sequence: 5})
    |> Repo.update!()

    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, before} = RoomServer.snapshot(room.room_id, participant.participant_id)
    identity_before = self_identity(before)

    assert {:ok, %{sequence: 1}} =
             RoomServer.send_message(room.room_id, participant.participant_id, %{
               client_message_id: "channel-reconnect-seed",
               body: "before disconnect"
             })

    assert {:ok, disconnected} = RoomServer.disconnect(room.room_id, participant.participant_id)
    assert self_member(disconnected).status == :DISCONNECTED

    assert {:ok, snapshot, _socket} =
             participant
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    assert snapshot.status == :ACTIVE
    assert snapshot.message_sequence == 1
    assert snapshot.content_sequence == 5
    assert self_member(snapshot).status == :ACTIVE
    assert self_identity(snapshot) == identity_before
    assert membership!(room.room_id, participant.participant_id).status == :ACTIVE
  end

  test "message intent uses socket identity, persists before public broadcast, and redacts internal authority" do
    {room, [sender | participants]} = active_room!()

    assert {:ok, _snapshot, socket} =
             sender
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    ref =
      push(socket, "message:send", %{
        "client_message_id" => "channel-message-1",
        "body" => "hello from channel"
      })

    assert_reply ref, :ok, accepted
    assert accepted.sequence == 1
    assert accepted.body == "hello from channel"

    assert Map.keys(accepted) |> Enum.sort() == [
             :body,
             :created_at,
             :message_id,
             :sender,
             :sequence
           ]

    assert_push "message:new", pushed
    assert pushed == accepted

    persisted = Repo.get!(HangoutMessage, accepted.message_id)
    assert persisted.sequence == accepted.sequence
    assert persisted.body == accepted.body

    encoded = inspect(accepted)
    refute encoded =~ sender.participant_id

    for participant <- participants do
      refute encoded =~ participant.participant_id
    end

    for membership <- memberships(room.room_id) do
      refute encoded =~ membership.membership_id
    end
  end

  test "message retries are idempotent, conflicting reuse is deliberate, and authoritative fields cannot be spoofed" do
    {room, [sender | _]} = active_room!()

    assert {:ok, _snapshot, socket} =
             sender
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    payload = %{"client_message_id" => "retry-1", "body" => "same body"}

    first_ref = push(socket, "message:send", payload)
    assert_reply first_ref, :ok, first
    assert_push "message:new", ^first

    retry_ref = push(socket, "message:send", payload)
    assert_reply retry_ref, :ok, retry
    assert retry.message_id == first.message_id
    assert retry.sequence == first.sequence

    conflict_ref =
      push(socket, "message:send", %{
        "client_message_id" => "retry-1",
        "body" => "different body"
      })

    assert_reply conflict_ref, :error, %{reason: "idempotency_conflict"}

    spoof_ref =
      push(socket, "message:send", %{
        "client_message_id" => "spoof-1",
        "body" => "no",
        "participant_id" => Ecto.UUID.generate(),
        "membership_id" => Ecto.UUID.generate(),
        "sequence" => 999
      })

    assert_reply spoof_ref, :error, %{reason: "invalid_message_intent"}
    assert Repo.aggregate(HangoutMessage, :count, :message_id) == 1
  end

  test "socket/channel disconnect becomes durable DISCONNECTED and never LEFT" do
    Process.flag(:trap_exit, true)
    {room, [participant | _]} = active_room!()

    assert {:ok, _snapshot, socket} =
             participant
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    membership_before = membership!(room.room_id, participant.participant_id)
    monitor = Process.monitor(socket.channel_pid)

    ref = leave(socket)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    membership_after = membership!(room.room_id, participant.participant_id)
    assert membership_after.membership_id == membership_before.membership_id
    assert membership_after.status == :DISCONNECTED
    assert membership_after.disconnect_count == membership_before.disconnect_count + 1
    assert is_nil(membership_after.left_at)
  end

  test "explicit room leave persists LEFT and later active join is rejected" do
    {room, [participant | _]} = active_room!()

    assert {:ok, _snapshot, socket} =
             participant
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})

    ref = push(socket, "room:leave", %{})
    assert_reply ref, :ok, %{status: "left"}

    membership = membership!(room.room_id, participant.participant_id)
    assert membership.status == :LEFT
    assert %DateTime{} = membership.left_at

    assert {:error, %{reason: "not_hangout_member"}} =
             participant
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})
  end

  test "ENDED room never resumes active channel behavior" do
    {room, [participant | _]} = active_room!()
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(room.room_id)

    assert {:error, %{reason: "hangout_ended"}} =
             participant
             |> connected_socket()
             |> subscribe_and_join(HangoutChannel, "hangout:#{room.room_id}", %{})
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
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

    track_room(room.room_id)
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

  defp memberships(room_id) do
    Repo.all(from m in HangoutMembership, where: m.room_id == ^room_id)
  end

  defp self_member(snapshot), do: Enum.find(snapshot.members, & &1.self)
  defp self_identity(snapshot), do: self_member(snapshot).identity

  defp assert_redacted_snapshot(snapshot, participants, room_id) do
    encoded = inspect(snapshot)

    for participant <- participants do
      refute encoded =~ participant.participant_id
    end

    for membership <- memberships(room_id) do
      refute encoded =~ membership.membership_id
    end

    assert Enum.all?(snapshot.members, fn member ->
             Map.keys(member) |> Enum.sort() == [:identity, :self, :status]
           end)
  end

  defp track_room(room_id) do
    on_exit(fn ->
      case RoomServer.lookup(room_id) do
        {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
        _ -> :ok
      end
    end)
  end
end
