defmodule StrangertalksNewWeb.HangoutLobbyChannelTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, HangoutRoom, Matcher, RoomServer}
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.{Participants, Repo}
  alias StrangertalksNewWeb.{HangoutLobbyChannel, ParticipantToken, UserSocket}

  test "UserSocket routes hangout_lobby topic and authenticated participant joins lobby while spoofed topic is rejected" do
    source = File.read!("lib/strangertalks_new_web/user_socket.ex")
    assert source =~ ~s(channel "hangout_lobby:*")
    assert source =~ "StrangertalksNewWeb.HangoutLobbyChannel"

    alice = participant!()
    bob = participant!()

    assert :error = connect(UserSocket, %{})

    alice_socket = connected_socket(alice)

    assert {:ok, reply, socket} =
             subscribe_and_join(
               alice_socket,
               HangoutLobbyChannel,
               "hangout_lobby:#{alice.participant_id}",
               %{}
             )

    assert socket.assigns.participant_id == alice.participant_id
    assert reply.status == "connected"

    assert {:error, %{reason: "participant_mismatch"}} =
             subscribe_and_join(
               alice_socket,
               HangoutLobbyChannel,
               "hangout_lobby:#{bob.participant_id}",
               %{}
             )
  end

  test "queue:join accepts only expected intent fields and supports extensible language tags" do
    participant = participant!()
    {:ok, _reply, socket} = join_lobby(participant)

    ref = push(socket, "queue:join", %{"language_tag" => "en-US"})
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: queue_attempt_id}
    assert is_binary(queue_attempt_id)
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^queue_attempt_id}

    # Cancel so we can test other intent forms
    cancel_ref = push(socket, "queue:cancel", %{})
    assert_reply cancel_ref, :ok, %{status: "idle"}
    assert_push "queue:status", %{status: "idle"}

    # Extensible custom language tag works
    custom_ref = push(socket, "queue:join", %{"language_tag" => "tlh-Klng"})
    assert_reply custom_ref, :ok, %{status: "queued"}
    _ = push(socket, "queue:cancel", %{})

    # Spoofed participant_id in intent rejected
    spoofed_ref =
      push(socket, "queue:join", %{
        "language_tag" => "en",
        "participant_id" => Ecto.UUID.generate()
      })

    assert_reply spoofed_ref, :error, %{reason: "invalid_intent"}

    # Missing language_tag rejected
    empty_ref = push(socket, "queue:join", %{})
    assert_reply empty_ref, :error, %{reason: "invalid_intent"}

    # Blank/invalid language tag rejected
    invalid_ref = push(socket, "queue:join", %{"language_tag" => ""})
    assert_reply invalid_ref, :error, %{reason: "invalid_language_tag"}
  end

  test "duplicate queue:join is idempotent for same language and rejects different language while queued" do
    participant = participant!()
    {:ok, _reply, socket} = join_lobby(participant)

    ref1 = push(socket, "queue:join", %{"language_tag" => "es-419"})
    assert_reply ref1, :ok, %{status: "queued", queue_attempt_id: id1}

    ref2 = push(socket, "queue:join", %{"language_tag" => "es-419"})
    assert_reply ref2, :ok, %{status: "queued", queue_attempt_id: id2}
    assert id1 == id2

    conflict_ref = push(socket, "queue:join", %{"language_tag" => "pt-BR"})
    assert_reply conflict_ref, :error, %{reason: "already_queued"}

    cancel_ref = push(socket, "queue:cancel", %{})
    assert_reply cancel_ref, :ok, %{status: "idle"}

    ref3 = push(socket, "queue:join", %{"language_tag" => "pt-BR"})
    assert_reply ref3, :ok, %{status: "queued", queue_attempt_id: id3}
    refute id3 == id1
  end

  test "active or disconnected Hangout member is rejected from queueing" do
    participant = participant!()
    {room, _members} = active_room!()

    {:ok, _membership} = Hangouts.add_member(room.room_id, participant.participant_id)
    {:ok, _reply, socket} = join_lobby(participant)

    ref = push(socket, "queue:join", %{"language_tag" => "en"})
    assert_reply ref, :error, %{reason: "already_in_hangout"}

    {:ok, disconnected} = Hangouts.disconnect_member(room.room_id, participant.participant_id)
    assert disconnected.status == :DISCONNECTED

    ref2 = push(socket, "queue:join", %{"language_tag" => "en"})
    assert_reply ref2, :error, %{reason: "already_in_hangout"}
  end

  test "successful formation notifies only authorized participants with room ID" do
    language = "en-LOBBY-01"
    [p1, p2, p3] = participants!(3)
    outsider = participant!()

    {:ok, _reply, s1} = join_lobby(p1)
    {:ok, _reply, s2} = join_lobby(p2)
    {:ok, _reply, s3} = join_lobby(p3)
    {:ok, _reply, _s_out} = join_lobby(outsider)

    ref1 = push(s1, "queue:join", %{"language_tag" => language})
    assert_reply ref1, :ok, %{status: "queued"}

    ref2 = push(s2, "queue:join", %{"language_tag" => language})
    assert_reply ref2, :ok, %{status: "queued"}

    ref3 = push(s3, "queue:join", %{"language_tag" => language})
    assert_reply ref3, :ok, %{status: "queued"}

    assert_push "room:formed", %{room_id: room_id1, status: "formed"}
    assert is_binary(room_id1)
    track_room(room_id1)

    room = Repo.get!(HangoutRoom, room_id1)
    assert room.status == :ACTIVE

    memberships =
      Repo.all(
        from m in HangoutMembership, where: m.room_id == ^room_id1, select: m.participant_id
      )

    assert MapSet.new(memberships) ==
             MapSet.new([p1.participant_id, p2.participant_id, p3.participant_id])

    refute outsider.participant_id in memberships
  end

  test "one-to-one queue state is not mutated when entering or leaving Hangout lobby" do
    participant = participant!()
    matches_before = pair_match_count()

    {:ok, _reply, socket} = join_lobby(participant)

    ref = push(socket, "queue:join", %{"language_tag" => "en-ISO"})
    assert_reply ref, :ok, %{status: "queued"}

    cancel_ref = push(socket, "queue:cancel", %{})
    assert_reply cancel_ref, :ok, %{status: "idle"}

    assert pair_match_count() == matches_before
  end

  test "blocked participants are never grouped into the same formed room" do
    language = "en-BLOCK-01"
    [a, b, c, d] = participants!(4)

    assert {:ok, _block} =
             MatchingRules.enforce_block(a.participant_id, b.participant_id, "HANGOUT")

    {:ok, _reply, sa} = join_lobby(a)
    {:ok, _reply, sb} = join_lobby(b)
    {:ok, _reply, sc} = join_lobby(c)
    {:ok, _reply, sd} = join_lobby(d)

    ref_a = push(sa, "queue:join", %{"language_tag" => language})
    assert_reply ref_a, :ok, _
    ref_b = push(sb, "queue:join", %{"language_tag" => language})
    assert_reply ref_b, :ok, _
    ref_c = push(sc, "queue:join", %{"language_tag" => language})
    assert_reply ref_c, :ok, _
    ref_d = push(sd, "queue:join", %{"language_tag" => language})
    assert_reply ref_d, :ok, _

    assert_push "room:formed", %{room_id: room_id, status: "formed"}
    track_room(room_id)

    room_members =
      Repo.all(
        from m in HangoutMembership, where: m.room_id == ^room_id, select: m.participant_id
      )

    assert length(room_members) == 3
    refute a.participant_id in room_members and b.participant_id in room_members
  end

  defp join_lobby(participant) do
    socket = connected_socket(participant)

    subscribe_and_join(
      socket,
      HangoutLobbyChannel,
      "hangout_lobby:#{participant.participant_id}",
      %{}
    )
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    track_queue(participant.participant_id)
    participant
  end

  defp participants!(count), do: Enum.map(1..count, fn _ -> participant!() end)

  defp active_room!(experiment_arm \\ :GROUP_WITH_CONTENT) do
    participants = for _ <- 1..3, do: participant!()

    {:ok, %{room: room}} =
      Hangouts.create_formed_room(
        Enum.map(participants, & &1.participant_id),
        %{
          language_tag: "en",
          experiment_arm: experiment_arm,
          minimum_size: 3,
          target_size: 4,
          max_size: 6
        }
      )

    track_room(room.room_id)
    {room, participants}
  end

  defp pair_match_count do
    [[count]] = Repo.query!("SELECT count(*) FROM matches").rows
    count
  end

  defp track_queue(participant_id) do
    on_exit(fn ->
      if Code.ensure_loaded?(Matcher) and function_exported?(Matcher, :leave_queue, 1) and
           Process.whereis(Matcher) do
        _ = Matcher.leave_queue(participant_id)
      end
    end)
  end

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
