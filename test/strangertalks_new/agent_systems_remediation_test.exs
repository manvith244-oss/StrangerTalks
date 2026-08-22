defmodule StrangertalksNew.AgentSystemsRemediationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{MatchingRules, Repo}
  alias StrangertalksNewWeb.ConversationChannel

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "en te hi queue authority reaches persisted Match and language-qualified Conversation Start" do
    for language <- ["en", "te", "hi"] do
      %{match: match, conversation: conversation, a: a, b: b} = queue_match(language)

      assert match.conversation_language == language

      pid =
        start_supervised!({ConversationServer, %{conversation_id: conversation.conversation_id}})

      assert {:ok, %{icebreaker: {:active, identity}}} =
               ConversationServer.inspect_state(conversation.conversation_id)

      assert String.starts_with?(identity, "#{language}/")

      assert {:ok, %{language: ^language, text: text}} =
               StrangertalksNew.IcebreakerCatalog.fetch(identity)

      assert is_binary(text) and text != ""

      assert {:ok, join_a} =
               ConversationServer.sync_and_register_channel(
                 conversation.conversation_id,
                 a.participant_id,
                 self(),
                 nil,
                 0
               )

      assert {:ok, join_b} =
               ConversationServer.sync_and_register_channel(
                 conversation.conversation_id,
                 b.participant_id,
                 self(),
                 nil,
                 0
               )

      assert join_a.icebreaker == %{status: "active", identity: identity}
      assert join_b.icebreaker == join_a.icebreaker
      assert join_a.messages == []
      refute Map.has_key?(join_a.icebreaker, :sender_id)
      refute Map.has_key?(join_a.icebreaker, :client_message_id)
      refute Map.has_key?(join_a.icebreaker, :sequence)

      assert :ok = stop_supervised({ConversationServer, conversation.conversation_id})
      refute Process.alive?(pid)
    end
  end

  test "previous queue-attempt language cannot leak into a later attempt or starter" do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

    assert {:ok, first} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "te", nil, nil)
    assert :ok = MatchmakingEngine.leave_queue(a.participant_id)

    assert {:ok, second} =
             MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)

    refute second.queue_attempt_id == first.queue_attempt_id
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    match = Repo.get!(StrangertalksNew.Matching, match_id)
    conversation = Repo.get_by!(StrangertalksNew.Conversation, match_id: match_id)
    assert match.conversation_language == "en"

    _pid =
      start_supervised!({ConversationServer, %{conversation_id: conversation.conversation_id}})

    assert {:ok, %{icebreaker: {:active, identity}}} =
             ConversationServer.inspect_state(conversation.conversation_id)

    assert String.starts_with?(identity, "en/")
    refute String.starts_with?(identity, "te/")
  end

  test "requeued transition survivor cannot reuse stale safety eligibility" do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    recovery_conversation_id = Ecto.UUID.generate()

    assert {:ok, %{status: :queued}} =
             MatchmakingEngine.requeue_transition_survivor(
               a.participant_id,
               :EXPLORE,
               "en",
               recovery_conversation_id
             )

    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

    assert {:ok, _block} =
             MatchingRules.enforce_block(
               a.participant_id,
               b.participant_id,
               "AGENT_SYSTEMS_REMEDIATION"
             )

    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
    assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0

    queue = Agent.get(QueueState, & &1)
    assert queue[a.participant_id].recovery_conversation_id == recovery_conversation_id
    assert Map.has_key?(queue, b.participant_id)
  end

  test "Conversation recovery keeps Match-authoritative language and rejects an outsider" do
    %{conversation: conversation, a: a} = queue_match("hi")

    old_pid =
      start_supervised!({ConversationServer, %{conversation_id: conversation.conversation_id}})

    assert {:ok, %{icebreaker: {:active, before_identity}}} =
             ConversationServer.inspect_state(conversation.conversation_id)

    assert String.starts_with?(before_identity, "hi/")

    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})

    assert {:error, :not_conversation_member} =
             ConversationServer.sync_and_register_channel(
               conversation.conversation_id,
               outsider.participant_id,
               self(),
               nil,
               0
             )

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    new_pid = await_replacement(conversation.conversation_id, old_pid)
    assert is_pid(new_pid)
    refute new_pid == old_pid

    assert {:ok, %{icebreaker: {:active, ^before_identity}}} =
             ConversationServer.inspect_state(conversation.conversation_id)

    assert {:ok, recovered} =
             ConversationServer.sync_and_register_channel(
               conversation.conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    assert recovered.icebreaker == %{status: "active", identity: before_identity}
    assert recovered.messages == []
  end

  test "block terminates live Conversation authority and defeats refresh or restart recovery" do
    %{conversation: conversation, a: a, b: b} = queue_match("en")
    conversation_id = conversation.conversation_id

    pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               b.participant_id,
               self(),
               nil,
               0
             )

    assert Repo.get!(StrangertalksNew.Conversation, conversation_id).conversation_status ==
             :ACTIVE

    assert Process.alive?(pid)

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(conversation_id, a.participant_id)

    terminal = Repo.get!(StrangertalksNew.Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :BLOCK
    assert terminal.ending_initiator == a.participant_id
    assert terminal.safety_flagged == true
    assert terminal.conversation_completed == false

    refute Process.alive?(pid)
    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)

    assert {:error, :conversation_unavailable} =
             ConversationServer.append_message(
               conversation_id,
               b.participant_id,
               Ecto.UUID.generate(),
               "must not survive block"
             )

    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)

    socket = %Phoenix.Socket{assigns: %{participant_id: b.participant_id}}

    assert {:error, _payload} =
             ConversationChannel.join("conversation:#{conversation_id}", %{}, socket)
  end

  test "block closes a pending Conversation before any runtime can be reconstructed" do
    %{conversation: conversation, a: a} = queue_match("te")
    conversation_id = conversation.conversation_id

    assert conversation.conversation_status == :PENDING
    assert {:error, :not_started} = ConversationServer.lookup(conversation_id)

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(conversation_id, a.participant_id)

    terminal = Repo.get!(StrangertalksNew.Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :BLOCK
    assert terminal.ending_initiator == a.participant_id
    assert terminal.safety_flagged == true
    assert terminal.conversation_completed == false

    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)
  end

  test "runtime ownership excludes dormant ParticipantServer and legacy Matcher" do
    application = File.read!("lib/strangertalks_new/application.ex")
    participant_channel = File.read!("lib/strangertalks_new_web/participant_channel.ex")
    participant_server = File.read!("lib/strangertalks_new/queue/participant_server.ex")
    matcher = File.read!("lib/strangertalks_new/matchmaking/queue_engine/matcher.ex")

    assert application =~ "StrangertalksNew.QueueEngine.ParticipantConnectionTracker"
    assert application =~ "StrangertalksNew.QueueEngine.QueueState"
    refute application =~ "StrangertalksNew.Queue.ParticipantServer"
    refute application =~ "StrangertalksNew.Queue.Registry"

    assert participant_channel =~ "ParticipantConnectionTracker.register"
    assert participant_channel =~ "ParticipantConnectionTracker.unregister"
    refute participant_channel =~ "Queue.ParticipantServer"

    assert participant_server =~ "LEGACY / DORMANT"
    assert participant_server =~ "StrangertalksNew.Queue.Registry"
    assert matcher =~ "LEGACY / DORMANT"

    other_lib =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(
        &(&1 in [
            "lib/strangertalks_new/queue/participant_server.ex",
            "lib/strangertalks_new/matchmaking/queue_engine/matcher.ex"
          ])
      )
      |> Enum.map_join("\n", &File.read!/1)

    refute other_lib =~ "StrangertalksNew.Queue.ParticipantServer"
    refute other_lib =~ "StrangertalksNew.QueueEngine.Matcher"
  end

  test "historical readiness and analytics schemas have no production mutation path" do
    matchmaking =
      File.read!("lib/strangertalks_new/matchmaking/queue_engine/matchmaking_engine.ex")

    participant_channel = File.read!("lib/strangertalks_new_web/participant_channel.ex")
    safety = File.read!("lib/strangertalks_new/matching_rules.ex")
    icebreaker = File.read!("lib/strangertalks_new/icebreaker_catalog.ex")
    learning_context = File.read!("lib/strangertalks_new/learning_records.ex")
    analytics_context = File.read!("lib/strangertalks_new/analytics_records.ex")

    for source <- [matchmaking, participant_channel, safety, icebreaker] do
      refute source =~ "LearningRecord"
      refute source =~ "LearningRecords"
      refute source =~ "AnalyticsRecord"
      refute source =~ "AnalyticsRecords"
      refute source =~ "READINESS_EVALUATION"
      refute source =~ "readiness_score"
      refute source =~ "keystroke_latency_variance"
      refute source =~ "agent_accuracy"
    end

    assert participant_channel =~
             "MatchmakingEngine.join_queue(participant_id, door, language, nil, nil)"

    refute learning_context =~ "Application.put_env"
    refute analytics_context =~ "Application.put_env"
    refute learning_context =~ "MatchmakingEngine"
    refute analytics_context =~ "MatchmakingEngine"
    refute learning_context =~ "MatchingRules"
    refute analytics_context =~ "MatchingRules"
  end

  test "runtime model authority is restricted to A01 Conversation Companion" do
    dependency_manifests = File.read!("mix.exs") <> "\n" <> File.read!("package.json")

    runtime_config =
      Path.wildcard("config/**/*.exs")
      |> Enum.map_join("\n", &File.read!/1)

    runtime_files =
      Path.wildcard("lib/**/*.ex") ++
        Path.wildcard("lib/**/*.exs") ++
        Path.wildcard("priv/static/assets/*.js") ++
        Path.wildcard("priv/static/assets/*.mjs")

    companion_provider_path = "lib/strangertalks_new/companion/open_ai_provider.ex"
    companion_provider = File.read!(companion_provider_path)

    assert companion_provider =~ "https://api.openai.com/v1"
    assert companion_provider =~ "store: false"
    assert companion_provider =~ "/responses"
    assert companion_provider =~ "/moderations"

    runtime_outside_companion_provider =
      runtime_files
      |> Enum.reject(&(&1 == companion_provider_path))
      |> Enum.map_join("\n", &File.read!/1)

    for pattern <- [~r/\bOpenAI\b/i, ~r/api\.openai\.com/i] do
      refute Regex.match?(pattern, dependency_manifests),
             "provider-specific SDK dependency is not allowed: #{inspect(pattern)}"

      refute Regex.match?(pattern, runtime_config),
             "provider authority must not leak into generic runtime config: #{inspect(pattern)}"

      refute Regex.match?(pattern, runtime_outside_companion_provider),
             "OpenAI runtime authority escaped A01 provider boundary: #{inspect(pattern)}"
    end

    all_runtime_source = Enum.map_join(runtime_files, "\n", &File.read!/1)

    for pattern <- [
          ~r/\bGemini\b/i,
          ~r/generativelanguage\.googleapis\.com/i,
          ~r/Google\s+AI/i,
          ~r/\bAnthropic\b/i,
          ~r/api\.anthropic\.com/i,
          ~r/\bpgvector\b/i,
          ~r/\bvectorize\b/i,
          ~r/inference[_-]?endpoint/i,
          ~r/model[_-]?endpoint/i
        ] do
      refute Regex.match?(pattern, dependency_manifests),
             "unexpected model dependency manifest entry: #{inspect(pattern)}"

      refute Regex.match?(pattern, runtime_config),
             "unexpected model runtime config: #{inspect(pattern)}"

      refute Regex.match?(pattern, all_runtime_source),
             "unexpected model runtime integration outside approved A01 design: #{inspect(pattern)}"
    end
  end

  defp queue_match(language) do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, language, nil, nil)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, language, nil, nil)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    %{
      match: Repo.get!(StrangertalksNew.Matching, match_id),
      conversation: Repo.get_by!(StrangertalksNew.Conversation, match_id: match_id),
      a: a,
      b: b
    }
  end

  defp await_replacement(conversation_id, old_pid, attempts \\ 50)

  defp await_replacement(_conversation_id, _old_pid, 0),
    do: flunk("ConversationServer did not recover")

  defp await_replacement(conversation_id, old_pid, attempts) do
    case ConversationServer.lookup(conversation_id) do
      {:ok, pid} when pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        await_replacement(conversation_id, old_pid, attempts - 1)
    end
  end
end