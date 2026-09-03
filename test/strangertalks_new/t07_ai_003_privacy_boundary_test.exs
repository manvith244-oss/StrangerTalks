defmodule StrangertalksNew.T07AI003PrivacyBoundaryTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.LearningAdvisor

  defmodule OpaqueAggregate do
    defstruct [:value]
  end

  defmodule FakeProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :t07_ai_003_test_pid), {
        :agent_request,
        agent_id,
        payload
      })

      {:ok,
       %{
         "recommendations" => [
           %{
             "title" => "Keep the experiment bounded",
             "hypothesis" => "The aggregate signal may justify a reviewed experiment.",
             "evidence" => "Only the supplied aggregate snapshot was used.",
             "experiment" => "Run a small reversible test.",
             "confidence" => "medium"
           }
         ]
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :t07_ai_003_test_pid)
    previous_learning = Application.get_env(:strangertalks_new, :learning_advisor)

    Application.put_env(:strangertalks_new, :t07_ai_003_test_pid, self())
    Application.put_env(:strangertalks_new, :learning_advisor, provider: FakeProvider)

    on_exit(fn ->
      restore(:t07_ai_003_test_pid, previous_pid)
      restore(:learning_advisor, previous_learning)
    end)

    :ok
  end

  test "T04 case-variant participant identifier is rejected before provider invocation" do
    input = [
      %{
        analytics_period: :DAILY,
        source_type: :SYSTEM,
        trend_category: %{
          "Participant_ID" => "private-participant-123"
        },
        aggregation_level: :AGGREGATED
      }
    ]

    assert {:error, :personal_data_not_allowed} = LearningAdvisor.advise(input)
    refute_receive {:agent_request, "learning_advisor", _}, 20
  end

  test "forbidden personal keys are case-insensitive across recursive containers" do
    hostile_values = [
      %{"participant_id" => "private-lowercase"},
      [%{"PARTICIPANT_ID" => "private-uppercase"}],
      %{nested: %{"pArTiCiPaNt_Id" => "private-mixed-case"}},
      [nested: [participant_id: "private-atom"]],
      %{"Report_ID" => Ecto.UUID.generate()}
    ]

    for trend_category <- hostile_values do
      assert {:error, :personal_data_not_allowed} =
               LearningAdvisor.advise([
                 %{
                   analytics_period: :DAILY,
                   source_type: :SYSTEM,
                   trend_category: trend_category,
                   aggregation_level: :AGGREGATED
                 }
               ])

      refute_receive {:agent_request, "learning_advisor", _}, 20
    end
  end

  test "personal-data markers are case-insensitive across recursive containers" do
    hostile_values = [
      %{"contains_personal_data" => true},
      [%{"CONTAINS_PERSONAL_DATA" => true}],
      %{nested: %{"Contains_Personal_Data" => true}},
      [nested: [%{"CoNtAiNs_PeRsOnAl_DaTa" => true}]],
      [nested: [contains_personal_data: true]]
    ]

    for trend_category <- hostile_values do
      assert {:error, :personal_data_not_allowed} =
               LearningAdvisor.advise([
                 %{
                   analytics_period: :DAILY,
                   source_type: :SYSTEM,
                   trend_category: trend_category,
                   aggregation_level: :AGGREGATED
                 }
               ])

      refute_receive {:agent_request, "learning_advisor", _}, 20
    end
  end

  test "nested keyword-list private identifiers are rejected before provider invocation" do
    assert {:error, :personal_data_not_allowed} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 trend_category: [nested: [conversation_id: Ecto.UUID.generate()]],
                 aggregation_level: :AGGREGATED
               }
             ])

    refute_receive {:agent_request, "learning_advisor", _}, 20
  end

  test "safe Date DateTime and Decimal values traverse and normalize for the provider" do
    assert {:ok, result} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 analytics_date: ~D[2026-09-03],
                 source_type: :SYSTEM,
                 trend_category: %{
                   timestamp: ~U[2026-09-03 12:34:56Z],
                   score: Decimal.new("0.82")
                 },
                 aggregation_level: :AGGREGATED
               }
             ])

    assert result.status == "ready"
    assert result.mutation_authority == false

    assert_receive {:agent_request, "learning_advisor", %{analytics: [payload]}}
    assert payload.analytics_date == "2026-09-03"
    assert payload.trend_category.timestamp == "2026-09-03T12:34:56Z"
    assert payload.trend_category.score == "0.82"
  end

  test "unknown structs fail closed before provider invocation instead of being enumerated" do
    assert {:error, :invalid_learning_snapshot} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 trend_category: %OpaqueAggregate{value: "synthetic"},
                 aggregation_level: :AGGREGATED
               }
             ])

    refute_receive {:agent_request, "learning_advisor", _}, 20
  end

  test "nested maps and ordinary lists still reject atom and string private keys" do
    assert {:error, :personal_data_not_allowed} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 trend_category: [
                   %{safe: "aggregate"},
                   %{"nested" => [%{"report_id" => Ecto.UUID.generate()}]}
                 ],
                 aggregation_level: :AGGREGATED
               }
             ])

    refute_receive {:agent_request, "learning_advisor", _}, 20
  end

  test "unrelated keys containing forbidden tokens remain allowed" do
    trend_category = %{
      "participant_id_count" => 12,
      "NOT_PARTICIPANT_ID" => "aggregate-label",
      "CONTAINS_PERSONAL_DATA_SUMMARY" => true
    }

    assert {:ok, result} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 trend_category: trend_category,
                 aggregation_level: :AGGREGATED
               }
             ])

    assert result.status == "ready"
    assert_receive {:agent_request, "learning_advisor", %{analytics: [payload]}}
    assert payload.trend_category == trend_category
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
