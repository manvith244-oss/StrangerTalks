defmodule StrangertalksNew.Hangouts.ContextTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, HangoutMessage, HangoutRoom}
  alias StrangertalksNew.{Participants, Repo}

  test "create_room owns lifecycle defaults and ignores protected state" do
    assert {:ok, room} =
             Hangouts.create_room(%{
               language_tag: "pt-BR",
               experiment_arm: :GROUP_WITH_CONTENT,
               minimum_size: 3,
               target_size: 4,
               max_size: 6,
               status: :ACTIVE,
               message_sequence: 99,
               content_sequence: 77,
               activated_at: DateTime.utc_now(),
               ended_at: DateTime.utc_now()
             })

    assert room.status == :FORMING
    assert room.language_tag == "pt-BR"
    assert room.experiment_arm == :GROUP_WITH_CONTENT
    assert room.minimum_size == 3
    assert room.target_size == 4
    assert room.max_size == 6
    assert room.message_sequence == 0
    assert room.content_sequence == 0
    assert is_nil(room.activated_at)
    assert is_nil(room.ended_at)
    assert %DateTime{} = room.created_at
  end

  test "create_room rejects malformed capacity without partial persistence" do
    before_count = Repo.aggregate(HangoutRoom, :count, :room_id)

    assert {:error, :invalid_room, changeset} =
             Hangouts.create_room(%{
               language_tag: "en",
               minimum_size: 5,
               target_size: 4,
               max_size: 4
             })

    refute changeset.valid?
    assert Repo.aggregate(HangoutRoom, :count, :room_id) == before_count
  end

  test "concurrent competing admissions allow one active Hangout only" do
    participant = participant!()
    room_a = room!()
    room_b = room!()

    results =
      [room_a.room_id, room_b.room_id]
      |> Task.async_stream(
        &Hangouts.add_member(&1, participant.participant_id),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %HangoutMembership{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :already_in_hangout}, &1)) == 1

    active_count =
      Repo.aggregate(
        from(m in HangoutMembership,
          where:
            m.participant_id == ^participant.participant_id and
              m.status in [:ACTIVE, :DISCONNECTED]
        ),
        :count,
        :membership_id
      )

    assert active_count == 1
  end

  test "member admission allocates unique room identities and public snapshot redacts persistent ids" do
    room = room!()
    first = participant!()
    second = participant!()

    assert {:ok, first_membership} = Hangouts.add_member(room.room_id, first.participant_id)
    assert {:ok, second_membership} = Hangouts.add_member(room.room_id, second.participant_id)

    refute first_membership.temporary_identity_slot == second_membership.temporary_identity_slot

    assert {:ok, internal} = Hangouts.internal_room_snapshot(room.room_id)
    assert Enum.any?(internal.members, &(&1.participant_id == first.participant_id))

    assert {:ok, public} = Hangouts.room_snapshot(room.room_id, first.participant_id)
    assert public.room_id == room.room_id
    assert public.message_sequence == 0
    assert public.content_sequence == 0
    assert length(public.members) == 2
    assert Enum.count(public.members, & &1.self) == 1

    encoded = inspect(public)
    refute encoded =~ first.participant_id
    refute encoded =~ second.participant_id
    refute encoded =~ first_membership.membership_id
    refute encoded =~ second_membership.membership_id

    assert Enum.all?(public.members, fn member ->
             Map.keys(member) |> Enum.sort() == [:identity, :self, :status]
           end)
  end

  test "leave is authoritative, idempotent, releases active-room uniqueness, and blocks messaging" do
    participant = participant!()
    room = active_room!()

    assert {:ok, membership} = Hangouts.add_member(room.room_id, participant.participant_id)
    assert membership.status == :ACTIVE

    assert {:ok, left} = Hangouts.leave_room(room.room_id, participant.participant_id)
    assert left.status == :LEFT
    assert %DateTime{} = left.left_at

    assert {:ok, same_left} = Hangouts.leave_room(room.room_id, participant.participant_id)
    assert same_left.membership_id == left.membership_id
    assert same_left.left_at == left.left_at

    assert {:error, :membership_not_active} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "after-leave",
               body: "should not send"
             })

    replacement = room!()
    assert {:ok, replacement_membership} =
             Hangouts.add_member(replacement.room_id, participant.participant_id)

    assert replacement_membership.status == :ACTIVE
  end

  test "append_message serializes concurrent sends into a gapless authoritative sequence" do
    room = active_room!()

    participants =
      for _ <- 1..6 do
        participant = participant!()
        assert {:ok, _} = Hangouts.add_member(room.room_id, participant.participant_id)
        participant
      end

    sends =
      participants
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {participant, index} ->
          Hangouts.append_message(room.room_id, participant.participant_id, %{
            client_message_id: "concurrent-#{index}",
            body: "message #{index}"
          })
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(sends, &match?({:ok, %HangoutMessage{}}, &1))

    sequences =
      sends
      |> Enum.map(fn {:ok, message} -> message.sequence end)
      |> Enum.sort()

    assert sequences == Enum.to_list(1..6)
    assert Repo.get!(HangoutRoom, room.room_id).message_sequence == 6
  end

  test "message retry is idempotent but a conflicting payload cannot mutate the accepted message" do
    room = active_room!()
    participant = participant!()
    assert {:ok, membership} = Hangouts.add_member(room.room_id, participant.participant_id)

    attrs = %{client_message_id: "retry-1", body: "same body"}
    assert {:ok, first} = Hangouts.append_message(room.room_id, participant.participant_id, attrs)
    assert {:ok, retry} = Hangouts.append_message(room.room_id, participant.participant_id, attrs)

    assert retry.message_id == first.message_id
    assert retry.sequence == first.sequence
    assert Repo.get!(HangoutRoom, room.room_id).message_sequence == 1

    assert {:error, :idempotency_conflict} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "retry-1",
               body: "different body"
             })

    persisted = Repo.get!(HangoutMessage, first.message_id)
    assert persisted.body == "same body"
    assert persisted.membership_id == membership.membership_id
    assert Repo.get!(HangoutRoom, room.room_id).message_sequence == 1
  end

  test "message authority ignores spoofed membership and sequence fields" do
    room = active_room!()
    participant = participant!()
    assert {:ok, membership} = Hangouts.add_member(room.room_id, participant.participant_id)

    assert {:ok, message} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "authority-1",
               body: "canonical",
               membership_id: Ecto.UUID.generate(),
               sequence: 999
             })

    assert message.membership_id == membership.membership_id
    assert message.sequence == 1
  end

  test "invalid messages roll back sequence and byte limits use UTF-8 bytes" do
    room = active_room!()
    participant = participant!()
    assert {:ok, _} = Hangouts.add_member(room.room_id, participant.participant_id)

    assert {:error, :invalid_message, blank_changeset} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "blank",
               body: "   "
             })

    refute blank_changeset.valid?
    assert Repo.get!(HangoutRoom, room.room_id).message_sequence == 0

    boundary = String.duplicate("a", HangoutMessage.max_body_bytes())

    assert {:ok, boundary_message} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "boundary",
               body: boundary
             })

    assert byte_size(boundary_message.body) == HangoutMessage.max_body_bytes()

    assert {:ok, unicode} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "unicode",
               body: "తెలుగు 🌙"
             })

    assert String.valid?(unicode.body)

    oversized = String.duplicate("a", HangoutMessage.max_body_bytes() + 1)

    assert {:error, :invalid_message, oversized_changeset} =
             Hangouts.append_message(room.room_id, participant.participant_id, %{
               client_message_id: "oversized",
               body: oversized
             })

    assert "is too large" in errors_on(oversized_changeset).body
    assert Repo.get!(HangoutRoom, room.room_id).message_sequence == 2
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
    room
  end

  defp active_room! do
    room = room!()
    now = DateTime.utc_now()

    room
    |> HangoutRoom.changeset(%{status: :ACTIVE, activated_at: now})
    |> Repo.update!()
  end
end
