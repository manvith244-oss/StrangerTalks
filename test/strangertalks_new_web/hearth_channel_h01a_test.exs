defmodule StrangertalksNewWeb.HearthChannelH01aTest do
  use StrangertalksNew.DataCase, async: false

  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.{HearthChannel, ParticipantToken, UserSocket}

  setup do
    previous = Application.get_env(:strangertalks_new, :experiment_hearth_enabled, false)
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, true)

    on_exit(fn ->
      Application.put_env(:strangertalks_new, :experiment_hearth_enabled, previous)
    end)

    :ok
  end

  test "treatment telemetry carries anonymous bridge and room correlation ids end to end" do
    events = correlated_events()
    attach_telemetry(events)

    alice = participant!()
    bob = participant!()
    {:ok, _reply, alice_socket} = join_treatment(alice)
    {:ok, _reply, bob_socket} = join_treatment(bob)

    ref = push(alice_socket, "hearth:submit", %{"contribution" => "Air fryer"})
    assert_reply ref, :ok, %{status: "waiting"}

    ref = push(bob_socket, "hearth:submit", %{"contribution" => "Running shoes"})
    assert_reply ref, :ok, %{status: "bridge_offered", bridge_id: bridge_id}
    assert_push "bridge:offered", %{bridge_id: ^bridge_id}
    assert_push "bridge:offered", %{bridge_id: ^bridge_id}

    ref = push(alice_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref, :ok, %{status: "waiting_for_partner"}

    ref = push(bob_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref, :ok, %{status: "room_ready", room_id: room_id}
    assert_push "room:ready", %{room_id: ^room_id}
    assert_push "room:ready", %{room_id: ^room_id}

    ref = push(alice_socket, "room:message", %{"room_id" => room_id, "content" => "hello"})
    assert_reply ref, :ok, %{status: "delivered", turn_number: 1}
    assert_push "room:message", %{room_id: ^room_id, content: "hello", turn_number: 1}

    ref = push(alice_socket, "room:leave", %{"room_id" => room_id})
    assert_reply ref, :ok, %{status: "ended"}
    assert_push "room:partner_disconnected", %{room_id: ^room_id}

    feedback_ref = push(alice_socket, "experiment:feedback", %{"reason" => "good_chat"})
    assert_reply feedback_ref, :ok, %{status: "recorded"}

    telemetry = collect_telemetry([])
    rendered = inspect(telemetry)
    refute rendered =~ alice.participant_id
    refute rendered =~ bob.participant_id
    refute rendered =~ "Air fryer"
    refute rendered =~ "Running shoes"
    refute rendered =~ "hello"

    assert_event_metadata(telemetry, :bridge_offered, %{bridge_id: bridge_id})
    assert_event_metadata(telemetry, :bridge_step_in, %{bridge_id: bridge_id})
    assert_event_metadata(telemetry, :experiment_room_started, %{room_id: room_id})
    assert_event_metadata(telemetry, :experiment_turn, %{room_id: room_id, turn_number: 1})
    assert_event_metadata(telemetry, :experiment_first_message, %{room_id: room_id})

    assert_event_metadata(telemetry, :experiment_room_ended, %{
      room_id: room_id,
      reason: :explicit_leave
    })

    assert_event_metadata(telemetry, :experiment_exit_reason, %{
      room_id: room_id,
      reason: "good_chat"
    })
  end

  test "control room telemetry uses the same anonymous room correlation contract" do
    attach_telemetry(correlated_events())

    alice = participant_for_variant!(:control)
    bob = participant_for_variant!(:control)
    {:ok, _reply, alice_socket} = join_auto(alice)
    {:ok, _reply, bob_socket} = join_auto(bob)

    ref = push(alice_socket, "control:connect", %{})
    assert_reply ref, :ok, %{status: "waiting"}

    ref = push(bob_socket, "control:connect", %{})
    assert_reply ref, :ok, %{status: "room_ready", room_id: room_id}
    assert_push "room:ready", %{room_id: ^room_id, variant: "control"}
    assert_push "room:ready", %{room_id: ^room_id, variant: "control"}

    ref = push(bob_socket, "room:message", %{"room_id" => room_id, "content" => "hi"})
    assert_reply ref, :ok, %{status: "delivered", turn_number: 1}
    assert_push "room:message", %{room_id: ^room_id, content: "hi", turn_number: 1}

    ref = push(bob_socket, "room:leave", %{"room_id" => room_id})
    assert_reply ref, :ok, %{status: "ended"}
    assert_push "room:partner_disconnected", %{room_id: ^room_id}

    telemetry = collect_telemetry([])
    assert_event_metadata(telemetry, :experiment_room_started, %{room_id: room_id})
    assert_event_metadata(telemetry, :experiment_turn, %{room_id: room_id, turn_number: 1})
    assert_event_metadata(telemetry, :experiment_first_message, %{room_id: room_id})

    assert_event_metadata(telemetry, :experiment_room_ended, %{
      room_id: room_id,
      reason: :explicit_leave
    })
  end

  test "feedback is rejected before an encounter ends and is one-shot afterward" do
    event = [:strangertalks_new, :experiment, :hearth, :experiment_exit_reason]
    attach_telemetry([event])

    alice = participant_for_variant!(:control)
    bob = participant_for_variant!(:control)
    {:ok, _reply, alice_socket} = join_auto(alice)
    {:ok, _reply, bob_socket} = join_auto(bob)

    premature = push(alice_socket, "experiment:feedback", %{"reason" => "good_chat"})
    assert_reply premature, :error, %{reason: "no_completed_encounter"}
    refute_receive {:telemetry_seen, ^event, _, _}, 20

    ref = push(alice_socket, "control:connect", %{})
    assert_reply ref, :ok, %{status: "waiting"}
    ref = push(bob_socket, "control:connect", %{})
    assert_reply ref, :ok, %{room_id: room_id}
    assert_push "room:ready", %{room_id: ^room_id}
    assert_push "room:ready", %{room_id: ^room_id}

    ref = push(alice_socket, "room:leave", %{"room_id" => room_id})
    assert_reply ref, :ok, %{status: "ended"}
    assert_push "room:partner_disconnected", %{room_id: ^room_id}

    first = push(alice_socket, "experiment:feedback", %{"reason" => "good_chat"})
    assert_reply first, :ok, %{status: "recorded"}

    assert_receive {:telemetry_seen, ^event, %{count: 1}, metadata}
    assert metadata.room_id == room_id
    assert metadata.reason == "good_chat"

    second = push(alice_socket, "experiment:feedback", %{"reason" => "ran_out"})
    assert_reply second, :error, %{reason: "no_completed_encounter"}
    refute_receive {:telemetry_seen, ^event, _, _}, 20
  end

  defp join_treatment(participant) do
    subscribe_and_join(
      connected_socket(participant),
      HearthChannel,
      "hearth:#{participant.participant_id}",
      %{}
    )
  end

  defp join_auto(participant) do
    subscribe_and_join(
      connected_socket(participant),
      HearthChannel,
      "hearth:#{participant.participant_id}",
      %{"variant" => "auto"}
    )
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp participant_for_variant!(variant, attempts \\ 40)

  defp participant_for_variant!(variant, attempts) when attempts > 0 do
    participant = participant!()

    if HearthChannel.assigned_variant(participant.participant_id) == variant do
      participant
    else
      participant_for_variant!(variant, attempts - 1)
    end
  end

  defp participant_for_variant!(variant, 0),
    do: flunk("could not issue participant for #{inspect(variant)}")

  defp correlated_events do
    Enum.map(
      [
        :bridge_offered,
        :bridge_step_in,
        :bridge_passed,
        :bridge_expired,
        :experiment_room_started,
        :experiment_turn,
        :experiment_first_message,
        :experiment_room_ended,
        :experiment_exit_reason
      ],
      &[:strangertalks_new, :experiment, :hearth, &1]
    )
  end

  defp attach_telemetry(events) do
    handler_id = "hearth-h01a-correlation-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_seen, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry_seen, event, measurements, metadata} ->
        collect_telemetry([{event, measurements, metadata} | acc])
    after
      40 -> Enum.reverse(acc)
    end
  end

  defp assert_event_metadata(telemetry, event_name, expected) do
    assert Enum.any?(telemetry, fn {event, _measurements, metadata} ->
             List.last(event) == event_name and
               Enum.all?(expected, fn {key, value} -> Map.get(metadata, key) == value end)
           end),
           "expected #{inspect(event_name)} metadata to include #{inspect(expected)}, got: #{inspect(telemetry)}"
  end
end
