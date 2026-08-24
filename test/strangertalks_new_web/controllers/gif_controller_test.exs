defmodule StrangertalksNewWeb.GifControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.GifProvider
  alias StrangertalksNewWeb.ParticipantToken

  defmodule FakeProvider do
    def search("none"), do: {:ok, []}
    def search("rate"), do: {:error, :rate_limited}
    def search("broken"), do: {:error, :provider_error}

    def search(query) do
      if pid = Application.get_env(:strangertalks_new, :gif_controller_test_pid) do
        send(pid, {:gif_query, query})
      end

      {:ok,
       [
         %{
           id: "gif-1",
           provider: "fake",
           media_url: "https://media.example.test/a.gif",
           label: "A GIF",
           width: 200,
           height: 120
         }
       ]}
    end
  end

  setup do
    old_adapter = Application.get_env(:strangertalks_new, :gif_provider_adapter)
    old_hosts = Application.get_env(:strangertalks_new, :gif_media_hosts)
    old_test_pid = Application.get_env(:strangertalks_new, :gif_controller_test_pid)
    Application.put_env(:strangertalks_new, :gif_controller_test_pid, self())

    fixture = conversation_fixture()
    {:ok, _pid} = ConversationServer.ensure_started(fixture.conversation.conversation_id)

    on_exit(fn ->
      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
        {:error, :not_started} -> :ok
      end

      restore_env(:gif_provider_adapter, old_adapter)
      restore_env(:gif_media_hosts, old_hosts)
      restore_env(:gif_controller_test_pid, old_test_pid)
    end)

    fixture
  end

  test "status remains lightweight when no provider is configured", %{conn: conn} do
    Application.put_env(:strangertalks_new, :gif_provider_adapter, StrangertalksNew.GifProvider.Disabled)
    Application.put_env(:strangertalks_new, :gif_media_hosts, [])
    assert %{"available" => false} = conn |> get("/api/gifs/status") |> json_response(200)
  end

  test "authenticated current member can search and only q reaches the provider", %{conn: conn} = context do
    configure_fake_provider()
    token = ParticipantToken.sign(context.participant_a)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/gifs/search", %{
        q: "happy dance",
        conversation_id: context.conversation.conversation_id
      })
      |> json_response(200)

    assert_received {:gif_query, "happy dance"}
    assert [%{"id" => "gif-1", "reference" => reference}] = response["results"]
    assert is_binary(reference)
    refute Map.has_key?(hd(response["results"]), "participant_id")
  end

  test "missing token, outsider and malformed request never reach provider", %{conn: conn} = context do
    configure_fake_provider()
    conversation_id = context.conversation.conversation_id

    assert %{"error" => "invalid_token"} =
             conn
             |> get("/api/gifs/search", %{q: "unauthorized", conversation_id: conversation_id})
             |> json_response(401)

    refute_received {:gif_query, "unauthorized"}

    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
    outsider_token = ParticipantToken.sign(outsider.participant_id)

    assert %{"error" => "not_conversation_member"} =
             recycle(conn)
             |> put_req_header("authorization", "Bearer #{outsider_token}")
             |> get("/api/gifs/search", %{q: "outsider", conversation_id: conversation_id})
             |> json_response(403)

    refute_received {:gif_query, "outsider"}

    member_token = ParticipantToken.sign(context.participant_a)

    assert %{"error" => "invalid_request"} =
             recycle(conn)
             |> put_req_header("authorization", "Bearer #{member_token}")
             |> get("/api/gifs/search", %{
               q: "malformed",
               conversation_id: conversation_id,
               participant_id: context.participant_a
             })
             |> json_response(400)

    refute_received {:gif_query, "malformed"}
  end

  test "server-side participant rate limit bounds provider traffic", %{conn: conn} = context do
    configure_fake_provider()
    token = ParticipantToken.sign(context.participant_a)
    conversation_id = context.conversation.conversation_id

    for index <- 1..12 do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/gifs/search", %{q: "burst-#{index}", conversation_id: conversation_id})

      assert response.status == 200
    end

    limited =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/gifs/search", %{q: "burst-13", conversation_id: conversation_id})

    assert %{"error" => "rate_limited", "retry_after_ms" => retry_after_ms} = json_response(limited, 429)
    assert is_integer(retry_after_ms) and retry_after_ms > 0
    refute_received {:gif_query, "burst-13"}
  end

  defp configure_fake_provider do
    Application.put_env(:strangertalks_new, :gif_provider_adapter, FakeProvider)
    Application.put_env(:strangertalks_new, :gif_media_hosts, ["media.example.test"])
    assert GifProvider.configured?()
  end

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
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
