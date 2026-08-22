defmodule StrangertalksNew.CompanionOpenAIProviderTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Companion.OpenAIProvider

  defmodule FakeHTTPClient do
    def responses(_config, body) do
      case get_in(body, [:text, :format, :name]) do
        "strangertalks_companion_critic" ->
          send(test_pid(), {:critic_request, body})
          approved = Application.get_env(:strangertalks_new, :companion_test_critic_approved, true)

          critic = %{
            approved: approved,
            reason: if(approved, do: nil, else: "Suggestion claims hidden intent.")
          }

          response("critic-test-model", critic)

        _ ->
          send(test_pid(), {:responses_request, body})

          suggestions = %{
            decision: "assist",
            reason: nil,
            suggestions: [
              %{style: "Warm", text: "That makes sense. What happened next?"},
              %{style: "Light", text: "Okay, now I’m curious — tell me more."}
            ]
          }

          response("test-model", suggestions)
      end
    end

    def moderate(_config, texts) do
      send(test_pid(), {:moderation_request, texts})
      flagged = Application.get_env(:strangertalks_new, :companion_test_flagged, false)
      {:ok, %{status: 200, body: %{"results" => Enum.map(texts, fn _ -> %{"flagged" => flagged} end)}}}
    end

    defp response(model, payload) do
      {:ok,
       %{
         status: 200,
         body: %{
           "model" => model,
           "output" => [
             %{
               "type" => "message",
               "content" => [
                 %{"type" => "output_text", "text" => Jason.encode!(payload)}
               ]
             }
           ]
         }
       }}
    end

    defp test_pid, do: Application.fetch_env!(:strangertalks_new, :companion_test_pid)
  end

  setup do
    previous = Application.get_env(:strangertalks_new, :companion)
    previous_pid = Application.get_env(:strangertalks_new, :companion_test_pid)
    previous_flagged = Application.get_env(:strangertalks_new, :companion_test_flagged)
    previous_critic = Application.get_env(:strangertalks_new, :companion_test_critic_approved)

    Application.put_env(:strangertalks_new, :companion,
      enabled: true,
      api_key: "test-secret",
      model: "test-model",
      critic_model: "critic-test-model",
      moderation_model: "test-moderation",
      http_client: FakeHTTPClient
    )

    Application.put_env(:strangertalks_new, :companion_test_pid, self())
    Application.put_env(:strangertalks_new, :companion_test_flagged, false)
    Application.put_env(:strangertalks_new, :companion_test_critic_approved, true)

    on_exit(fn ->
      restore(:companion, previous)
      restore(:companion_test_pid, previous_pid)
      restore(:companion_test_flagged, previous_flagged)
      restore(:companion_test_critic_approved, previous_critic)
    end)

    :ok
  end

  test "provider sends only the bounded public projection with store disabled" do
    context = %{
      conversation_id: "conversation-secret-id",
      participant_id: "participant-secret-id",
      peer_id: "peer-secret-id",
      language: "te",
      door: "JUST_TALK",
      mode: "respond",
      tone: "warm",
      request: "Help me reply",
      draft: "",
      messages: [%{role: "stranger", text: "హలో", sequence: 1}]
    }

    assert {:ok, %{decision: :assist, model: "test-model", suggestions: suggestions}} =
             OpenAIProvider.generate(context)

    assert length(suggestions) == 2

    assert_receive {:responses_request, request_body}
    assert request_body.store == false
    assert request_body.model == "test-model"
    assert request_body.text.format.type == "json_schema"

    decoded_input = Jason.decode!(request_body.input)
    refute Map.has_key?(decoded_input, "conversation_id")
    refute Map.has_key?(decoded_input, "participant_id")
    refute Map.has_key?(decoded_input, "peer_id")
    assert decoded_input["language"] == "te"
    assert decoded_input["messages"] == [%{"role" => "stranger", "text" => "హలో", "sequence" => 1}]

    serialized = Jason.encode!(request_body)
    refute serialized =~ "conversation-secret-id"
    refute serialized =~ "participant-secret-id"
    refute serialized =~ "peer-secret-id"

    assert_receive {:critic_request, critic_body}
    assert critic_body.store == false
    assert critic_body.model == "critic-test-model"
    assert critic_body.text.format.name == "strangertalks_companion_critic"

    critic_input = Jason.decode!(critic_body.input)
    refute Jason.encode!(critic_input) =~ "conversation-secret-id"
    refute Jason.encode!(critic_input) =~ "participant-secret-id"
    refute Jason.encode!(critic_input) =~ "peer-secret-id"
    assert critic_input["context"]["language"] == "te"
    assert length(critic_input["suggestions"]) == 2

    assert_receive {:moderation_request, moderated}
    assert moderated == Enum.map(suggestions, & &1["text"])
  end

  test "critic rejects policy-invalid generated output before moderation" do
    Application.put_env(:strangertalks_new, :companion_test_critic_approved, false)

    assert {:error, :companion_unsafe_output} =
             OpenAIProvider.generate(%{
               conversation_id: "conversation-secret-id",
               participant_id: "participant-secret-id",
               peer_id: "peer-secret-id",
               language: "en",
               door: "JUST_TALK",
               mode: "respond",
               tone: "natural",
               request: "Help me reply",
               draft: nil,
               messages: []
             })

    assert_receive {:responses_request, _}
    assert_receive {:critic_request, _}
    refute_receive {:moderation_request, _}, 20
  end

  test "flagged generated output is never returned" do
    Application.put_env(:strangertalks_new, :companion_test_flagged, true)

    assert {:error, :companion_unsafe_output} =
             OpenAIProvider.generate(%{
               conversation_id: "conversation-secret-id",
               participant_id: "participant-secret-id",
               peer_id: "peer-secret-id",
               language: "en",
               door: "JUST_TALK",
               mode: "respond",
               tone: "natural",
               request: "Help me reply",
               draft: nil,
               messages: []
             })
  end

  test "provider fails closed when disabled or missing credentials" do
    Application.put_env(:strangertalks_new, :companion,
      enabled: false,
      api_key: "test-secret",
      http_client: FakeHTTPClient
    )

    assert {:error, :companion_unavailable} = OpenAIProvider.generate(%{})

    Application.put_env(:strangertalks_new, :companion,
      enabled: true,
      api_key: nil,
      http_client: FakeHTTPClient
    )

    assert {:error, :companion_unavailable} = OpenAIProvider.generate(%{})
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
