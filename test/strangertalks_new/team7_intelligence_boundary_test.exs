defmodule StrangertalksNew.Team7IntelligenceBoundaryTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.Intelligence.{V1Metrics, V1Recommendations}

  test "privacy guard rejects renamed stable participant identifiers" do
    refute V1Metrics.safe_output?(%{"participant-id" => Ecto.UUID.generate()})
    refute V1Metrics.safe_output?(%{"participantId" => Ecto.UUID.generate()})
    refute V1Metrics.safe_output?(%{"raw.queue.participant.id" => Ecto.UUID.generate()})
  end

  test "recommendations reject reversed evidence windows" do
    snapshot = canonical_snapshot("2026-08-25T00:00:00Z", "2026-08-24T00:00:00Z")

    assert {:error, :invalid_analytics_input} = V1Recommendations.analyze(snapshot)
  end

  test "recommendations reject evidence windows larger than the V1 query bound" do
    snapshot = canonical_snapshot("2026-07-01T00:00:00Z", "2026-08-02T00:00:00Z")

    assert {:error, :invalid_analytics_input} = V1Recommendations.analyze(snapshot)
  end

  test "recommendations accept an ordered evidence window at the 31 day bound" do
    snapshot = canonical_snapshot("2026-07-24T00:00:00Z", "2026-08-24T00:00:00Z")

    assert {:ok, result} = V1Recommendations.analyze(snapshot)
    assert result.mutation_authority == false
    assert result.requires_review == true
  end

  test "generated recommendations never contain obsolete numeric team routing" do
    snapshot =
      canonical_snapshot("2026-08-23T00:00:00Z", "2026-08-24T00:00:00Z")
      |> put_in([:system, :technical_disconnects], 1)
      |> put_in([:human_outcomes, :reports_submitted], 1)

    assert {:ok, result} = V1Recommendations.analyze(snapshot)
    assert length(result.recommendations) == 2

    refute Enum.any?(result.recommendations, fn recommendation ->
             Regex.match?(~r/\bTeam\s+\d+\b/i, recommendation.suggested_change)
           end)

    reliability = Enum.find(result.recommendations, &(&1.area == "conversation_reliability"))
    safety = Enum.find(result.recommendations, &(&1.area == "safety_observation"))

    assert reliability.suggested_change =~ "Conversation Reliability owner"
    assert safety.suggested_change =~ "Safety/Terminal owner"
  end

  defp canonical_snapshot(from, to) do
    %{
      schema_version: V1Metrics.schema_version(),
      window: %{from: from, to: to},
      system: %{
        matches_created: 0,
        same_door_matches: 0,
        cross_door_matches: 0,
        average_queue_time_seconds: 0.0,
        conversations_started: 0,
        natural_ends: 0,
        technical_disconnects: 0,
        failed_conversations: 0
      },
      human_outcomes: %{
        voluntary_relationships_created: 0,
        reports_submitted: 0,
        block_terminated_conversations: 0
      }
    }
  end
end
