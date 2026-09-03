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

  test "safe Date values do not crash privacy traversal and are normalized for the provider" do
    assert {:ok, result} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 analytics_date: ~D[2026-09-03],
                 source_type: :SYSTEM,
                 aggregation_level: :AGGREGATED
               }
             ])

    assert result.status == "ready"
    assert result.mutation_authority == false

    assert_receive {:agent_request, "learning_advisor", %{analytics: [payload]}}
    assert payload.analytics_date == "2026-09-03"
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

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
