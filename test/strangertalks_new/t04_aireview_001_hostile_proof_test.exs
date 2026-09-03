defmodule StrangertalksNew.T04AIReview001HostileProofTest do
  use ExUnit.Case, async: false

  # Diagnostic-only hostile proof. T07 production source remains untouched.
  alias StrangertalksNew.AgentSystems.LearningAdvisor

  defmodule ProbeProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :t04_aireview_test_pid), {
        :provider_invoked,
        agent_id,
        payload
      })

      {:ok,
       %{
         "recommendations" => [
           %{
             "title" => "Synthetic",
             "hypothesis" => "Synthetic",
             "evidence" => "Synthetic",
             "experiment" => "Synthetic",
             "confidence" => "low"
           }
         ]
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :t04_aireview_test_pid)
    previous_learning = Application.get_env(:strangertalks_new, :learning_advisor)

    Application.put_env(:strangertalks_new, :t04_aireview_test_pid, self())
    Application.put_env(:strangertalks_new, :learning_advisor, provider: ProbeProvider)

    on_exit(fn ->
      restore(:t04_aireview_test_pid, previous_pid)
      restore(:learning_advisor, previous_learning)
    end)

    :ok
  end

  test "case-variant nested participant identifier is rejected before provider invocation" do
    input = [
      %{
        analytics_period: :DAILY,
        source_type: :SYSTEM,
        trend_category: %{"Participant_ID" => "private-participant-123"},
        aggregation_level: :AGGREGATED
      }
    ]

    assert {:error, :personal_data_not_allowed} = LearningAdvisor.advise(input)
    refute_receive {:provider_invoked, "learning_advisor", _}, 20
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
