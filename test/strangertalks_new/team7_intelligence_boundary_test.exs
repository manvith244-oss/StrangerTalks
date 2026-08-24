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
