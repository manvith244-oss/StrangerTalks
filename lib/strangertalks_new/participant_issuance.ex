defmodule StrangertalksNew.ParticipantIssuance do
  @moduledoc """
  Pre-participant admission boundary for anonymous identity issuance.

  The gate is deliberately source-scoped because participant_id does not exist
  yet. Enforcement state is durable in PostgreSQL so restarting the volatile
  participant limiter cannot reset identity-rotation authority.
  """

  alias StrangertalksNew.Participants
  alias StrangertalksNew.SourceRateLimiter
  alias StrangertalksNew.Telemetry

  @policies [
    {:participant_issuance_burst, 6, 60_000},
    {:participant_recent_identity_slots, 12, 15 * 60_000},
    {:participant_identity_rotation, 20, 60 * 60_000}
  ]

  def create(source, attrs, participants_context \\ Participants) when is_map(attrs) do
    result =
      SourceRateLimiter.transact_source(source, @policies, fn _source_fingerprint ->
        case participants_context.create_participant(attrs) do
          {:ok, participant} -> {:ok, participant}
          {:error, reason} -> {:error, {:participant_creation_failed, reason}}
        end
      end)

    case result do
      {:ok, participant, source_fingerprint} ->
        Telemetry.execute(
          [:participant_issuance, :accepted],
          %{count: 1},
          %{result: :success}
        )

        {:ok, participant, source_fingerprint}

      {:error, {:rate_limited, bucket, retry_after_ms}} ->
        Telemetry.execute(
          [:participant_issuance, :rejected],
          %{count: 1},
          %{result: :failure, rejection_category: bucket}
        )

        Telemetry.execute(
          [:participant_issuance, :rate_limit_activated],
          %{count: 1},
          %{rejection_category: bucket}
        )

        {:error, {:rate_limited, bucket, retry_after_ms}}

      {:error, :enforcement_unavailable} ->
        Telemetry.execute(
          [:participant_issuance, :rejected],
          %{count: 1},
          %{result: :failure, rejection_category: :enforcement_unavailable}
        )

        {:error, :enforcement_unavailable}

      {:error, {:participant_creation_failed, _reason} = error} ->
        Telemetry.execute(
          [:participant_issuance, :rejected],
          %{count: 1},
          %{result: :failure, rejection_category: :participant_creation_failed}
        )

        {:error, error}

      {:error, _reason} ->
        Telemetry.execute(
          [:participant_issuance, :rejected],
          %{count: 1},
          %{result: :failure, rejection_category: :enforcement_unavailable}
        )

        {:error, :enforcement_unavailable}
    end
  end

  def policies, do: @policies
end
