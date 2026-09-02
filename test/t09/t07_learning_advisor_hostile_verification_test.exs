defmodule StrangertalksNew.T09T07LearningAdvisorHostileVerificationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.LearningAdvisor

  @forbidden [
    :participant_id,
    :participant_a_id,
    :participant_b_id,
    :conversation_id,
    :match_id,
    :message_id,
    :report_id,
    :reporter_context,
    :review_notes
  ]

  defmodule ProbeProvider do
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :t09_t07_test_pid), {:provider_invoked, agent_id, payload})

      {:ok,
       %{
         "recommendations" => [
           %{
             "title" => "Bounded test",
             "hypothesis" => "Aggregate trend",
             "evidence" => "Aggregate evidence",
             "experiment" => "Small reversible experiment",
             "confidence" => "low"
           }
         ]
       }}
    end
  end

  setup do
    previous = Application.get_env(:strangertalks_new, :learning_advisor)
    previous_pid = Application.get_env(:strangertalks_new, :t09_t07_test_pid)
    Application.put_env(:strangertalks_new, :learning_advisor, provider: ProbeProvider)
    Application.put_env(:strangertalks_new, :t09_t07_test_pid, self())

    on_exit(fn ->
      restore(:learning_advisor, previous)
      restore(:t09_t07_test_pid, previous_pid)
    end)

    :ok
  end

  test "all forbidden atom and string keys fail closed through nested map/list combinations before provider" do
    Enum.each(@forbidden, fn key ->
      for forbidden_key <- [key, Atom.to_string(key)] do
        drain_provider_messages()
        row = safe_row(%{trend_category: [%{"safe" => [%{forbidden_key => "private"}]}]})
        assert {:error, :personal_data_not_allowed} = LearningAdvisor.advise([row])
        refute_receive {:provider_invoked, "learning_advisor", _}, 10
      end
    end)
  end

  test "nested contains_personal_data true fails before provider" do
    row = safe_row(%{trend_category: [%{nested: %{"contains_personal_data" => true}}]})
    assert {:error, :personal_data_not_allowed} = LearningAdvisor.advise([row])
    refute_receive {:provider_invoked, "learning_advisor", _}, 20
  end

  test "privacy-safe nested aggregate structures still reach provider" do
    row =
      safe_row(%{
        trend_category: %{
          cohorts: [
            %{name: "new", metrics: %{count: 12, success_rate: "0.80"}},
            %{name: "returning", metrics: [%{count: 9}, %{count: 11}]}
          ]
        }
      })

    assert {:ok, %{status: "ready", mutation_authority: false}} = LearningAdvisor.advise([row])
    assert_receive {:provider_invoked, "learning_advisor", %{analytics: [_]}}
  end

  test "keyword-list nested forbidden identifier is rejected before provider" do
    row = safe_row(%{trend_category: [participant_id: "private-participant"]})

    assert {:error, :personal_data_not_allowed} = LearningAdvisor.advise([row])
    refute_receive {:provider_invoked, "learning_advisor", _}, 20
  end

  test "ordinary Date struct in an allowed field does not crash the privacy validator" do
    row = safe_row(%{analytics_date: ~D[2026-09-02]})

    result = LearningAdvisor.advise([row])
    assert match?({:ok, %{status: "ready"}}, result) or match?({:error, _}, result)
  end

  defp safe_row(extra) do
    Map.merge(
      %{
        analytics_period: :DAILY,
        source_type: :SYSTEM,
        source_count: 10,
        aggregation_level: :AGGREGATED
      },
      extra
    )
  end

  defp drain_provider_messages do
    receive do
      {:provider_invoked, _, _} -> drain_provider_messages()
    after
      0 -> :ok
    end
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
