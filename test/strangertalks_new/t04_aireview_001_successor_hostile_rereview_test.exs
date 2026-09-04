defmodule StrangertalksNew.T04Aireview001SuccessorHostileRereviewTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.AgentSystems.LearningAdvisor

  @source_path "lib/strangertalks_new/agent_systems/learning_advisor.ex"

  @forbidden [
    {:participant_id, "participant_id"},
    {:participant_a_id, "participant_a_id"},
    {:participant_b_id, "participant_b_id"},
    {:conversation_id, "conversation_id"},
    {:match_id, "match_id"},
    {:message_id, "message_id"},
    {:report_id, "report_id"},
    {:reporter_context, "reporter_context"},
    {:review_notes, "review_notes"}
  ]

  defmodule OpaqueAggregate do
    defstruct [:value]
  end

  defmodule CountingProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :t04_aireview_001_test_pid), {
        :t04_provider_invoked,
        agent_id,
        payload
      })

      {:ok,
       %{
         "recommendations" => [
           %{
             "title" => "Bounded aggregate review",
             "hypothesis" => "Only aggregate evidence was supplied.",
             "evidence" => "The provider received the normalized aggregate snapshot.",
             "experiment" => "Keep the experiment small and reversible.",
             "confidence" => "medium"
           }
         ]
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :t04_aireview_001_test_pid)
    previous_learning = Application.get_env(:strangertalks_new, :learning_advisor)

    Application.put_env(:strangertalks_new, :t04_aireview_001_test_pid, self())
    Application.put_env(:strangertalks_new, :learning_advisor, provider: CountingProvider)
    flush_provider_messages()

    on_exit(fn ->
      restore(:t04_aireview_001_test_pid, previous_pid)
      restore(:learning_advisor, previous_learning)
    end)

    :ok
  end

  test "original T04 RED Participant_ID is rejected before any provider invocation" do
    snapshot = base_snapshot(%{"Participant_ID" => "private-participant-123"})

    assert_privacy_rejection_before_provider(snapshot)
  end

  test "all forbidden identifier keys reject lowercase uppercase title mixed and atom forms" do
    for {atom_key, lower} <- @forbidden do
      string_variants = [
        lower,
        String.upcase(lower),
        title_case(lower),
        alternating_case(lower)
      ]

      for key <- string_variants do
        assert_privacy_rejection_before_provider(base_snapshot(%{key => "private-value"}))
      end

      assert_privacy_rejection_before_provider(base_snapshot(%{atom_key => "private-value"}))
    end
  end

  test "contains_personal_data marker rejects authoritative true in every case variant and atom form" do
    variants = [
      "contains_personal_data",
      "CONTAINS_PERSONAL_DATA",
      "Contains_Personal_Data",
      alternating_case("contains_personal_data"),
      :contains_personal_data
    ]

    for key <- variants do
      assert_privacy_rejection_before_provider(base_snapshot(%{key => true}))
    end
  end

  test "contains_personal_data non-authoritative values follow the existing exact true contract" do
    for value <- [false, nil, "true", 1] do
      snapshot = base_snapshot(%{"CoNtAiNs_PeRsOnAl_DaTa" => value})
      assert {:ok, %{status: "ready", mutation_authority: false}} = LearningAdvisor.advise(snapshot)
      assert_provider_once()
    end
  end

  test "forbidden identifiers and markers are rejected through recursive map list and keyword containers" do
    top_row =
      base_row(%{safe: "aggregate"})
      |> Map.put("Participant_ID", "private-top-row")

    hostile_snapshots = [
      [top_row],
      base_snapshot(%{nested: %{"PARTICIPANT_ID" => "private-nested-map"}}),
      base_snapshot([%{"pArTiCiPaNt_Id" => "private-map-in-list"}]),
      base_snapshot([[%{safe: 1}, [%{"REPORT_ID" => "private-deep-list"}]]]),
      base_snapshot([nested: [conversation_id: "private-keyword"]]),
      base_snapshot(%{nested: [safe: [reporter_context: "private-kw-in-map"]]}),
      base_snapshot([nested: %{safe: %{"Message_ID" => "private-map-in-keyword"}}]),
      base_snapshot(%{
        a: [
          %{b: [c: [%{d: [review_notes: "private-deep-mixed"]}]]}
        ]
      }),
      base_snapshot(%{a: [%{b: [c: %{"CONTAINS_PERSONAL_DATA" => true}]}]})
    ]

    for snapshot <- hostile_snapshots do
      assert_privacy_rejection_before_provider(snapshot)
    end
  end

  test "benign aggregate labels containing forbidden tokens remain allowed and payload keys are preserved" do
    trend_category = %{
      "participant_id_count" => 12,
      "NOT_PARTICIPANT_ID" => "aggregate-label",
      "CONTAINS_PERSONAL_DATA_SUMMARY" => true,
      "report_id_count" => 4,
      "review_notes_rate" => Decimal.new("0.25")
    }

    assert {:ok, %{status: "ready", mutation_authority: false}} =
             LearningAdvisor.advise(base_snapshot(trend_category))

    assert_receive {:t04_provider_invoked, "learning_advisor", %{analytics: [payload]}}, 100
    refute_receive {:t04_provider_invoked, _, _}, 20

    assert payload.trend_category == %{
             "participant_id_count" => 12,
             "NOT_PARTICIPANT_ID" => "aggregate-label",
             "CONTAINS_PERSONAL_DATA_SUMMARY" => "true",
             "report_id_count" => 4,
             "review_notes_rate" => "0.25"
           }
  end

  test "Date DateTime and Decimal remain safely traversable and normalize only values" do
    trend_category = %{
      "event_date" => ~D[2026-09-04],
      "event_time" => ~U[2026-09-04 12:34:56Z],
      "aggregate_score" => Decimal.new("0.82")
    }

    assert {:ok, %{status: "ready", mutation_authority: false}} =
             LearningAdvisor.advise(base_snapshot(trend_category))

    assert_receive {:t04_provider_invoked, "learning_advisor", %{analytics: [payload]}}, 100
    refute_receive {:t04_provider_invoked, _, _}, 20

    assert payload.trend_category == %{
             "event_date" => "2026-09-04",
             "event_time" => "2026-09-04T12:34:56Z",
             "aggregate_score" => "0.82"
           }
  end

  test "unknown structs fail closed before provider invocation" do
    snapshot = base_snapshot(%{opaque: %OpaqueAggregate{value: "synthetic"}})

    assert {:error, :invalid_learning_snapshot} = LearningAdvisor.advise(snapshot)
    refute_provider_invocation()
  end

  test "unsupported key types fail closed before provider invocation" do
    snapshot = base_snapshot(%{{:unsupported, :tuple_key} => "synthetic"})

    assert {:error, :invalid_learning_snapshot} = LearningAdvisor.advise(snapshot)
    refute_provider_invocation()
  end

  test "external binary keys do not create atoms" do
    unique_key = "t04_external_key_#{System.unique_integer([:positive, :monotonic])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_key) end

    assert {:ok, %{status: "ready", mutation_authority: false}} =
             LearningAdvisor.advise(base_snapshot(%{unique_key => "aggregate"}))

    assert_provider_once()
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_key) end
  end

  test "implementation contains no binary-to-atom creation path and canonicalization is ASCII comparison-only" do
    source = File.read!(@source_path)

    refute String.contains?(source, "String.to_atom(")
    refute String.contains?(source, ":erlang.binary_to_atom")
    refute String.contains?(source, ":erlang.list_to_atom")

    assert String.contains?(source, "canonical_privacy_key")
    assert String.contains?(source, "byte in ?A..?Z")
    assert String.contains?(source, "byte + 32")
    assert String.contains?(source, "canonical_privacy_key(&1) == canonical_key")

    refute String.contains?(source, "String.downcase(key)")
    refute String.contains?(source, "String.contains?(canonical_key")
  end

  test "privacy rejection ordering is stable across repeated hostile calls" do
    hostile = base_snapshot(%{"PARTICIPANT_B_ID" => "private-repeat"})

    for _ <- 1..25 do
      assert_privacy_rejection_before_provider(hostile)
    end
  end

  defp base_snapshot(trend_category), do: [base_row(trend_category)]

  defp base_row(trend_category) do
    %{
      analytics_period: :DAILY,
      source_type: :SYSTEM,
      trend_category: trend_category,
      aggregation_level: :AGGREGATED
    }
  end

  defp assert_privacy_rejection_before_provider(snapshot) do
    flush_provider_messages()
    assert {:error, :personal_data_not_allowed} = LearningAdvisor.advise(snapshot)
    refute_provider_invocation()
  end

  defp assert_provider_once do
    assert_receive {:t04_provider_invoked, "learning_advisor", _}, 100
    refute_receive {:t04_provider_invoked, _, _}, 20
  end

  defp refute_provider_invocation do
    refute_receive {:t04_provider_invoked, _, _}, 20
  end

  defp flush_provider_messages do
    receive do
      {:t04_provider_invoked, _, _} -> flush_provider_messages()
    after
      0 -> :ok
    end
  end

  defp title_case(value) do
    value
    |> String.split("_")
    |> Enum.map_join("_", &String.capitalize/1)
  end

  defp alternating_case(value) do
    value
    |> String.graphemes()
    |> Enum.map_reduce(0, fn grapheme, alpha_index ->
      if grapheme =~ ~r/[a-z]/ do
        transformed =
          if rem(alpha_index, 2) == 0, do: String.downcase(grapheme), else: String.upcase(grapheme)

        {transformed, alpha_index + 1}
      else
        {grapheme, alpha_index}
      end
    end)
    |> elem(0)
    |> Enum.join()
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
