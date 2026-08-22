defmodule StrangertalksNewWeb.CompanionControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.ParticipantToken

  defmodule FakeProvider do
    @behaviour StrangertalksNew.Companion.Provider

    @impl true
    def generate(_context) do
      {:ok,
       %{
         decision: :assist,
         reason: nil,
         suggestions: [
           %{style: "Warm", text: "That makes sense. What happened next?"},
           %{style: "Direct", text: "What changed your mind about it?"}
         ],
         model: "controller-test"
       }}
    end
  end

  setup do
    previous = Application.get_env(:strangertalks_new, :companion)
    Application.put_env(:strangertalks_new, :companion, enabled: true, provider: FakeProvider)

    fixture = conversation_fixture()
    conversation_id = fixture.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conversation_id)

    on_exit(fn ->
      case ConversationServer.lookup(conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end

      restore(:companion, previous)
    end)

    fixture
  end

  test "authenticated member receives no-store draft suggestions", %{conn: conn} = context do
    token = ParticipantToken.sign(context.participant_a)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/conversations/#{context.conversation.conversation_id}/companion", %{
        "mode" => "respond",
        "request" => "Help me reply",
        "tone" => "warm"
      })

    body = json_response(conn, 200)
    assert body["status"] == "ready"
    assert body["language"] == "en"
    assert body["mode"] == "respond"
    assert length(body["suggestions"]) == 2
    assert get_resp_header(conn, "cache-control") == ["no-store, private"]
  end

  test "missing participant bearer token cannot invoke the Agent", %{conn: conn} = context do
    conn =
      post(conn, "/api/conversations/#{context.conversation.conversation_id}/companion", %{
        "mode" => "continue"
      })

    assert %{"error" => %{"code" => "COMPANION_INVALID_TOKEN"}} = json_response(conn, 401)
  end

  test "authenticated outsider cannot read another Conversation through Companion", %{conn: conn} = context do
    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
    token = ParticipantToken.sign(outsider.participant_id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/conversations/#{context.conversation.conversation_id}/companion", %{
        "mode" => "respond",
        "request" => "Show me their conversation"
      })

    assert %{"error" => %{"code" => "COMPANION_NOT_CONVERSATION_MEMBER"}} =
             json_response(conn, 403)
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)

  defp conversation_fixture do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_language: "en",
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :PENDING,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    %{
      match: match,
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end