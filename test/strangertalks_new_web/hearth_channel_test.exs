defmodule StrangertalksNewWeb.HearthChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Experiments.Hearth.Authority
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

  test "UserSocket routes isolated hearth topic and disabled experiment refuses admission" do
    source = File.read!("lib/strangertalks_new_web/user_socket.ex")
    assert source =~ ~s(channel "hearth:*")
    assert source =~ "StrangertalksNewWeb.HearthChannel"

    participant = participant!()
    socket = connected_socket(participant)

    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, false)

    assert {:error, %{reason: "experiment_disabled"}} =
             subscribe_and_join(
               socket,
               HearthChannel,
               "hearth:#{participant.participant_id}",
               %{}
             )
  end

  test "auto variant follows deterministic participant assignment instead of the empty-map fallback" do
    participant = participant_for_variant!(:control)

    assert {:ok, %{status: "control_ready", variant: "control"}, socket} =
             join_auto(participant)

    assert socket.assigns.hearth_variant == :control
  end

  test "control participants pair directly into a blank room without bridge or residue exposure" do
    alice = participant_for_variant!(:control)
    bob = participant_for_variant!(:control)

    assert {:ok, alice_reply, alice_socket} = join_auto(alice)
    assert {:ok, bob_reply, bob_socket} = join_auto(bob)
    assert alice_reply == %{status: "control_ready", variant: "control"}
    assert bob_reply == %{status: "control_ready", variant: "control"}
    refute Map.has_key?(alice_reply, :recent)
    refute Map.has_key?(bob_reply, :recent)

    ref = push(alice_socket, "control:connect", %{})
    assert_reply ref, :ok, %{status: "waiting"}

    ref = push(bob_socket, "control:connect", %{})
    assert_reply ref, :ok, %{status: "room_ready", room_id: room_id}

    assert_push "room:ready", %{
      room_id: ^room_id,
      variant: "control",
      own_anchor: nil,
      partner_anchor: nil
    }

    assert_push "room:ready", %{
      room_id: ^room_id,
      variant: "control",
      own_anchor: nil,
      partner_anchor: nil
    }

    refute_push "bridge:offered", _payload, 20
  end

  test "authenticated treatment participants receive bridge offers and require mutual Step In" do
    {alice_socket, bob_socket, bridge_id} = create_bridge()

    ref1 = push(alice_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref1, :ok, %{status: "waiting_for_partner"}

    ref2 = push(bob_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref2, :ok, %{status: "room_ready", room_id: room_id}
    assert is_binary(room_id)

    assert_push "room:ready", %{room_id: ^room_id}
    assert_push "room:ready", %{room_id: ^room_id}
  end

  test "room message is ephemeral, bounded like canonical text, and delivered only to the partner" do
    {alice_socket, bob_socket, room_id} = create_room()
    content = "I bought it for a version of me that never showed up"

    ref =
      push(alice_socket, "room:message", %{
        "room_id" => room_id,
        "content" => content
      })

    assert_reply ref, :ok, %{status: "delivered", turn_number: 1}
    assert_push "room:message", %{room_id: ^room_id, content: ^content, turn_number: 1}

    too_large = String.duplicate("x", ConversationServer.max_message_bytes() + 1)

    ref =
      push(bob_socket, "room:message", %{
        "room_id" => room_id,
        "content" => too_large
      })

    assert_reply ref, :error, %{reason: "message_too_large"}
    assert Authority.snapshot(Authority).turn_count >= 1
    refute inspect(Authority.snapshot(Authority)) =~ content
  end

  test "explicit Leave destroys delivery immediately and tells only the partner that the room ended" do
    {alice_socket, bob_socket, room_id} = create_room()

    leave_ref = push(alice_socket, "room:leave", %{"room_id" => room_id})
    assert_reply leave_ref, :ok, %{status: "ended"}
    assert_push "room:partner_disconnected", %{room_id: ^room_id}

    message_ref =
      push(bob_socket, "room:message", %{
        "room_id" => room_id,
        "content" => "This must not deliver"
      })

    assert_reply message_ref, :error, %{reason: "no_room"}
  end

  test "pass dissolves bridge and survivor receives neutral reset, never a rejection alert" do
    {alice_socket, _bob_socket, bridge_id} = create_bridge()

    pass_ref = push(alice_socket, "bridge:pass", %{"bridge_id" => bridge_id})
    assert_reply pass_ref, :ok, %{status: "hearth_viewed"}
    assert_push "bridge:dissolved", %{bridge_id: ^bridge_id}
    refute_push "bridge:rejected", _payload, 20
  end

  test "channel terminate dissolves participant bridge state and neutrally resets survivor" do
    {alice_socket, _bob_socket, bridge_id} = create_bridge()
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    close(alice_socket)

    assert_push "bridge:dissolved", %{bridge_id: ^bridge_id}

    assert {:error, :no_offer} =
             Authority.step_in(Authority, participant_id_from_bridge_survivor(), bridge_id)
  end

  test "treatment telemetry omits participant ids, Hearth inputs, and chat bodies" do
    events = privacy_events()
    attach_telemetry(events)

    alice = participant!()
    bob = participant!()
    {:ok, _reply, alice_socket} = join_hearth(alice)
    {:ok, _reply, bob_socket} = join_hearth(bob)

    secret_anchor = "SECRET_ANCHOR_92831"
    secret_message = "SECRET_MESSAGE_51729"

    ref = push(alice_socket, "hearth:submit", %{"contribution" => secret_anchor})
    assert_reply ref, :ok, %{status: "waiting"}

    ref = push(bob_socket, "hearth:submit", %{"contribution" => "Running shoes"})
    assert_reply ref, :ok, %{bridge_id: bridge_id}
    flush_bridge_offers()

    ref = push(alice_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref, :ok, %{status: "waiting_for_partner"}
    ref = push(bob_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref, :ok, %{room_id: room_id}
    flush_room_ready()

    ref = push(alice_socket, "room:message", %{"room_id" => room_id, "content" => secret_message})
    assert_reply ref, :ok, %{status: "delivered"}

    ref = push(alice_socket, "room:leave", %{"room_id" => room_id})
    assert_reply ref, :ok, %{status: "ended"}

    telemetry = collect_telemetry([])
    rendered = inspect(telemetry)
    refute rendered =~ alice.participant_id
    refute rendered =~ bob.participant_id
    refute rendered =~ secret_anchor
    refute rendered =~ secret_message
    assert Enum.any?(telemetry, fn {event, _, _} -> List.last(event) == :experiment_turn end)
  end

  test "control telemetry omits participant ids and chat bodies" do
    attach_telemetry(privacy_events())

    alice = participant_for_variant!(:control)
    bob = participant_for_variant!(:control)
    {:ok, _reply, alice_socket} = join_auto(alice)
    {:ok, _reply, bob_socket} = join_auto(bob)

    ref = push(alice_socket, "control:connect", %{})
    assert_reply ref, :ok, %{status: "waiting"}
    ref = push(bob_socket, "control:connect", %{})
    assert_reply ref, :ok, %{room_id: room_id}
    flush_room_ready()

    secret_message = "CONTROL_SECRET_MESSAGE_66217"
    ref = push(alice_socket, "room:message", %{"room_id" => room_id, "content" => secret_message})
    assert_reply ref, :ok, %{status: "delivered"}

    ref = push(alice_socket, "room:leave", %{"room_id" => room_id})
    assert_reply ref, :ok, %{status: "ended"}

    telemetry = collect_telemetry([])
    rendered = inspect(telemetry)
    refute rendered =~ alice.participant_id
    refute rendered =~ bob.participant_id
    refute rendered =~ secret_message

    assert Enum.any?(telemetry, fn {event, _, metadata} ->
             List.last(event) == :experiment_turn and metadata.variant == :control
           end)
  end

  test "exit feedback accepts only frozen categorical reasons without identity metadata" do
    event = [:strangertalks_new, :experiment, :hearth, :experiment_exit_reason]
    attach_telemetry([event])

    participant = participant!()
    {:ok, _reply, socket} = join_hearth(participant)

    invalid_ref = push(socket, "experiment:feedback", %{"reason" => "SECRET_FREE_TEXT"})
    assert_reply invalid_ref, :error, %{reason: "invalid_request"}
    refute_receive {:telemetry_seen, ^event, _, _}, 20

    valid_ref = push(socket, "experiment:feedback", %{"reason" => "good_chat"})
    assert_reply valid_ref, :ok, %{status: "recorded"}

    assert_receive {:telemetry_seen, ^event, measurements, metadata}
    assert measurements.count == 1
    assert metadata == %{variant: :treatment, reason: "good_chat"}
    refute inspect({measurements, metadata}) =~ participant.participant_id
    refute inspect({measurements, metadata}) =~ "SECRET_FREE_TEXT"
  end

  defp create_bridge do
    alice = participant!()
    bob = participant!()
    Process.put(:hearth_bridge_survivor_id, bob.participant_id)
    {:ok, _reply, alice_socket} = join_hearth(alice)
    {:ok, _reply, bob_socket} = join_hearth(bob)

    alice_ref = push(alice_socket, "hearth:submit", %{"contribution" => "Air fryer"})
    assert_reply alice_ref, :ok, %{status: "waiting"}

    bob_ref = push(bob_socket, "hearth:submit", %{"contribution" => "Running shoes"})
    assert_reply bob_ref, :ok, %{status: "bridge_offered", bridge_id: bridge_id}

    assert_push "bridge:offered", %{bridge_id: ^bridge_id}
    assert_push "bridge:offered", %{bridge_id: ^bridge_id}

    {alice_socket, bob_socket, bridge_id}
  end

  defp create_room do
    {alice_socket, bob_socket, bridge_id} = create_bridge()

    ref = push(alice_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref, :ok, %{status: "waiting_for_partner"}

    ref = push(bob_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref, :ok, %{status: "room_ready", room_id: room_id}
    flush_room_ready()

    {alice_socket, bob_socket, room_id}
  end

  defp join_hearth(participant) do
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

  defp participant_for_variant!(variant, attempts \\ 30)

  defp participant_for_variant!(variant, attempts) when attempts > 0 do
    participant = participant!()

    if HearthChannel.assigned_variant(participant.participant_id) == variant do
      participant
    else
      participant_for_variant!(variant, attempts - 1)
    end
  end

  defp participant_for_variant!(variant, 0),
    do: flunk("could not issue a participant assigned to #{inspect(variant)}")

  defp flush_bridge_offers do
    assert_push "bridge:offered", _
    assert_push "bridge:offered", _
  end

  defp flush_room_ready do
    assert_push "room:ready", _
    assert_push "room:ready", _
  end

  defp participant_id_from_bridge_survivor do
    Process.get(:hearth_bridge_survivor_id)
  end

  defp privacy_events do
    [
      [:strangertalks_new, :experiment, :hearth, :experiment_assigned],
      [:strangertalks_new, :experiment, :hearth, :hearth_submitted],
      [:strangertalks_new, :experiment, :hearth, :bridge_offered],
      [:strangertalks_new, :experiment, :hearth, :bridge_step_in],
      [:strangertalks_new, :experiment, :hearth, :experiment_room_started],
      [:strangertalks_new, :experiment, :hearth, :experiment_turn],
      [:strangertalks_new, :experiment, :hearth, :experiment_first_message],
      [:strangertalks_new, :experiment, :hearth, :experiment_room_ended]
    ]
  end

  defp attach_telemetry(events) do
    handler_id = "hearth-privacy-#{System.unique_integer([:positive])}"
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
      30 -> Enum.reverse(acc)
    end
  end
end
