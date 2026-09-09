defmodule StrangertalksNewWeb.ParticipantMultiTabAuthorityTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken
  alias StrangertalksNewWeb.UserSocket

  defmodule ChannelCollector do
    use GenServer

    def start_link({parent, label}) do
      GenServer.start_link(__MODULE__, {parent, label})
    end

    @impl true
    def init({parent, label}) do
      {:ok, %{parent: parent, label: label}}
    end

    @impl true
    def handle_info(%Phoenix.Socket.Message{} = message, state) do
      send(state.parent, {:channel_push, state.label, message})
      {:noreply, state}
    end

    def handle_info(%Phoenix.Socket.Reply{} = reply, state) do
      send(state.parent, {:channel_reply, state.label, reply})
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "sibling participant channels open at match time converge on one canonical authority" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    collector_a1 = start_collector(:a1)
    collector_a2 = start_collector(:a2)
    collector_b = start_collector(:b)

    socket_a1 = joined_socket(participant_a, collector_a1)
    socket_a2 = joined_socket(participant_a, collector_a2)
    socket_b = joined_socket(participant_b, collector_b)

    sockets = [socket_a1, socket_a2, socket_b]
    collectors = [collector_a1, collector_a2, collector_b]
    params = queue_params("JUST_TALK")

    assert socket_a1.transport_pid == collector_a1
    assert socket_a2.transport_pid == collector_a2
    assert socket_b.transport_pid == collector_b
    assert MapSet.size(MapSet.new(Enum.map(sockets, & &1.channel_pid))) == 3

    ref = push(socket_a1, "queue:join", params)

    assert_receive {:channel_reply, :a1,
                    %Phoenix.Socket.Reply{
                      ref: ^ref,
                      status: :ok,
                      payload: %{status: "queued", queue_attempt_id: attempt_a}
                    }}

    assert_receive {:channel_push, :a1,
                    %Phoenix.Socket.Message{
                      event: "queue:status",
                      payload: %{status: "queued", queue_attempt_id: ^attempt_a}
                    }}

    ref = push(socket_a2, "queue:join", params)

    assert_receive {:channel_reply, :a2,
                    %Phoenix.Socket.Reply{
                      ref: ^ref,
                      status: :ok,
                      payload: %{status: "queued", queue_attempt_id: ^attempt_a}
                    }}

    assert map_size(queue_state()) == 1

    ref = push(socket_b, "queue:join", params)

    assert_receive {:channel_reply, :b,
                    %Phoenix.Socket.Reply{
                      ref: ^ref,
                      status: :ok,
                      payload: %{status: "queued", queue_attempt_id: attempt_b}
                    }}

    assert_receive {:channel_push, :b,
                    %Phoenix.Socket.Message{
                      event: "queue:status",
                      payload: %{status: "queued", queue_attempt_id: ^attempt_b}
                    }}

    synchronize_match_fanout(sockets, collectors)

    assert_receive {:channel_push, :a1,
                    %Phoenix.Socket.Message{
                      event: "match_found",
                      payload: %{status: "matched", conversation_id: conversation_id}
                    }}

    assert_receive {:channel_push, :a2,
                    %Phoenix.Socket.Message{
                      event: "match_found",
                      payload: %{status: "matched", conversation_id: ^conversation_id}
                    }}

    assert_receive {:channel_push, :b,
                    %Phoenix.Socket.Message{
                      event: "match_found",
                      payload: %{status: "matched", conversation_id: ^conversation_id}
                    }}

    refute_receive {:channel_push, _label, %Phoenix.Socket.Message{event: "match_found"}},
                   0

    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert Repo.get!(Conversation, conversation_id).conversation_status == :PENDING
    assert queue_state() == %{}

    for {label, socket} <- [a1: socket_a1, a2: socket_a2, b: socket_b] do
      ref = push(socket, "session:reconcile", %{})

      assert_receive {:channel_reply, ^label,
                      %Phoenix.Socket.Reply{
                        ref: ^ref,
                        status: :ok,
                        payload: %{
                          snapshot: %{
                            canonical_state: :CONVERSATION,
                            conversation: %{conversation_id: ^conversation_id}
                          }
                        }
                      }}
    end

    synchronize_match_fanout(sockets, collectors)

    refute_receive {:channel_push, _label, %Phoenix.Socket.Message{event: "match_found"}},
                   0
  end

  defp start_collector(label) do
    start_supervised!(
      {ChannelCollector, {self(), label}},
      id: {:participant_multitab_channel_collector, label}
    )
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp joined_socket(participant, transport_pid) do
    socket =
      participant
      |> connected_socket()
      |> Map.put(:transport_pid, transport_pid)

    {:ok, _, socket} =
      subscribe_and_join(
        socket,
        StrangertalksNewWeb.ParticipantChannel,
        "participant:#{participant.participant_id}"
      )

    socket
  end

  defp synchronize_match_fanout(sockets, collectors) do
    # First pass drains queue-evaluation messages. A second pass drains any
    # cross-channel match events emitted while the first pass was running.
    for _pass <- 1..2, socket <- sockets do
      _ = :sys.get_state(socket.channel_pid)
    end

    _ = :sys.get_state(QueueState)

    for collector <- collectors do
      _ = :sys.get_state(collector)
    end

    :ok
  end

  defp queue_params(door_type) do
    %{"door_type" => door_type, "conversation_language" => "en"}
  end

  defp queue_state, do: Agent.get(QueueState, & &1)
end
