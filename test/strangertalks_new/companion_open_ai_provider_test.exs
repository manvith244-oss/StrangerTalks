defmodule StrangertalksNew.CompanionOpenAIProviderTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.Companion.OpenAIProvider

  defmodule FakeHTTPClient do
    def responses(_config, body) do
      case get_in(body, [:text, :format, :name]) do
        "strangertalks_companion_critic" ->
          send(test_pid(), {:critic_request, body})

          approved =
            Application.get_env(:strangertalks_new, :companion_test_critic_approved, true)

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

      {:ok,
       %{status: 200, body: %{"results" => Enum.map(texts, fn _ -> %{"flagged" => flagged} end)}}}
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

  defmodule ScriptedHTTPClient do
    def responses(_config, body) do
      name = get_in(body, [:text, :format, :name])

      key =
        case name do
          "strangertalks_companion" -> :provider_test_generation_response
          "strangertalks_companion_critic" -> :provider_test_critic_response
          _ -> :provider_test_structured_response
        end

      send(test_pid(), {:scripted_response_request, name, body})
      Application.fetch_env!(:strangertalks_new, key)
    end

    def moderate(_config, texts) do
      send(test_pid(), {:scripted_moderation_request, texts})
      Application.fetch_env!(:strangertalks_new, :provider_test_moderation_response)
    end

    defp test_pid, do: Application.fetch_env!(:strangertalks_new, :companion_test_pid)
  end

  setup do
    keys = [
      :companion,
      :agent_systems,
      :companion_test_pid,
      :companion_test_flagged,
      :companion_test_critic_approved,
      :provider_test_generation_response,
      :provider_test_critic_response,
      :provider_test_structured_response,
      :provider_test_moderation_response
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:strangertalks_new, &1)})

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
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
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
             OpenAIProvider.generate(companion_context())

    assert_receive {:responses_request, _}
    assert_receive {:critic_request, _}
    refute_receive {:moderation_request, _}, 20
  end

  test "flagged generated output is never returned" do
    Application.put_env(:strangertalks_new, :companion_test_flagged, true)

    assert {:error, :companion_unsafe_output} =
             OpenAIProvider.generate(companion_context())
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

  test "structured provider turns malformed 200 response envelopes and JSON shapes into useless data" do
    configure_scripted_provider()

    cases = [
      {"empty response", ok_response(%{})},
      {"missing output", ok_response(%{"model" => "test-model"})},
      {"nil output", ok_response(%{"model" => "test-model", "output" => nil})},
      {"non-list output", ok_response(%{"model" => "test-model", "output" => "bad"})},
      {"non-map output item", ok_response(%{"output" => [123]})},
      {"no output_text",
       ok_response(%{
         "output" => [%{"content" => [%{"type" => "refusal", "text" => "no"}]}]
       })},
      {"non-string output text",
       ok_response(%{
         "output" => [
           %{"content" => [%{"type" => "output_text", "text" => 123}]}
         ]
       })},
      {"invalid JSON", raw_text_response("{not-json")},
      {"truncated JSON", raw_text_response("{\"recommendations\":[")},
      {"JSON scalar", raw_text_response("42")},
      {"JSON array", raw_text_response("[]")}
    ]

    Enum.each(cases, fn {label, response} ->
      Application.put_env(:strangertalks_new, :provider_test_structured_response, response)

      assert OpenAIProvider.structured(
               "learning_advisor",
               %{analytics: []},
               "Return JSON.",
               %{type: "object", additionalProperties: false, properties: %{}, required: []},
               []
             ) == {:error, :agent_invalid_output},
             label
    end)
  end

  test "structured provider maps retryable HTTP statuses, unexpected HTTP errors, and client errors" do
    configure_scripted_provider()

    for status <- [408, 409, 429, 500, 502, 503, 504] do
      Application.put_env(
        :strangertalks_new,
        :provider_test_structured_response,
        {:ok, %{status: status, body: %{}}}
      )

      assert {:error, :agent_unavailable} = structured_probe(), "status #{status}"
    end

    Application.put_env(
      :strangertalks_new,
      :provider_test_structured_response,
      {:ok, %{status: 400, body: %{}}}
    )

    assert {:error, :agent_provider_failure} = structured_probe()

    Application.put_env(
      :strangertalks_new,
      :provider_test_structured_response,
      {:error, :econnreset}
    )

    assert {:error, :agent_unavailable} = structured_probe()
  end

  test "A01 rejects incomplete, wrongly typed, wrong-enum, extra-field, and malformed suggestion output" do
    configure_scripted_provider()

    valid_suggestions = valid_suggestions()

    cases = [
      {"missing required reason", %{"decision" => "assist", "suggestions" => valid_suggestions}},
      {"missing required suggestions", %{"decision" => "decline", "reason" => "No."}},
      {"wrong reason type",
       %{"decision" => "assist", "reason" => 123, "suggestions" => valid_suggestions}},
      {"wrong decision enum",
       %{"decision" => "maybe", "reason" => nil, "suggestions" => valid_suggestions}},
      {"extra top-level field",
       %{
         "decision" => "assist",
         "reason" => nil,
         "suggestions" => valid_suggestions,
         "authority" => "send"
       }},
      {"extra suggestion field",
       %{
         "decision" => "assist",
         "reason" => nil,
         "suggestions" => [
           Map.put(hd(valid_suggestions), "send_now", true),
           Enum.at(valid_suggestions, 1)
         ]
       }},
      {"wrong suggestion field type",
       %{
         "decision" => "assist",
         "reason" => nil,
         "suggestions" => [
           %{"style" => "Warm", "text" => 123},
           Enum.at(valid_suggestions, 1)
         ]
       }}
    ]

    Enum.each(cases, fn {label, payload} ->
      Application.put_env(
        :strangertalks_new,
        :provider_test_generation_response,
        json_response(payload)
      )

      assert OpenAIProvider.generate(companion_context()) ==
               {:error, :companion_invalid_output},
             label
    end)
  end

  test "A01 critic rejects incomplete and extra-field structured output" do
    configure_scripted_provider()

    cases = [
      {"missing reason", %{"approved" => true}},
      {"wrong approved type", %{"approved" => "true", "reason" => nil}},
      {"extra field", %{"approved" => true, "reason" => nil, "override" => true}}
    ]

    Enum.each(cases, fn {label, payload} ->
      Application.put_env(
        :strangertalks_new,
        :provider_test_critic_response,
        json_response(payload, "critic-test-model")
      )

      assert OpenAIProvider.generate(companion_context()) ==
               {:error, :companion_invalid_output},
             label
    end)
  end

  test "A01 moderation rejects incomplete or wrongly typed verdicts instead of treating them as safe" do
    configure_scripted_provider()

    cases = [
      {"empty results", {:ok, %{status: 200, body: %{"results" => []}}}},
      {"missing flagged", {:ok, %{status: 200, body: %{"results" => [%{}, %{}]}}}},
      {"wrong flagged type",
       {:ok,
        %{
          status: 200,
          body: %{"results" => [%{"flagged" => "false"}, %{"flagged" => false}]}
        }}}
    ]

    Enum.each(cases, fn {label, response} ->
      Application.put_env(:strangertalks_new, :provider_test_moderation_response, response)

      assert OpenAIProvider.generate(companion_context()) ==
               {:error, :companion_provider_failure},
             label
    end)
  end

  test "A01 generation, critic, and moderation failures fail closed without a model result" do
    configure_scripted_provider()

    Application.put_env(
      :strangertalks_new,
      :provider_test_generation_response,
      {:ok, %{status: 503, body: %{}}}
    )

    assert {:error, :companion_unavailable} = OpenAIProvider.generate(companion_context())

    configure_scripted_provider()

    Application.put_env(
      :strangertalks_new,
      :provider_test_critic_response,
      {:ok, %{status: 429, body: %{}}}
    )

    assert {:error, :companion_unavailable} = OpenAIProvider.generate(companion_context())

    configure_scripted_provider()

    Application.put_env(
      :strangertalks_new,
      :provider_test_moderation_response,
      {:ok, %{status: 504, body: %{}}}
    )

    assert {:error, :companion_unavailable} = OpenAIProvider.generate(companion_context())

    configure_scripted_provider()

    Application.put_env(
      :strangertalks_new,
      :provider_test_generation_response,
      {:ok, %{status: 400, body: %{}}}
    )

    assert {:error, :companion_provider_failure} = OpenAIProvider.generate(companion_context())

    configure_scripted_provider()

    Application.put_env(
      :strangertalks_new,
      :provider_test_generation_response,
      {:error, :timeout}
    )

    assert {:error, :companion_unavailable} = OpenAIProvider.generate(companion_context())
  end

  defp configure_scripted_provider do
    Application.put_env(:strangertalks_new, :companion,
      enabled: true,
      api_key: "test-secret",
      model: "test-model",
      critic_model: "critic-test-model",
      moderation_model: "test-moderation",
      http_client: ScriptedHTTPClient
    )

    Application.put_env(:strangertalks_new, :agent_systems,
      enabled: true,
      api_key: "test-secret",
      model: "test-model",
      http_client: ScriptedHTTPClient
    )

    Application.put_env(
      :strangertalks_new,
      :provider_test_generation_response,
      json_response(%{
        "decision" => "assist",
        "reason" => nil,
        "suggestions" => valid_suggestions()
      })
    )

    Application.put_env(
      :strangertalks_new,
      :provider_test_critic_response,
      json_response(%{"approved" => true, "reason" => nil}, "critic-test-model")
    )

    Application.put_env(
      :strangertalks_new,
      :provider_test_structured_response,
      json_response(%{"ok" => true})
    )

    Application.put_env(
      :strangertalks_new,
      :provider_test_moderation_response,
      {:ok,
       %{
         status: 200,
         body: %{"results" => [%{"flagged" => false}, %{"flagged" => false}]}
       }}
    )
  end

  defp structured_probe do
    OpenAIProvider.structured(
      "learning_advisor",
      %{analytics: []},
      "Return JSON.",
      %{type: "object", additionalProperties: false, properties: %{}, required: []},
      []
    )
  end

  defp companion_context do
    %{
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
    }
  end

  defp valid_suggestions do
    [
      %{"style" => "Warm", "text" => "That makes sense. What happened next?"},
      %{"style" => "Light", "text" => "Okay, now I’m curious — tell me more."}
    ]
  end

  defp json_response(payload, model \\ "test-model") do
    raw_text_response(Jason.encode!(payload), model)
  end

  defp raw_text_response(text, model \\ "test-model") do
    ok_response(%{
      "model" => model,
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ]
    })
  end

  defp ok_response(body), do: {:ok, %{status: 200, body: body}}

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
