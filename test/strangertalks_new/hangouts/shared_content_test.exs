defmodule StrangertalksNew.Hangouts.SharedContentTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{ContentCatalog, HangoutRoom, RoomServer}
  alias StrangertalksNew.{Participants, Repo}

  @pubsub StrangertalksNew.PubSub

  test "GROUP_WITH_CONTENT boots one durable approved shared stimulus" do
    {room, [participant | _]} = active_room!(:GROUP_WITH_CONTENT, "en")

    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, snapshot} = RoomServer.snapshot(room.room_id, participant.participant_id)

    assert snapshot.content_sequence == 1

    assert %{id: content_id, safety_status: :APPROVED, publication_status: :ACTIVE} =
             snapshot.current_content

    persisted = Repo.get!(HangoutRoom, room.room_id)
    assert persisted.current_content_id == content_id
    assert persisted.content_sequence == 1
    assert %DateTime{} = persisted.current_content_started_at
  end

  test "GROUP_NO_CONTENT never receives shared-content authority" do
    {room, [participant | _]} = active_room!(:GROUP_NO_CONTENT, "en")

    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, snapshot} = RoomServer.snapshot(room.room_id, participant.participant_id)

    assert snapshot.current_content == nil
    assert snapshot.content_sequence == 0
    assert {:error, :content_disabled} = RoomServer.advance_content(room.room_id)

    persisted = Repo.get!(HangoutRoom, room.room_id)
    assert is_nil(persisted.current_content_id)
    assert is_nil(persisted.current_content_started_at)
  end

  test "advance_content persists before broadcasting the next canonical item" do
    {room, [_participant | _]} = active_room!(:GROUP_WITH_CONTENT, "en")
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert :ok = Phoenix.PubSub.subscribe(@pubsub, "hangout:#{room.room_id}")

    assert {:ok, first} = RoomServer.current_content(room.room_id)
    assert first.sequence == 1

    assert {:ok, second} = RoomServer.advance_content(room.room_id)
    assert second.sequence == 2
    refute second.content.id == first.content.id
    assert %DateTime{} = second.started_at

    persisted = Repo.get!(HangoutRoom, room.room_id)
    assert persisted.current_content_id == second.content.id
    assert persisted.content_sequence == 2
    assert persisted.current_content_started_at == second.started_at

    assert_receive {:hangout_event, "content:changed", ^second}
  end

  test "restart reconstructs the exact durable current content without advancing" do
    {room, [_participant | _]} = active_room!(:GROUP_WITH_CONTENT, "en")
    assert {:ok, pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, advanced} = RoomServer.advance_content(room.room_id)

    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert {:ok, replacement} = RoomServer.ensure_started(room.room_id)
    refute replacement == pid

    assert {:ok, rebuilt} = RoomServer.current_content(room.room_id)
    assert rebuilt == advanced
  end

  test "extensible languages use only catalog-approved localized or neutral content" do
    {room, [_participant | _]} = active_room!(:GROUP_WITH_CONTENT, "pt-BR")
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)

    assert {:ok, current} = RoomServer.current_content(room.room_id)
    assert current.content in ContentCatalog.items("pt-BR")
    assert current.content.language_tag in ["pt-BR", "und"]
    assert current.content.source == :FIRST_PARTY
    assert current.content.safety_status == :APPROVED
    assert current.content.publication_status == :ACTIVE

    assert Repo.get!(HangoutRoom, room.room_id).language_tag == "pt-BR"
  end

  test "ENDED rooms cannot advance or resurrect shared content" do
    {room, [_participant | _]} = active_room!(:GROUP_WITH_CONTENT, "en")
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    assert {:ok, before_end} = RoomServer.current_content(room.room_id)
    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(room.room_id)

    assert {:error, :terminal_room} = RoomServer.advance_content(room.room_id)

    persisted = Repo.get!(HangoutRoom, room.room_id)
    assert persisted.status == :ENDED
    assert persisted.current_content_id == before_end.content.id
    assert persisted.content_sequence == before_end.sequence
  end

  defp active_room!(experiment_arm, language_tag) do
    participants = for _ <- 1..3, do: participant!()

    {:ok, %{room: room}} =
      Hangouts.create_formed_room(
        Enum.map(participants, & &1.participant_id),
        %{
          language_tag: language_tag,
          experiment_arm: experiment_arm,
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

  defp track_room(room_id) do
    on_exit(fn ->
      case RoomServer.lookup(room_id) do
        {:ok, pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
        _ -> :ok
      end
    end)
  end
end
