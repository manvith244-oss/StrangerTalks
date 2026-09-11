defmodule StrangertalksNewWeb.HearthChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Experiments.Hearth.Authority
  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.{HearthChannel, ParticipantToken, UserSocket}

  setup do
    previous = Application.get_env(:strangertalks_new, :experiment_hearth_enabled, false)
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, true)

    if Process.whereis(Authority) == nil do
      start_supervised!({Authority, name: Authority, bridge_ttl_ms: 200, submission_ttl_ms: 500})
    end

    on_exit(fn -> Application.put_env(:strangertalks_new, :experiment_hearth_enabled, previous) end)
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
             subscribe_and_join(socket, HearthChannel, "hearth:#{participant.participant_id}", %{})
  end

  test "authenticated participants submit, receive bridge offers, and require mutual Step In" do
    alice = participant!()
    bob = participant!()
    {:ok, _reply, alice_socket} = join_hearth(alice)
    {:ok, _reply, bob_socket} = join_hearth(bob)

    alice_ref = push(alice_socket, "hearth:submit", %{"contribution" => "Air fryer"})
    assert_reply alice_ref, :ok, %{status: "waiting"}

    bob_ref = push(bob_socket, "hearth:submit", %{"contribution" => "Running shoes"})
    assert_reply bob_ref, :ok, %{status: "bridge_offered", bridge_id: bridge_id}

    assert_push "bridge:offered", %{bridge_id: ^bridge_id, own_anchor: "Air fryer", partner_anchor: "Running shoes"}
    assert_push "bridge:offered", %{bridge_id: ^bridge_id, own_anchor: "Running shoes", partner_anchor: "Air fryer"}

    ref1 = push(alice_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref1, :ok, %{status: "waiting_for_partner"}

    ref2 = push(bob_socket, "bridge:step_in", %{"bridge_id" => bridge_id})
    assert_reply ref2, :ok, %{status: "room_ready", room_id: room_id}
    assert is_binary(room_id)

    assert_push "room:ready", %{room_id: ^room_id}
    assert_push "room:ready", %{room_id: ^room_id}
  end

  test "pass dissolves bridge without a rejection event", do: bridge_dissolution(:pass)

  test "channel terminate dissolves participant bridge state" do
    alice = participant!()
    bob = participant!()
    {:ok, _reply, alice_socket} = join_hearth(alice)
    {:ok, _reply, bob_socket} = join_hearth(bob)

    _ = push(alice_socket, "hearth:submit", %{"contribution" => "Air fryer"})
    bob_ref = push(bob_socket, "hearth:submit", %{"contribution" => "Running shoes"})
    assert_reply bob_ref, :ok, %{bridge_id: bridge_id}

    close(alice_socket)
    Process.sleep(20)

    assert {:error, :no_offer} = Authority.offer(Authority, bob.participant_id)
    assert {:error, :no_offer} = Authority.step_in(Authority, bob.participant_id, bridge_id)
  end

  defp bridge_dissolution(:pass) do
    alice = participant!()
    bob = participant!()
    {:ok, _reply, alice_socket} = join_hearth(alice)
    {:ok, _reply, bob_socket} = join_hearth(bob)

    _ = push(alice_socket, "hearth:submit", %{"contribution" => "Air fryer"})
    bob_ref = push(bob_socket, "hearth:submit", %{"contribution" => "Running shoes"})
    assert_reply bob_ref, :ok, %{bridge_id: bridge_id}

    pass_ref = push(alice_socket, "bridge:pass", %{"bridge_id" => bridge_id})
    assert_reply pass_ref, :ok, %{status: "hearth_viewed"}
    assert {:error, :no_offer} = Authority.offer(Authority, bob.participant_id)
  end

  defp join_hearth(participant) do
    subscribe_and_join(
      connected_socket(participant),
      HearthChannel,
      "hearth:#{participant.participant_id}",
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
    participant
  end
end
