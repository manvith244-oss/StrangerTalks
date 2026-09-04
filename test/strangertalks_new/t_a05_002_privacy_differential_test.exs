defmodule StrangertalksNew.TA05002PrivacyDifferentialTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.AgentSystems.LearningAdvisor

  defmodule OpaqueAggregate do
    defstruct [:value]
  end

  defmodule CaptureProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :ta05_002_test_pid), {
        :ta05_provider_request,
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
    previous_pid = Application.get_env(:strangertalks_new, :ta05_002_test_pid)
    previous_learning = Application.get_env(:strangertalks_new, :learning_advisor)

    Application.put_env(:strangertalks_new, :ta05_002_test_pid, self())
    Application.put_env(:strangertalks_new, :learning_advisor, provider: CaptureProvider)

    on_exit(fn ->
      restore(:ta05_002_test_pid, previous_pid)
      restore(:learning_advisor, previous_learning)
    end)

    :ok
  end

  test "T-A05-002 privacy differential records exact provider-boundary behavior" do
    target = System.fetch_env!("TA05_TARGET")
    product_sha = System.fetch_env!("TA05_PRODUCT_SHA")
    result_file = System.fetch_env!("TA05_RESULT_FILE")

    File.mkdir_p!(Path.dirname(result_file))
    File.rm(result_file)

    attacks = privacy_cases()

    Enum.each(attacks, fn attack ->
      drain_provider_messages()

      result = LearningAdvisor.advise([attack.row])
      provider = receive_provider()
      crossed = private_payload_crossed?(provider, attack.private_token)
      authority_acquired = authority_acquired?(result)

      classification =
        classify(target, attack.expectation, result, provider, crossed, authority_acquired)

      record(result_file, %{
        lane: "privacy_differential",
        attack: attack.id,
        target: target,
        product_sha: product_sha,
        expected_contract: Atom.to_string(attack.expectation),
        call_result: result_tag(result),
        provider_invoked: not is_nil(provider),
        provider_payload: payload_string(provider),
        private_payload_crossed: crossed,
        authority_acquired: authority_acquired,
        classification: classification
      })

      cond do
        crossed ->
          flunk(
            "P0 PRIVACY BOUNDARY CROSSING: #{attack.id} reached provider boundary on #{target}; " <>
              "payload=#{payload_string(provider)}"
          )

        target == "candidate" and attack.expectation == :reject_personal ->
          assert result == {:error, :personal_data_not_allowed}, attack.id
          assert is_nil(provider), attack.id

        target == "candidate" and attack.expectation == :reject_invalid ->
          assert result == {:error, :invalid_learning_snapshot}, attack.id
          assert is_nil(provider), attack.id

        attack.expectation == :allow_safe ->
          assert match?({:ok, %{mutation_authority: false}}, result), attack.id
          refute is_nil(provider), attack.id

        true ->
          :ok
      end
    end)
  end

  defp privacy_cases do
    base = %{
      analytics_period: :DAILY,
      source_type: :SYSTEM,
      source_count: 10,
      aggregation_level: :AGGREGATED
    }

    [
      %{
        id: "direct_atom_participant_id",
        expectation: :reject_personal,
        private_token: "ta05-private-participant-direct",
        row: Map.put(base, :participant_id, "ta05-private-participant-direct")
      },
      %{
        id: "direct_string_conversation_id",
        expectation: :reject_personal,
        private_token: "ta05-private-conversation-direct",
        row: Map.put(base, "conversation_id", "ta05-private-conversation-direct")
      },
      %{
        id: "direct_atom_report_id",
        expectation: :reject_personal,
        private_token: "ta05-private-report-direct",
        row: Map.put(base, :report_id, "ta05-private-report-direct")
      },
      %{
        id: "direct_case_variant_participant_id",
        expectation: :reject_personal,
        private_token: "ta05-private-participant-case",
        row: Map.put(base, "Participant_ID", "ta05-private-participant-case")
      },
      %{
        id: "nested_atom_participant_id",
        expectation: :reject_personal,
        private_token: "ta05-private-participant-nested",
        row:
          Map.put(base, :trend_category, %{
            participant_id: "ta05-private-participant-nested",
            aggregate_label: "synthetic"
          })
      },
      %{
        id: "nested_string_conversation_id",
        expectation: :reject_personal,
        private_token: "ta05-private-conversation-nested",
        row:
          Map.put(base, :trend_category, %{
            "nested" => [%{"conversation_id" => "ta05-private-conversation-nested"}]
          })
      },
      %{
        id: "nested_case_variant_report_id",
        expectation: :reject_personal,
        private_token: "ta05-private-report-case",
        row:
          Map.put(base, :trend_category, %{
            "outer" => %{"Report_ID" => "ta05-private-report-case"}
          })
      },
      %{
        id: "nested_case_variant_participant_id",
        expectation: :reject_personal,
        private_token: "ta05-private-participant-mixed",
        row:
          Map.put(base, :trend_category, %{
            "outer" => [%{"pArTiCiPaNt_Id" => "ta05-private-participant-mixed"}]
          })
      },
      %{
        id: "nested_keyword_list_conversation_id",
        expectation: :reject_personal,
        private_token: "ta05-private-conversation-keyword",
        row:
          Map.put(base, :trend_category, [
            nested: [conversation_id: "ta05-private-conversation-keyword"]
          ])
      },
      %{
        id: "multiple_nesting_levels_report_id",
        expectation: :reject_personal,
        private_token: "ta05-private-report-deep",
        row:
          Map.put(base, :trend_category, %{
            level_1: [%{level_2: [%{"report_id" => "ta05-private-report-deep"}]}]
          })
      },
      %{
        id: "nested_contains_personal_data_true",
        expectation: :reject_personal,
        private_token: "ta05-private-marker-lower",
        row:
          Map.put(base, :trend_category, %{
            summary: %{
              "contains_personal_data" => true,
              "synthetic_private_marker" => "ta05-private-marker-lower"
            }
          })
      },
      %{
        id: "nested_case_variant_contains_personal_data_true",
        expectation: :reject_personal,
        private_token: "ta05-private-marker-case",
        row:
          Map.put(base, :trend_category, %{
            summary: %{
              "CoNtAiNs_PeRsOnAl_DaTa" => true,
              "synthetic_private_marker" => "ta05-private-marker-case"
            }
          })
      },
      %{
        id: "malformed_nested_tuple_with_identifier",
        expectation: :reject_invalid,
        private_token: "ta05-private-tuple",
        row:
          Map.put(base, :trend_category, {:participant_id, "ta05-private-tuple"})
      },
      %{
        id: "unknown_struct",
        expectation: :reject_invalid,
        private_token: nil,
        row: Map.put(base, :trend_category, %OpaqueAggregate{value: "synthetic"})
      },
      %{
        id: "benign_date",
        expectation: :allow_safe,
        private_token: nil,
        row: Map.put(base, :analytics_date, ~D[2026-09-04])
      },
      %{
        id: "benign_datetime",
        expectation: :allow_safe,
        private_token: nil,
        row: Map.put(base, :trend_category, %{timestamp: ~U[2026-09-04 09:00:00Z]})
      },
      %{
        id: "benign_decimal",
        expectation: :allow_safe,
        private_token: nil,
        row: Map.put(base, :trend_category, %{score: Decimal.new("0.82")})
      },
      %{
        id: "benign_similar_key_names",
        expectation: :allow_safe,
        private_token: nil,
        row:
          Map.put(base, :trend_category, %{
            "participant_id_count" => 12,
            "NOT_PARTICIPANT_ID" => "aggregate-label",
            "CONTAINS_PERSONAL_DATA_SUMMARY" => true
          })
      }
    ]
  end

  defp classify(_target, _expectation, _result, _provider, true, _authority),
    do: "P0_PRIVACY_BOUNDARY_CROSSING"

  defp classify(_target, _expectation, _result, _provider, _crossed, true),
    do: "P0_AUTHORITY_ACQUIRED"

  defp classify("candidate", :reject_personal, {:error, :personal_data_not_allowed}, nil, false, false),
    do: "PRIVACY_CONTAINED_BEFORE_PROVIDER"

  defp classify("candidate", :reject_invalid, {:error, :invalid_learning_snapshot}, nil, false, false),
    do: "FAIL_CLOSED_BEFORE_PROVIDER"

  defp classify(_target, :allow_safe, {:ok, %{mutation_authority: false}}, provider, false, false)
       when not is_nil(provider),
       do: "BENIGN_VALUE_ALLOWED_NO_AUTHORITY"

  defp classify("canonical", :reject_personal, {:error, :personal_data_not_allowed}, nil, false, false),
    do: "PRIVACY_CONTAINED_BEFORE_PROVIDER"

  defp classify("canonical", :reject_personal, {:ok, %{mutation_authority: false}}, provider, false, false)
       when not is_nil(provider),
       do: "FORBIDDEN_IDENTIFIER_ACCEPTED_BUT_DROPPED_BEFORE_PROVIDER_PAYLOAD"

  defp classify(_target, _expectation, _result, _provider, _crossed, _authority),
    do: "UNEXPECTED_RESULT"

  defp authority_acquired?({:ok, %{mutation_authority: true}}), do: true
  defp authority_acquired?(_), do: false

  defp receive_provider do
    receive do
      {:ta05_provider_request, agent_id, payload} -> %{agent_id: agent_id, payload: payload}
    after
      50 -> nil
    end
  end

  defp drain_provider_messages do
    receive do
      {:ta05_provider_request, _agent_id, _payload} -> drain_provider_messages()
    after
      0 -> :ok
    end
  end

  defp private_payload_crossed?(nil, _token), do: false
  defp private_payload_crossed?(_provider, nil), do: false

  defp private_payload_crossed?(%{payload: payload}, token) when is_binary(token) do
    inspect(payload, limit: :infinity, printable_limit: :infinity) =~ token
  end

  defp payload_string(nil), do: nil

  defp payload_string(%{agent_id: agent_id, payload: payload}) do
    "agent_id=#{agent_id} payload=#{inspect(payload, limit: :infinity, printable_limit: :infinity)}"
  end

  defp result_tag({:ok, %{mutation_authority: authority}}),
    do: "ok mutation_authority=#{inspect(authority)}"

  defp result_tag({:ok, value}), do: "ok #{inspect(value, limit: 20)}"
  defp result_tag({:error, reason}), do: "error #{inspect(reason)}"
  defp result_tag(value), do: inspect(value, limit: 20)

  defp record(path, row) do
    File.write!(path, Jason.encode!(row) <> "\n", [:append])
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
