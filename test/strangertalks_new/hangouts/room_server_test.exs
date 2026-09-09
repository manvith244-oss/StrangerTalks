defmodule StrangertalksNew.Hangouts.RoomServerTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, HangoutMessage, HangoutRoom, RoomServer}
  alias StrangertalksNew.{Participants, Repo}

  @pubsub StrangertalksNew.PubSub

  test "eligible durable room starts from database truth while missing and terminal rooms refuse authority" do
    room = room!()

    assert {:ok, pid} = RoomServer.ensure_started(room.room_id)
    assert Process.alive?(pid)
    assert {:ok, ^pid} = RoomServer.lookup(room.room_id)
    assert function_exported?(RoomServer, :ensure_started, 1)
    refute function_exported?(RoomServer, :ensure_started, 2)

    assert {:error, :room_not_found} = RoomServer.ensure_started(Ecto.UUID.generate())

    terminal = room!()
    set_room_status!(terminal, :ENDED)

    assert {:error, :terminal_room} = RoomServer.ensure_started(terminal.room_id)
    assert {:error, :not_started} = RoomServer.lookup(terminal.room_id)
  end

  test "concurrent ensure_started calls and activation converge on one room authority" do
    {room, _participants} = forming_room_with_members!(3)

    results =
      1..20
      |> Task.async_stream(fn _ -> RoomServer.ensure_started(room.room_id) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _pid}, &1))
    assert [{:ok, pid}] = Enum.uniq(results)
    assert Process.alive?(pid)
    assert {:ok, ^pid} = RoomServer.lookup(room.room_id)

    persisted = Repo.get!(HangoutRoom, room.room_id)
    assert persisted.status == :ACTIVE
    assert %DateTime{} = persisted.activated_at
  end

  test "boot and snapshots are rebuilt from durable room state and never accept caller-supplied state" do
    {room, [first | _]} = forming_room_with_members!(3, %{language_tag: "pt-BR"})

    room
    |> HangoutRoom.changeset(%{content_sequence: 7, message_sequence: 9})
    |> Repo.update!()

    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, snapshot} = RoomServer.snapshot(room.room_id, first.participant_id)

    assert snapshot.room_id == room.room_id
    assert snapshot.status == :ACTIVE
    assert snapshot.language_tag == "pt-BR"
    assert snapshot.minimum_size == 3
    assert snapshot.target_size == 4
    assert snapshot.max_size == 6
    assert snapshot.message_sequence == 9
    assert snapshot.content_sequence == 7
  end

  test "FORMING remains forming below minimum and activates when persisted active membership reaches minimum" do
    {room, [first, _second]} = forming_room_with_members!(2)

    assert {:ok, pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, before} = RoomServer.snapshot(room.room_id, first.participant_id)
    assert before.status == :FORMING
    assert Repo.get!(HangoutRoom, room.room_id).status == :FORMING

    third = participant!()
    assert {:ok, _membership} = Hangouts.add_member(room.room_id, third.participant_id)

    assert {:ok, ^pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, after_activation} = RoomServer.snapshot(room.room_id, first.participant_id)
    assert after_activation.status == :ACTIVE
    assert Repo.get!(HangoutRoom, room.room_id).status == :ACTIVE
  end

  test "participant-facing snapshot preserves temporary identities and redacts persistent identifiers" do
    {room, participants} = active_room_with_members!(3)
    first = hd(participants)
    memberships = Repo.all(from m in HangoutMembership, where: m.room_id == ^room.room_id)

    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, snapshot} = RoomServer.snapshot(room.room_id, first.participant_id)

    assert length(snapshot.members) == 3
    assert Enum.count(snapshot.members, & &1.self) == 1

    encoded = inspect(snapshot)

    for participant <- participants do
      refute encoded =~ participant.participant_id
    end

    for membership <- memberships do
      refute encoded =~ membership.membership_id
    end

    assert Enum.all?(snapshot.members, fn member ->
             Map.keys(member) |> Enum.sort() == [:identity, :self, :status]
           end)
  end

  test "disconnect is durable membership state, not leave, and reconnect restores the same identity" do
    {room, [first | _]} = active_room_with_members!(3)
    membership_before = membership!(room.room_id, first.participant_id)

    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, before} = RoomServer.snapshot(room.room_id, first.participant_id)
    identity_before = self_identity(before)

    assert {:ok, disconnected_snapshot} =
             RoomServer.disconnect(room.room_id, first.participant_id)

    assert self_member(disconnected_snapshot).status == :DISCONNECTED

    disconnected = membership!(room.room_id, first.participant_id)
    assert disconnected.membership_id == membership_before.membership_id
    assert disconnected.status == :DISCONNECTED
    assert disconnected.disconnect_count == membership_before.disconnect_count + 1
    assert is_nil(disconnected.left_at)

    other_room = room!()

    assert {:error, :already_in_hangout} =
             Hangouts.add_member(other_room.room_id, first.participant_id)

    assert {:ok, reconnected_snapshot} = RoomServer.reconnect(room.room_id, first.participant_id)
    assert self_member(reconnected_snapshot).status == :ACTIVE
    assert self_identity(reconnected_snapshot) == identity_before

    reconnected = membership!(room.room_id, first.participant_id)
    assert reconnected.membership_id == membership_before.membership_id
    assert reconnected.temporary_identity_slot == membership_before.temporary_identity_slot
    assert reconnected.status == :ACTIVE
  end

  test "authorized messages persist before broadcast and public message payloads redact internal authority" do
    {room, [first | _]} = active_room_with_members!(3)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert :ok = Phoenix.PubSub.subscribe(@pubsub, "hangout:#{room.room_id}")

    attrs = %{client_message_id: "roomserver-1", body: "hello room"}

    assert {:ok, public_message} =
             RoomServer.send_message(room.room_id, first.participant_id, attrs)

    assert Map.keys(public_message) |> Enum.sort() ==
             [:body, :created_at, :message_id, :sender, :sequence]

    refute Map.has_key?(public_message, :participant_id)
    refute Map.has_key?(public_message, :membership_id)

    assert_receive {:hangout_event, "message:new", ^public_message}

    persisted = Repo.get!(HangoutMessage, public_message.message_id)
    assert persisted.sequence == public_message.sequence
    assert persisted.body == public_message.body

    oversized = String.duplicate("x", HangoutMessage.max_body_bytes() + 1)

    assert {:error, :invalid_message, _changeset} =
             RoomServer.send_message(room.room_id, first.participant_id, %{
               client_message_id: "roomserver-too-large",
               body: oversized
             })

    refute_receive {:hangout_event, "message:new", %{body: ^oversized}}, 50
  end

  test "unauthorized, LEFT, and REMOVED members cannot send messages" do
    {room, [active, left, removed]} = active_room_with_members!(3)
    outsider = participant!()
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)

    assert {:error, :membership_not_found} =
             RoomServer.send_message(room.room_id, outsider.participant_id, %{
               client_message_id: "outsider",
               body: "no"
             })

    assert {:ok, _} = Hangouts.leave_room(room.room_id, left.participant_id)

    assert {:error, :membership_not_active} =
             RoomServer.send_message(room.room_id, left.participant_id, %{
               client_message_id: "left",
               body: "no"
             })

    removed_membership = membership!(room.room_id, removed.participant_id)

    removed_membership
    |> HangoutMembership.changeset(
      %{status: :REMOVED, left_at: DateTime.utc_now(), last_seen_at: DateTime.utc_now()},
      room.room_id,
      removed.participant_id
    )
    |> Repo.update!()

    assert {:error, :membership_not_active} =
             RoomServer.send_message(room.room_id, removed.participant_id, %{
               client_message_id: "removed",
               body: "no"
             })

    assert {:ok, _message} =
             RoomServer.send_message(room.room_id, active.participant_id, %{
               client_message_id: "active",
               body: "yes"
             })
  end

  test "crash and restart reconstruct durable lifecycle, identities, and sequences" do
    {room, [first | _]} = active_room_with_members!(3)

    room
    |> HangoutRoom.changeset(%{content_sequence: 4})
    |> Repo.update!()

    assert {:ok, old_pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, before} = RoomServer.snapshot(room.room_id, first.participant_id)
    identity_before = self_identity(before)

    assert {:ok, %{sequence: 1}} =
             RoomServer.send_message(room.room_id, first.participant_id, %{
               client_message_id: "restart-1",
               body: "before crash"
             })

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    assert {:ok, replacement} = RoomServer.ensure_started(room.room_id)
    refute replacement == old_pid
    assert Process.alive?(replacement)

    assert {:ok, after_restart} = RoomServer.snapshot(room.room_id, first.participant_id)
    assert after_restart.status == :ACTIVE
    assert after_restart.message_sequence == 1
    assert after_restart.content_sequence == 4
    assert self_identity(after_restart) == identity_before
  end

  test "ENDED is terminal: late messages and reconnects fail and runtime does not resurrect" do
    {room, [first | _]} = active_room_with_members!(3)
    assert {:ok, pid} = RoomServer.ensure_started(room.room_id)
    monitor = Process.monitor(pid)

    assert {:ok, terminal_snapshot} = RoomServer.end_room(room.room_id)
    assert terminal_snapshot.status == :ENDED
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    persisted = Repo.get!(HangoutRoom, room.room_id)
    assert persisted.status == :ENDED
    assert %DateTime{} = persisted.ended_at
    assert {:error, :not_started} = RoomServer.lookup(room.room_id)
    assert {:error, :terminal_room} = RoomServer.ensure_started(room.room_id)

    assert {:error, :terminal_room} = RoomServer.reconnect(room.room_id, first.participant_id)

    assert {:error, :terminal_room} =
             RoomServer.send_message(room.room_id, first.participant_id, %{
               client_message_id: "after-end",
               body: "no resurrection"
             })
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp room!(attrs \\ %{}) do
    defaults = %{
      language_tag: "en",
      experiment_arm: :GROUP_WITH_CONTENT,
      minimum_size: 3,
      target_size: 4,
      max_size: 6
    }

    {:ok, room} = Hangouts.create_room(Map.merge(defaults, attrs))
    track_room(room.room_id)
    room
  end

  defp forming_room_with_members!(count, attrs \\ %{}) do
    room = room!(attrs)

    participants =
      for _ <- 1..count do
        participant = participant!()
        assert {:ok, _membership} = Hangouts.add_member(room.room_id, participant.participant_id)
        participant
      end

    {room, participants}
  end

  defp active_room_with_members!(count) do
    {room, participants} = forming_room_with_members!(count)
    set_room_status!(room, :ACTIVE)
    {Repo.get!(HangoutRoom, room.room_id), participants}
  end

  defp set_room_status!(room, :ENDED) do
    room
    |> HangoutRoom.changeset(%{status: :ENDED, ended_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp set_room_status!(room, status) do
    room
    |> HangoutRoom.changeset(%{status: status, activated_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp membership!(room_id, participant_id) do
    Repo.one!(
      from m in HangoutMembership,
        where: m.room_id == ^room_id and m.participant_id == ^participant_id
    )
  end

  defp self_member(snapshot), do: Enum.find(snapshot.members, & &1.self)
  defp self_identity(snapshot), do: self_member(snapshot).identity

  defp track_room(room_id) do
    on_exit(fn ->
      if Code.ensure_loaded?(RoomServer) and function_exported?(RoomServer, :lookup, 1) do
        case RoomServer.lookup(room_id) do
          {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
          _ -> :ok
        end
      end
    end)
  end
end
