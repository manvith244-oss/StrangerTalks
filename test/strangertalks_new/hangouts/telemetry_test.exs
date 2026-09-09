defmodule StrangertalksNew.Hangouts.TelemetryTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{HangoutMembership, Matcher, RoomServer, Safety}
  alias StrangertalksNew.{Participants, Repo}

  @events [
    [:strangertalks_new, :hangout, :queue_entered],
    [:strangertalks_new, :hangout, :queue_cancelled],
    [:strangertalks_new, :hangout, :room_formed],
    [:strangertalks_new, :hangout, :room_activated],
    [:strangertalks_new, :hangout, :content_activated],
    [:strangertalks_new, :hangout, :first_human_message],
    [:strangertalks_new, :hangout, :message_accepted],
    [:strangertalks_new, :hangout, :first_response_after_content],
    [:strangertalks_new, :hangout, :reaction_accepted],
    [:strangertalks_new, :hangout, :skip_vote],
    [:strangertalks_new, :hangout, :content_advanced],
    [:strangertalks_new, :hangout, :disconnect],
    [:strangertalks_new, :hangout, :reconnect],
    [:strangertalks_new, :hangout, :leave],
    [:strangertalks_new, :hangout, :report],
    [:strangertalks_new, :hangout, :block],
    [:strangertalks_new, :hangout, :room_ended]
  ]

  setup do
    handler_id = "hangout-telemetry-#{System.unique_integer([:positive])}"
    receiver = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:hangout_telemetry, event, measurements, metadata})
        end,
        receiver
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "authoritative Hangout lifecycle emits the bounded experiment telemetry needed for V1 measurement" do
    language = "en-T01"
    [first, second, third, cancelled] = participants!(4)

    Enum.each([first, second, third, cancelled], fn participant ->
      assert {:ok, %{status: :queued}} = Matcher.enqueue(participant.participant_id, language)
      track_queue(participant.participant_id)
    end)

    assert :ok = Matcher.leave_queue(cancelled.participant_id)

    assert {:ok, formed} = Matcher.try_form(language)
    track_room(formed.room_id)
    assert formed.participant_ids == Enum.map([first, second, third], & &1.participant_id)

    assert {:ok, current} = RoomServer.current_content(formed.room_id)

    assert {:ok, %{sequence: 1}} =
             RoomServer.send_message(formed.room_id, first.participant_id, %{
               client_message_id: "telemetry-message-1",
               body: "private message text must never enter telemetry"
             })

    assert {:ok, %{sequence: 2}} =
             RoomServer.send_message(formed.room_id, second.participant_id, %{
               client_message_id: "telemetry-message-2",
               body: "second private message"
             })

    assert {:ok, _reaction} =
             RoomServer.add_reaction(
               formed.room_id,
               first.participant_id,
               current.sequence,
               "laugh"
             )

    assert {:ok, %{advanced: false}} =
             RoomServer.vote_skip(formed.room_id, first.participant_id, current.sequence)

    assert {:ok, %{advanced: true, content: advanced}} =
             RoomServer.vote_skip(formed.room_id, second.participant_id, current.sequence)

    assert advanced.sequence == current.sequence + 1

    assert {:ok, _snapshot} = RoomServer.disconnect(formed.room_id, third.participant_id)
    assert {:ok, _snapshot} = RoomServer.reconnect(formed.room_id, third.participant_id)

    target_identity = identity_for(formed.room_id, second.participant_id)

    assert {:ok, %{status: "submitted"}} =
             Safety.submit_report(formed.room_id, first.participant_id, %{
               client_report_id: "telemetry-report-1",
               target_identity_slot: target_identity.slot,
               category: "harassment",
               evidence: "private report evidence must never enter telemetry"
             })

    block_identity = identity_for(formed.room_id, third.participant_id)

    assert {:ok, %{status: "blocked"}} =
             Safety.block_member(formed.room_id, first.participant_id, block_identity.slot)

    assert {:ok, %{status: :LEFT}} = Hangouts.leave_room(formed.room_id, third.participant_id)
    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(formed.room_id)

    events = drain_events()
    emitted_names = events |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    assert MapSet.subset?(MapSet.new(@events), emitted_names)

    assert Enum.count(events, fn {name, _, _} ->
             name == [:strangertalks_new, :hangout, :first_response_after_content]
           end) == 1

    assert Enum.count(events, fn {name, _, _} ->
             name == [:strangertalks_new, :hangout, :skip_vote]
           end) == 2

    assert {_, formed_measurements, formed_metadata} =
             event!(events, [:strangertalks_new, :hangout, :room_formed])

    assert formed_measurements.count == 1
    assert formed_measurements.room_size == 3
    assert is_number(formed_measurements.formation_latency_ms)
    assert formed_measurements.formation_latency_ms >= 0
    assert formed_metadata.experiment_arm == :GROUP_WITH_CONTENT

    message_events = events_for(events, [:strangertalks_new, :hangout, :message_accepted])
    assert Enum.map(message_events, fn {_, measurements, _} -> measurements.message_sequence end) == [1, 2]

    assert {_, ended_measurements, ended_metadata} =
             event!(events, [:strangertalks_new, :hangout, :room_ended])

    assert ended_measurements.message_count == 2
    assert ended_measurements.distinct_participant_count == 2
    assert is_number(ended_measurements.duration_ms)
    assert ended_measurements.duration_ms >= 0
    assert ended_metadata.experiment_arm == :GROUP_WITH_CONTENT

    encoded = inspect(events)

    for participant <- [first, second, third, cancelled] do
      refute encoded =~ participant.participant_id
    end

    refute encoded =~ "telemetry-message-1"
    refute encoded =~ "private message text must never enter telemetry"
    refute encoded =~ "private report evidence must never enter telemetry"

    assert Enum.all?(events, fn {_name, _measurements, metadata} ->
             Enum.all?(Map.keys(metadata), fn key ->
               not String.ends_with?(to_string(key), "_id")
             end)
           end)
  end

  test "control rooms preserve experiment arm and never emit shared-content activation telemetry" do
    [first, second, third] = participants!(3)

    assert {:ok, %{room: room}} =
             Hangouts.create_formed_room(
               Enum.map([first, second, third], & &1.participant_id),
               %{
                 language_tag: "en-T02",
                 experiment_arm: :GROUP_NO_CONTENT,
                 minimum_size: 3,
                 target_size: 4,
                 max_size: 6
               }
             )

    track_room(room.room_id)
    assert {:ok, _pid} = RoomServer.ensure_started(room.room_id)

    assert {:ok, %{sequence: 1}} =
             RoomServer.send_message(room.room_id, first.participant_id, %{
               client_message_id: "control-message-1",
               body: "control message"
             })

    assert {:ok, %{status: :ENDED}} = RoomServer.end_room(room.room_id)

    events = drain_events()

    assert {_, _, metadata} =
             event!(events, [:strangertalks_new, :hangout, :message_accepted])

    assert metadata.experiment_arm == :GROUP_NO_CONTENT

    refute Enum.any?(events, fn {name, _, _} ->
             name == [:strangertalks_new, :hangout, :content_activated]
           end)
  end

  defp event!(events, name), do: Enum.find(events, fn {event, _, _} -> event == name end)

  defp events_for(events, name),
    do: Enum.filter(events, fn {event, _, _} -> event == name end)

  defp drain_events(acc \\ []) do
    receive do
      {:hangout_telemetry, event, measurements, metadata} ->
        drain_events([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp participants!(count), do: Enum.map(1..count, fn _ -> participant!() end)

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp identity_for(room_id, participant_id) do
    membership =
      Repo.get_by!(HangoutMembership, room_id: room_id, participant_id: participant_id)

    %{
      slot: membership.temporary_identity_slot,
      label: membership.temporary_identity_label,
      emoji: membership.temporary_identity_emoji
    }
  end

  defp track_queue(participant_id) do
    on_exit(fn ->
      try do
        Matcher.leave_queue(participant_id)
      catch
        :exit, _reason -> :ok
      end
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
