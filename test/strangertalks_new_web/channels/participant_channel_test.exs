defmodule StrangertalksNewWeb.ParticipantChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Message
  alias StrangertalksNew.Matching
  alias StrangertalksNew.MatchingRules.BoundaryBlock
  alias StrangertalksNew.Report
  alias StrangertalksNew.Relationship
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken
  alias StrangertalksNewWeb.UserSocket

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "socket requires a current token for an existing participant" do
    participant = participant_fixture()
    token = ParticipantToken.sign(participant.participant_id)

    assert {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    assert socket.assigns.participant_id == participant.participant_id
    assert UserSocket.id(socket) == "participant_socket:#{participant.participant_id}"

    assert :error = connect(UserSocket, %{})
    assert :error = connect(UserSocket, %{"token" => token})
    assert :error = connect(UserSocket, %{"auth_token" => token})
    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: "malformed"})

    expired_token =
      Phoenix.Token.sign(
        @endpoint,
        ParticipantToken.salt(),
        participant.participant_id,
        signed_at: System.system_time(:second) - ParticipantToken.max_age() - 1
      )

    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: expired_token})

    missing_id_token = ParticipantToken.sign(Ecto.UUID.generate())
    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: missing_id_token})
  end

  test "verified socket joins only its own participant topic" do
    participant = participant_fixture()
    socket = connected_socket(participant)

    assert {:ok, _, _socket} =
             subscribe_and_join(
               socket,
               StrangertalksNewWeb.ParticipantChannel,
               "participant:#{participant.participant_id}"
             )

    other_id = Ecto.UUID.generate()

    assert {:error, %{reason: "participant_mismatch"}} =
             subscribe_and_join(
               connected_socket(participant),
               StrangertalksNewWeb.ParticipantChannel,
               "participant:#{other_id}"
             )
  end

  test "old create channel event is not supported" do
    participant = participant_fixture()
    socket = joined_socket(participant)

    ref = push(socket, "create", %{})

    assert_reply ref, :error, %{reason: "invalid_request"}
    assert Repo.aggregate(StrangertalksNew.Participant, :count, :participant_id) == 1
  end

  test "transition recovery admission failure reaches only its survivor" do
    survivor = participant_fixture()
    other = participant_fixture()
    survivor_socket = joined_socket(survivor)
    _other_socket = joined_socket(other)
    conversation_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      StrangertalksNew.PubSub,
      "strangertalks:matchmaking",
      {:transition_recovery_failed, survivor.participant_id, conversation_id}
    )

    assert_push "transition:recovery_failed", %{conversation_id: ^conversation_id}
    refute_push "transition:recovery_failed", %{}
    assert survivor_socket.assigns.participant_id == survivor.participant_id
  end

  test "successful transition survivor recovery delivers its fresh queue attempt" do
    survivor = participant_fixture()
    _socket = joined_socket(survivor)
    conversation_id = Ecto.UUID.generate()
    queue_attempt_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      StrangertalksNew.PubSub,
      "strangertalks:matchmaking",
      {:transition_survivor_requeued, survivor.participant_id, conversation_id, queue_attempt_id}
    )

    assert_push "queue:status", %{
      status: "queued",
      conversation_id: ^conversation_id,
      queue_attempt_id: ^queue_attempt_id
    }
  end

  test "queue join is idempotent and conflicting parameters do not mutate the entry" do
    participant = participant_fixture()
    socket = joined_socket(participant)
    sibling_socket = joined_socket(participant)
    params = queue_params("EXPLORE")

    ref = push(socket, "join_queue", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: queue_attempt_id}
    first_entry = queue_entry(participant.participant_id)

    ref = push(sibling_socket, "join_queue", params)
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: ^queue_attempt_id}
    assert queue_entry(participant.participant_id) == first_entry

    ref = push(socket, "join_queue", queue_params("JUST_TALK"))
    assert_reply ref, :error, %{reason: "already_queued_different_door"}
    assert queue_entry(participant.participant_id) == first_entry
    assert map_size(queue_state()) == 1
  end

  test "queue admission requires a supported explicit Conversation Language" do
    participant = participant_fixture()
    socket = joined_socket(participant)

    ref = push(socket, "queue:join", %{"door_type" => "EXPLORE"})
    assert_reply ref, :error, %{code: "LANGUAGE_REQUIRED"}
    refute queue_entry(participant.participant_id)

    ref = push(socket, "queue:join", %{"door_type" => "EXPLORE", "conversation_language" => "xx"})
    assert_reply ref, :error, %{code: "INVALID_CONVERSATION_LANGUAGE"}
    refute queue_entry(participant.participant_id)
  end

  test "stale Attempt-1 Cancel cannot remove Attempt 2 or emit queue_left" do
    participant = participant_fixture()
    old_socket = joined_socket(participant)
    current_socket = joined_socket(participant)

    ref = push(old_socket, "queue:join", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{queue_attempt_id: attempt_1_id}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^attempt_1_id}

    ref = push(current_socket, "queue:leave", %{"queue_attempt_id" => attempt_1_id})
    assert_reply ref, :ok, %{status: "left"}
    assert_push "queue:status", %{status: "left", queue_attempt_id: ^attempt_1_id}
    assert_push "queue:status", %{status: "left", queue_attempt_id: ^attempt_1_id}

    ref = push(current_socket, "queue:join", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{queue_attempt_id: attempt_2_id}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^attempt_2_id}
    refute attempt_1_id == attempt_2_id

    ref = push(old_socket, "queue:leave", %{"queue_attempt_id" => attempt_1_id})
    assert_reply ref, :error, %{reason: "stale_attempt"}
    refute_push "queue:status", %{status: "left"}

    assert queue_entry(participant.participant_id).queue_attempt_id == attempt_2_id
    assert Repo.aggregate(Matching, :count, :match_id) == 0
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 0
  end

  test "queue colon events publish safe status and leave idempotently" do
    participant = participant_fixture()
    socket = joined_socket(participant)

    ref = push(socket, "queue:join", queue_params("JUST_TALK"))
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: queue_attempt_id}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^queue_attempt_id}
    assert queue_entry(participant.participant_id)

    for _ <- 1..2 do
      ref = push(socket, "queue:leave", %{"queue_attempt_id" => queue_attempt_id})
      assert_reply ref, :ok, %{status: "left"}
      assert_push "queue:status", payload
      assert payload == %{status: "left", queue_attempt_id: queue_attempt_id}
      refute participant.participant_id in Map.values(payload)
    end

    refute queue_entry(participant.participant_id)
  end

  test "participant-wide Cancel converges both sibling channels" do
    participant = participant_fixture()
    socket_a = joined_socket(participant)
    socket_b = joined_socket(participant)

    ref = push(socket_a, "queue:join", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{status: "queued", queue_attempt_id: queue_attempt_id}
    assert_push "queue:status", %{status: "queued", queue_attempt_id: ^queue_attempt_id}
    assert map_size(queue_state()) == 1

    ref = push(socket_b, "queue:leave", %{"queue_attempt_id" => queue_attempt_id})
    assert_reply ref, :ok, %{status: "left"}
    assert_push "queue:status", %{status: "left", queue_attempt_id: ^queue_attempt_id}
    assert_push "queue:status", %{status: "left", queue_attempt_id: ^queue_attempt_id}

    assert queue_state() == %{}
    assert Repo.aggregate(Matching, :count, :match_id) == 0
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 0
  end

  test "queue leave does not report left after match commit wins" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket = joined_socket(participant_a)

    assert {:ok, _} =
             MatchmakingEngine.join_queue(
               participant_a.participant_id,
               :EXPLORE,
               "en",
               nil,
               nil
             )

    assert {:ok, _} =
             MatchmakingEngine.join_queue(
               participant_b.participant_id,
               :EXPLORE,
               "en",
               nil,
               nil
             )

    queue_attempt_id = queue_entry(participant_a.participant_id).queue_attempt_id
    assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

    ref = push(socket, "queue:leave", %{"queue_attempt_id" => queue_attempt_id})
    assert_reply ref, :error, %{reason: "participant_busy"}
    refute_push "queue:status", %{status: "left"}
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert queue_state() == %{}
  end

  test "compatible participants persist one match and conversation and both receive safe notifications" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket_a = joined_socket(participant_a)
    socket_b = joined_socket(participant_b)

    ref_a = push(socket_a, "queue:join", queue_params("JUST_TALK"))
    assert_reply ref_a, :ok, %{status: "queued"}

    ref_b = push(socket_b, "queue:join", queue_params("JUST_TALK"))
    assert_reply ref_b, :ok, %{status: "queued"}

    assert_push "match_found", %{status: "matched", conversation_id: conversation_id}
    assert_push "match_found", %{status: "matched", conversation_id: ^conversation_id}

    conversation = Repo.get!(Conversation, conversation_id)
    assert conversation.conversation_status == :PENDING
    assert Repo.aggregate(Matching, :count) == 1
  end

  test "language-bound queue entries keep cadence nil and client cadence cannot affect V1 matching" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket_a = joined_socket(participant_a)
    socket_b = joined_socket(participant_b)

    ref =
      push(socket_a, "queue:join", %{
        "door_type" => "SOMETHING_REAL",
        "conversation_language" => "en"
      })

    assert_reply ref, :ok, %{status: "queued"}
    assert queue_entry(participant_a.participant_id).keystroke_cadence == nil

    ref =
      push(socket_b, "queue:join", %{
        "door_type" => "SOMETHING_REAL",
        "conversation_language" => "en"
      })

    assert_reply ref, :ok, %{status: "queued"}
    assert_push "match_found", %{status: "matched"}
    assert_push "match_found", %{status: "matched"}
    assert Repo.aggregate(Matching, :count) == 1
  end

  test "missing cadence remains queued beyond the former timeout" do
    participant = participant_fixture()
    socket = joined_socket(participant)

    ref =
      push(socket, "queue:join", %{"door_type" => "JUST_TALK", "conversation_language" => "en"})

    assert_reply ref, :ok, %{status: "queued"}

    Agent.update(QueueState, fn state ->
      update_in(
        state[participant.participant_id].queue_entry_time,
        &DateTime.add(&1, -91, :second)
      )
    end)

    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert queue_entry(participant.participant_id)
  end

  test "queue:join returns explicit participant_busy error when participant is in active conversation" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, match} =
      Repo.insert(%StrangertalksNew.Matching{
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :EXPLORE,
        participant_a_door_type: :EXPLORE,
        participant_b_door_type: :EXPLORE,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: DateTime.utc_now(),
        queue_entry_time: DateTime.utc_now(),
        match_found_time: DateTime.utc_now(),
        compatibility_score: Decimal.new("0.85"),
        opportunity_score: Decimal.new("0.75"),
        scarcity_adjustment: Decimal.new("0.0"),
        conversation_temperature: Decimal.new("0.5"),
        mutual_participation_score: Decimal.new("0.8"),
        conversation_health_score: Decimal.new("0.85"),
        match_quality_score: Decimal.new("0.82"),
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false,
        reconnected_later: false
      })

    {:ok, conv} =
      %StrangertalksNew.Conversation{}
      |> StrangertalksNew.Conversation.changeset(%{
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :EXPLORE,
        conversation_status: :ACTIVE,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        relationship_created_at_end: false,
        safety_flagged: false,
        learning_processed: false,
        created_at: DateTime.utc_now(),
        message_count: 0,
        voice_note_count: 0,
        memory_count: 0,
        report_count: 0,
        block_count: 0,
        duration_seconds: 0
      })
      |> Repo.insert()

    assert {:ok,
            %{
              snapshot: %{
                canonical_state: :CONVERSATION,
                conversation: %{conversation_id: conversation_id}
              }
            },
            socket} =
             participant_a
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ParticipantChannel,
               "participant:#{participant_a.participant_id}"
             )

    assert conversation_id == conv.conversation_id

    ref = push(socket, "queue:join", %{"door_type" => "EXPLORE", "conversation_language" => "en"})
    assert_reply ref, :error, %{reason: "participant_busy"}
  end

  test "different doors remain queued and receive no match notification" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    socket_a = joined_socket(participant_a)
    socket_b = joined_socket(participant_b)

    ref = push(socket_a, "join_queue", queue_params("EXPLORE"))
    assert_reply ref, :ok, %{status: "queued"}
    ref = push(socket_b, "join_queue", queue_params("JUST_TALK"))
    assert_reply ref, :ok, %{status: "queued"}

    _ = :sys.get_state(socket_a.channel_pid)
    _ = :sys.get_state(socket_b.channel_pid)
    refute_push "match_found", _payload, 100
    assert map_size(queue_state()) == 2
    assert Repo.aggregate(Matching, :count, :match_id) == 0
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 0
  end

  test "channel termination performs best-effort queue removal" do
    Process.flag(:trap_exit, true)
    participant = participant_fixture()
    socket = joined_socket(participant)

    assert {:ok, _} =
             MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", 7, 120.0)

    assert queue_entry(participant.participant_id)
    monitor = Process.monitor(socket.channel_pid)

    ref = leave(socket)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    refute queue_entry(participant.participant_id)
  end

  test "conversation channel authorizes members, rejects non-members and unknown conversations" do
    {conversation, participant_a, _participant_b} = matched_conversation_fixture()

    assert {:ok, %{conversation_id: conversation_id}, _socket} =
             participant_a
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ConversationChannel,
               "conversation:#{conversation.conversation_id}"
             )

    assert conversation_id == conversation.conversation_id

    outsider = participant_fixture()

    assert {:error, %{reason: "not_conversation_member"}} =
             outsider
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ConversationChannel,
               "conversation:#{conversation.conversation_id}"
             )

    assert {:error, %{reason: "conversation_not_found"}} =
             participant_a
             |> connected_socket()
             |> subscribe_and_join(
               StrangertalksNewWeb.ConversationChannel,
               "conversation:#{Ecto.UUID.generate()}"
             )
  end

  test "conversation joins reuse one server, track tabs, and activate when both participants join" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    socket_a_1 = joined_conversation_socket(participant_a, conversation)
    socket_a_2 = joined_conversation_socket(participant_a, conversation)
    _socket_b = joined_conversation_socket(participant_b, conversation)

    assert {:ok, pid} = ConversationServer.lookup(conversation.conversation_id)
    assert {:ok, ^pid} = ConversationServer.ensure_started(conversation.conversation_id)
    assert {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)
    assert MapSet.size(state.participant_channels[participant_a.participant_id]) == 2
    assert Repo.get!(Conversation, conversation.conversation_id).conversation_status == :ACTIVE

    Process.flag(:trap_exit, true)
    monitor = Process.monitor(socket_a_1.channel_pid)
    ref = leave(socket_a_1)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    _ = :sys.get_state(pid)
    assert {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)
    assert MapSet.size(state.participant_channels[participant_a.participant_id]) == 1
    refute Map.has_key?(state.recovery_timers, participant_a.participant_id)
    assert socket_a_2.channel_pid != socket_a_1.channel_pid
  end

  test "conversation presence tracks multiple tabs without exposing participant IDs" do
    Process.flag(:trap_exit, true)
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    socket_a_1 = joined_conversation_socket(participant_a, conversation)
    assert_push "conversation:presence", initial_presence
    assert initial_presence.status == nil
    socket_a_2 = joined_conversation_socket(participant_a, conversation)
    assert_push "conversation:presence", %{status: nil}
    socket_b = joined_conversation_socket(participant_b, conversation)

    assert_push "conversation:presence", %{status: "connected"}
    assert_push "conversation:presence", %{status: "connected"}
    assert_push "conversation:presence", %{status: "connected"}

    ref = leave(socket_a_1)
    assert_reply ref, :ok
    refute_push "conversation:presence", %{status: nil}, 50

    monitor = Process.monitor(socket_a_2.channel_pid)
    ref = leave(socket_a_2)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert_push "conversation:presence", payload
    assert payload == %{status: nil}
    refute participant_a.participant_id in Map.values(payload)
    refute participant_b.participant_id in Map.values(payload)
    assert socket_b.channel_pid
  end

  test "typing is recipient-only, ephemeral, refreshable, and ignores stale expiry" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    sender = joined_conversation_socket(participant_a, conversation)
    _recipient = joined_conversation_socket(participant_b, conversation)
    assert {:ok, server} = ConversationServer.lookup(conversation.conversation_id)

    ref = push(sender, "typing:start", %{})
    assert_reply ref, :ok
    assert_push "typing:status", %{typing: true}
    refute_push "typing:status", %{typing: true}, 50
    {:ok, first_state} = ConversationServer.inspect_state(conversation.conversation_id)
    first_token = first_state.typing_timers[participant_a.participant_id].token

    ref = push(sender, "typing:start", %{})
    assert_reply ref, :ok
    assert_push "typing:status", %{typing: true}
    {:ok, second_state} = ConversationServer.inspect_state(conversation.conversation_id)
    second_token = second_state.typing_timers[participant_a.participant_id].token
    refute first_token == second_token

    send(server, {:typing_expired, participant_a.participant_id, first_token})
    _ = :sys.get_state(server)
    refute_push "typing:status", %{typing: false}, 50

    send(server, {:typing_expired, participant_a.participant_id, second_token})
    assert_push "typing:status", %{typing: false}
    assert Repo.aggregate(Message, :count, :message_id) == 0
  end

  test "authorized cumulative recipient progress delivers with safe payloads and no database row" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    sender_socket = joined_conversation_socket(participant_a, conversation)
    recipient_socket = joined_conversation_socket(participant_b, conversation)
    message_id = Ecto.UUID.generate()

    ref =
      push(sender_socket, "message:send", %{
        "message_id" => message_id,
        "content" => "hello"
      })

    assert_reply ref, :ok, %{message_id: ^message_id, sequence: 1, status: "sent"}
    assert_push "message:status", %{message_id: ^message_id, status: "sent"}

    assert_push "message:new", payload
    assert payload.message_id == message_id
    assert payload.sequence == 1
    assert payload.content == "hello"
    assert payload.content_revision == 0
    assert payload.edited == false

    assert Map.keys(payload) |> Enum.sort() == [
             :client_message_id,
             :content,
             :content_revision,
             :edited,
             :epoch_id,
             :message_id,
             :sent_at,
             :sequence
           ]

    refute participant_a.participant_id in Map.values(payload)
    refute participant_b.participant_id in Map.values(payload)

    sender_progress_ref =
      push(sender_socket, "delivery:progress", %{
        "epoch_id" => payload.epoch_id,
        "highest_contiguous_sequence" => 1
      })

    assert_reply sender_progress_ref, :ok, %{status: "applied"}
    refute_push "message:status", %{message_id: ^message_id, status: "delivered"}, 50

    progress_ref =
      push(recipient_socket, "delivery:progress", %{
        "epoch_id" => payload.epoch_id,
        "highest_contiguous_sequence" => 1
      })

    assert_reply progress_ref, :ok, %{status: "applied", highest_contiguous_sequence: 1}
    assert_push "message:status", %{message_id: ^message_id, status: "delivered"}

    duplicate_progress_ref =
      push(recipient_socket, "delivery:progress", %{
        "epoch_id" => payload.epoch_id,
        "highest_contiguous_sequence" => 1
      })

    assert_reply duplicate_progress_ref, :ok, %{status: "no_op", highest_contiguous_sequence: 1}
    assert Repo.aggregate(Message, :count, :message_id) == 0

    assert {:ok, server_state} = ConversationServer.inspect_state(conversation.conversation_id)
    assert server_state.pending == %{}
    assert server_state.pending_count == 0
    assert server_state.pending_bytes == 0
    assert Map.has_key?(server_state.completed, message_id)
    refute Map.has_key?(server_state.completed[message_id], :content)
  end

  test "conversation channel rejects missing and malformed client message IDs" do
    {conversation, participant_a, _participant_b} = matched_conversation_fixture()
    socket = joined_conversation_socket(participant_a, conversation)

    ref = push(socket, "message:send", %{"content" => "missing"})
    assert_reply ref, :error, %{reason: "invalid_payload"}

    ref = push(socket, "message:send", %{"message_id" => "bad", "content" => "malformed"})
    assert_reply ref, :error, %{reason: "invalid_message_id"}
  end

  test "authorized conversation completion ends both sides idempotently and clears pending content" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    socket_a = joined_conversation_socket(participant_a, conversation)
    _socket_b = joined_conversation_socket(participant_b, conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{"message_id" => message_id, "content" => "pending"})

    assert_reply send_ref, :ok, %{message_id: ^message_id}
    assert_push "message:new", %{message_id: ^message_id}

    end_ref =
      push(socket_a, "conversation:end", %{})

    assert_reply end_ref, :ok, %{status: "ended"}

    assert_push "conversation:ended", payload_a
    assert_push "conversation:ended", payload_b
    assert payload_a == %{status: "ended", reason: "participant_completed"}
    assert payload_b == payload_a
    refute participant_a.participant_id in Map.values(payload_a)
    refute participant_b.participant_id in Map.values(payload_a)

    persisted = Repo.get!(Conversation, conversation.conversation_id)
    assert persisted.conversation_status == :ENDED
    assert persisted.conversation_completed == true
    assert persisted.ending_type == :NATURAL_END
    assert persisted.ending_initiator == participant_a.participant_id
    assert persisted.ended_at

    duplicate_ref = push(socket_a, "conversation:end", %{})
    assert_reply duplicate_ref, :ok, %{status: "ended"}

    rejected_send_ref =
      push(socket_a, "message:send", %{
        "message_id" => Ecto.UUID.generate(),
        "content" => "too late"
      })

    assert_reply rejected_send_ref, :error, %{reason: "conversation_unavailable"}
    assert Repo.aggregate(Message, :count, :message_id) == 0
    assert {:error, :not_started} = ConversationServer.lookup(conversation.conversation_id)
  end

  test "verified member deliberately reports the other participant with only submitted evidence" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    socket = joined_conversation_socket(participant_a, conversation)

    payload = %{
      "category" => "HARASSMENT",
      "evidence" => "The exact text I chose to submit."
    }

    ref = push(socket, "conversation:report", payload)
    assert_reply ref, :ok, %{report_id: report_id, status: "submitted"}

    report = Repo.get!(Report, report_id)
    assert report.reporting_participant_id == participant_a.participant_id
    assert report.reported_participant_id == participant_b.participant_id
    assert report.conversation_id == conversation.conversation_id
    assert report.report_category == :HARASSMENT
    assert report.report_status == :SUBMITTED
    assert report.reporter_context == "The exact text I chose to submit."
    assert is_nil(report.reported_message_id)
    assert Repo.aggregate(Message, :count, :message_id) == 0

    duplicate_ref = push(socket, "conversation:report", payload)
    assert_reply duplicate_ref, :ok, %{report_id: ^report_id, status: "submitted"}
    assert Repo.aggregate(Report, :count, :report_id) == 1

    invalid_ref =
      push(socket, "conversation:report", %{"category" => "NOT_REAL", "evidence" => "invalid"})

    assert_reply invalid_ref, :error, %{reason: "invalid_request"}
    assert Repo.aggregate(Report, :count, :report_id) == 1
  end

  test "verified block is private, idempotent, and prevents rematching in either direction" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    socket = joined_conversation_socket(participant_a, conversation)

    ref = push(socket, "conversation:block", %{})

    assert_reply ref, :ok, %{status: "blocked"}

    block = Repo.one!(BoundaryBlock)
    assert block.blocker_user_id == participant_a.participant_id
    assert block.blocked_user_id == participant_b.participant_id
    assert block.source_surface == "CONVERSATION"
    assert block.active_status == true
    refute_push "participant_blocked", _payload, 50

    duplicate_ref = push(socket, "conversation:block", %{})
    assert_reply duplicate_ref, :ok, %{status: "blocked"}
    assert Repo.aggregate(BoundaryBlock, :count, :blocker_user_id) == 1

    conversation
    |> Conversation.changeset(%{conversation_status: :ENDED})
    |> Repo.update!()

    {:ok, _} =
      MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, _} =
      MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 7, 120.0)

    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert map_size(queue_state()) == 2
  end

  test "mutual relationship consent derives identity and notifies both participant topics safely" do
    {conversation, participant_a, participant_b} = matched_conversation_fixture()
    participant_socket_a = joined_socket(participant_a)
    _participant_socket_b = joined_socket(participant_b)
    conversation_socket_a = joined_conversation_socket(participant_a, conversation)
    conversation_socket_b = joined_conversation_socket(participant_b, conversation)

    end_ref = push(conversation_socket_a, "conversation:end", %{})
    assert_reply end_ref, :ok, %{status: "ended"}
    assert_push "conversation:ended", _
    assert_push "conversation:ended", _

    first_ref = push(conversation_socket_a, "relationship:consent", %{})

    assert_reply first_ref, :ok, %{status: "waiting_for_mutual_consent"}
    refute_push "relationship:created", _, 50

    second_ref = push(conversation_socket_b, "relationship:consent", %{})

    assert_reply second_ref, :ok, %{status: "created", relationship_id: relationship_id}
    assert_push "relationship:created", payload_a
    assert_push "relationship:created", payload_b
    assert payload_a == %{status: "created", relationship_id: relationship_id}
    assert payload_b == payload_a
    refute participant_a.participant_id in Map.values(payload_a)
    refute participant_b.participant_id in Map.values(payload_a)
    assert Repo.aggregate(Relationship, :count) == 1
    assert participant_socket_a.channel_pid
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

  defp joined_socket(participant) do
    {:ok, _, socket} =
      participant
      |> connected_socket()
      |> subscribe_and_join(
        StrangertalksNewWeb.ParticipantChannel,
        "participant:#{participant.participant_id}"
      )

    socket
  end

  defp joined_conversation_socket(participant, conversation) do
    {:ok, _, socket} =
      participant
      |> connected_socket()
      |> subscribe_and_join(
        StrangertalksNewWeb.ConversationChannel,
        "conversation:#{conversation.conversation_id}"
      )

    socket
  end

  defp matched_conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, _result} =
      MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, _result} =
      MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.one!(Conversation)
    {conversation, participant_a, participant_b}
  end

  defp queue_params(door_type) do
    %{"door_type" => door_type, "conversation_language" => "en"}
  end

  defp queue_entry(participant_id), do: Map.get(queue_state(), participant_id)
  defp queue_state, do: Agent.get(QueueState, & &1)
end
