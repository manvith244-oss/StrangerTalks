# filepath: test/strangertalks_new/participant_server_test.exs
defmodule StrangertalksNew.Queue.ParticipantServerTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.Queue.ParticipantServer

  @pubsub_topic "strangertalks:matchmaking"

  setup do
    start_supervised!({Registry, keys: :unique, name: StrangertalksNew.Queue.Registry})
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @pubsub_topic)

    p_id = Ecto.UUID.generate()

    params = %{
      participant_id: p_id,
      language: "en",
      selected_door: :SOMETHING_REAL,
      media_bitmask: 7,
      typing_speed: 140.0
    }

    {:ok, params: params, participant_id: p_id}
  end

  describe "Queue Process Lifecycles and Grace Transitions" do
    test "correctly broadcasts entry packet mappings upon node initialization", %{params: params} do
      child_spec = %{
        id: ParticipantServer,
        start: {ParticipantServer, :start_link, [params]},
        restart: :temporary
      }

      assert {:ok, pid} = start_supervised(child_spec)

      # FIX: Matched exact system broadcast string atom pattern mapping
      assert_receive {:queue_event, :"queue.joined", %{"event" => "queue.joined"}}

      assert is_pid(pid)
    end

    test "transitions to recovering loop structures safely upon cast notification hooks", %{
      params: params,
      participant_id: p_id
    } do
      child_spec = %{
        id: ParticipantServer,
        start: {ParticipantServer, :start_link, [params]},
        restart: :temporary
      }

      start_supervised!(child_spec)

      :ok = ParticipantServer.handle_disconnect(p_id)

      # FIX: Matched exact system broadcast string atom pattern mapping
      assert_receive {:queue_event, :"queue.recovery_started",
                      %{"event" => "queue.recovery_started"}}

      assert :ok = ParticipantServer.handle_reconnect(p_id)
      assert_receive {:queue_event, :"participant.returned", %{"event" => "participant.returned"}}
    end

    test "emits waiting status without decay metadata and remains alive", %{params: params} do
      child_spec = %{
        id: ParticipantServer,
        start: {ParticipantServer, :start_link, [params]},
        restart: :temporary
      }

      {:ok, pid} = start_supervised(child_spec)

      send(pid, {:timeout, make_ref(), :evaluate_tick})
      _ = :sys.get_state(pid)

      assert_receive {:queue_event, :"queue.waiting",
                      %{
                        "payload" => %{
                          "elapsed_seconds" => elapsed_seconds
                        }
                      }}

      assert elapsed_seconds <= 30
    end

    test "long waits remain active without staged relaxation", %{params: params} do
      child_spec = %{
        id: ParticipantServer,
        start: {ParticipantServer, :start_link, [params]},
        restart: :temporary
      }

      {:ok, pid} = start_supervised(child_spec)

      :sys.replace_state(pid, fn state ->
        %{state | start_time_ms: state.start_time_ms - 196_000}
      end)

      send(pid, {:timeout, make_ref(), :evaluate_tick})
      _ = :sys.get_state(pid)

      assert_receive {:queue_event, :"queue.waiting",
                      %{
                        "payload" => %{
                          "elapsed_seconds" => elapsed_seconds
                        }
                      }}

      assert elapsed_seconds >= 195
      assert %{presence_state: :QUEUED} = :sys.get_state(pid)
      refute_receive {:queue_event, :"queue.constraints_relaxed", _}
      refute_receive {:queue_event, :"queue.timeout_warning", _}
    end
  end
end
