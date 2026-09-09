defmodule StrangertalksNew.TrendBridgeResearchProvenanceTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.AgentSystems.TrendBridgeResearch

  defmodule CaptureProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :a04_provenance_test_pid), {
        :agent_request,
        agent_id,
        payload
      })

      {:ok,
       %{
         "candidates" => [
           %{
             "tier" => "universal",
             "bridge" => "What small thing has made this week better than expected?",
             "rationale" => "Turns a current signal into ordinary lived experience."
           },
           %{
             "tier" => "broad",
             "bridge" => "What is something people are talking about that you actually enjoy?",
             "rationale" => "Keeps the prompt broad without specialist knowledge."
           },
           %{
             "tier" => "niche",
             "bridge" => "Has a recent match, movie, or festival changed your mood this week?",
             "rationale" => "Offers optional cultural anchors."
           }
         ]
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :a04_provenance_test_pid)
    previous_trend = Application.get_env(:strangertalks_new, :trend_bridge_research)

    Application.put_env(:strangertalks_new, :a04_provenance_test_pid, self())
    Application.put_env(:strangertalks_new, :trend_bridge_research, provider: CaptureProvider)

    on_exit(fn ->
      restore(:a04_provenance_test_pid, previous_pid)
      restore(:trend_bridge_research, previous_trend)
    end)

    :ok
  end

  test "unclassified raw-string research fails closed before provider invocation" do
    assert {:error, :unclassified_research_signal} =
             TrendBridgeResearch.research("en", [
               "Copied from a private participant Conversation without provenance metadata"
             ])

    refute_receive {:agent_request, "trend_bridge_research", _}, 20
  end

  test "explicit operator-provided research reaches provider without provenance metadata leakage" do
    assert {:ok, result} =
             TrendBridgeResearch.research("en", [
               %{
                 text: "A big cricket match is being discussed this weekend",
                 provenance: :OPERATOR_PROVIDED
               },
               %{text: "Monsoon evenings are back", provenance: :OPERATOR_PROVIDED}
             ])

    assert result.status == "ready"
    assert result.publication_authority == false

    assert_receive {:agent_request, "trend_bridge_research", payload}

    assert payload == %{
             language: "en",
             signals: [
               "A big cricket match is being discussed this weekend",
               "Monsoon evenings are back"
             ]
           }
  end

  describe "hostile operator-input matrix" do
    @valid_signal %{
      text: "A valid operator provided signal text",
      provenance: :OPERATOR_PROVIDED
    }

    test "extra atom key fails closed before provider" do
      signal = Map.put(@valid_signal, :extra_atom_key, "unexpected_data")
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "extra string key fails closed before provider" do
      signal = Map.put(@valid_signal, "extra_string_key", "unexpected_data")
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "participant_id identifier fails closed before provider" do
      signal = Map.put(@valid_signal, :participant_id, "part_01J7YTRW8V2Q7K3J1Z8N9M0P1Q")
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "conversation_id identifier fails closed before provider" do
      signal = Map.put(@valid_signal, :conversation_id, "conv_01J7YTRW8V2Q7K3J1Z8N9M0P1Q")
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "message_id identifier fails closed before provider" do
      signal = Map.put(@valid_signal, :message_id, "msg_01J7YTRW8V2Q7K3J1Z8N9M0P1Q")
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "report_id identifier fails closed before provider" do
      signal = Map.put(@valid_signal, :report_id, "rep_01J7YTRW8V2Q7K3J1Z8N9M0P1Q")
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "user/account identifiers fail closed before provider" do
      for key <- [:user_id, :account_id, "user_id", "account_id"] do
        signal = Map.put(@valid_signal, key, "usr_123")
        assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
        assert reason in [:unclassified_research_signal, :invalid_trend_research]
        refute_receive {:agent_request, "trend_bridge_research", _}, 20
      end
    end

    test "contains_personal_data flag fails closed before provider" do
      signal = Map.put(@valid_signal, :contains_personal_data, true)
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "secret/token/password metadata fails closed before provider" do
      for key <- [:secret, :token, :password, :api_key, "token"] do
        signal = Map.put(@valid_signal, key, "sensitive_value_123")
        assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
        assert reason in [:unclassified_research_signal, :invalid_trend_research]
        refute_receive {:agent_request, "trend_bridge_research", _}, 20
      end
    end

    test "nested maps fail closed before provider" do
      signal = %{text: %{nested: "content"}, provenance: :OPERATOR_PROVIDED}
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "nested lists fail closed before provider" do
      signal = %{text: ["item 1", "item 2"], provenance: :OPERATOR_PROVIDED}
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "mixed provenance fails closed before provider" do
      signals = [
        @valid_signal,
        %{text: "unprovenanced raw text"}
      ]

      assert {:error, reason} = TrendBridgeResearch.research("en", signals)
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "string provenance fails closed before provider" do
      signal = %{text: "valid text", provenance: "OPERATOR_PROVIDED"}
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "missing provenance fails closed before provider" do
      signal = %{text: "valid text"}
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "wrong provenance atom fails closed before provider" do
      signal = %{text: "valid text", provenance: :PARTICIPANT_MESSAGE}
      assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
      assert reason in [:unclassified_research_signal, :invalid_trend_research]
      refute_receive {:agent_request, "trend_bridge_research", _}, 20
    end

    test "malformed text fails closed before provider" do
      for bad_text <- [nil, 12345, true, "", "   ", String.duplicate("x", 241)] do
        signal = %{text: bad_text, provenance: :OPERATOR_PROVIDED}
        assert {:error, reason} = TrendBridgeResearch.research("en", [signal])
        assert reason in [:unclassified_research_signal, :invalid_trend_research]
        refute_receive {:agent_request, "trend_bridge_research", _}, 20
      end
    end

    test "duplicate or alternate key forms fail closed before provider" do
      alternate_forms = [
        %{"text" => "valid text", "provenance" => :OPERATOR_PROVIDED},
        %{"text" => "valid text", :provenance => :OPERATOR_PROVIDED},
        %{"provenance" => :OPERATOR_PROVIDED, :text => "valid text"}
      ]

      for form <- alternate_forms do
        assert {:error, reason} = TrendBridgeResearch.research("en", [form])
        assert reason in [:unclassified_research_signal, :invalid_trend_research]
        refute_receive {:agent_request, "trend_bridge_research", _}, 20
      end
    end

    test "CLI formatting wraps signals in exact bounded schema without bypass" do
      assert :ok =
               Mix.Tasks.Strangertalks.Agents.run([
                 "trends",
                 "en",
                 "Local book fair opening",
                 "New metro line inaugurated"
               ])

      assert_receive {:agent_request, "trend_bridge_research", payload}

      assert payload == %{
               language: "en",
               signals: ["Local book fair opening", "New metro line inaugurated"]
             }
    end
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
