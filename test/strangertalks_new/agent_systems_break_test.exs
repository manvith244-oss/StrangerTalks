defmodule StrangertalksNew.AgentSystemsBreakTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Companion
  alias StrangertalksNew.Companion.OpenAIProvider

  defmodule DeclineHTTPClient do
    def responses(_config, body) do
      send(test_pid(), {:decline_response_request, body})

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "test-model",
           "output" => [
             %{
               "type" => "message",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" =>
                     Jason.encode!(%{
                       decision: "decline",
                       reason: "I can’t help with that request.",
                       suggestions: []
                     })
                 }
               ]
             }
           ]
         }
       }}
    end

    def moderate(_config, texts) do
      send(test_pid(), {:decline_moderation_request, texts})
      flagged = Application.get_env(:strangertalks_new, :decline_test_flagged, false)

      {:ok,
       %{
         status: 200,
         body: %{"results" => Enum.map(texts, fn _ -> %{"flagged" => flagged} end)}
       }}
    end

    defp test_pid, do: Application.fetch_env!(:strangertalks_new, :agent_break_test_pid)
  end

  setup do
    keys = [
      :companion,
      :agent_break_test_pid,
      :decline_test_flagged
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:strangertalks_new, &1)})

    Application.put_env(:strangertalks_new, :agent_break_test_pid, self())
    Application.put_env(:strangertalks_new, :decline_test_flagged, false)

    Application.put_env(:strangertalks_new, :companion,
      enabled: true,
      api_key: "test-secret",
      model: "test-model",
      moderation_model: "test-moderation",
      http_client: DeclineHTTPClient
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
    end)

    :ok
  end

  test "Companion decline reason is moderated before it can be returned" do
    assert {:ok, %{decision: :decline, reason: reason}} =
             OpenAIProvider.generate(%{
               conversation_id: "opaque-conversation",
               participant_id: "opaque-participant",
               peer_id: "opaque-peer",
               language: "en",
               door: "JUST_TALK",
               mode: "respond",
               tone: "natural",
               request: "Help me pressure them",
               draft: nil,
               messages: []
             })

    assert is_binary(reason)
    assert_receive {:decline_response_request, %{store: false}}
    assert_receive {:decline_moderation_request, [^reason]}
  end

  test "flagged Companion decline reason fails closed" do
    Application.put_env(:strangertalks_new, :decline_test_flagged, true)

    assert {:error, :companion_unsafe_output} =
             OpenAIProvider.generate(%{
               conversation_id: "opaque-conversation",
               participant_id: "opaque-participant",
               peer_id: "opaque-peer",
               language: "en",
               door: "JUST_TALK",
               mode: "respond",
               tone: "natural",
               request: "unsafe request",
               draft: nil,
               messages: []
             })
  end

  test "invalid mode content never enters Companion telemetry" do
    handler_id = "agent-break-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :companion, :request],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:companion_telemetry, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    secret = "my-private-secret-mode"

    assert {:error, :conversation_not_found} =
             Companion.request(Ecto.UUID.generate(), Ecto.UUID.generate(), %{"mode" => secret})

    assert_receive {:companion_telemetry, metadata}
    assert metadata.mode == "invalid"
    refute inspect(metadata) =~ secret
  end

  test "generic structured agent provider remains disabled without explicit Agent Systems enablement" do
    previous = Application.get_env(:strangertalks_new, :agent_systems)

    Application.put_env(:strangertalks_new, :agent_systems,
      enabled: false,
      api_key: "test-secret",
      http_client: DeclineHTTPClient
    )

    on_exit(fn -> restore(:agent_systems, previous) end)

    assert {:error, :agent_unavailable} =
             OpenAIProvider.structured(
               "learning_advisor",
               %{analytics: []},
               "Return JSON.",
               %{type: "object", additionalProperties: false, properties: %{}, required: []},
               []
             )

    refute_receive {:decline_response_request, _}, 20
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
