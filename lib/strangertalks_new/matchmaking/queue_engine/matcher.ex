defmodule StrangertalksNew.QueueEngine.Matcher do
  @moduledoc """
  LEGACY / DORMANT compatibility scorer retained for historical regression coverage.

  The current V1 `MatchmakingEngine` does not call this module when selecting or
  committing candidates. Its old intent/media/tempo matrix, Four Attempt Doctrine
  comments, and typing-rate input are therefore non-authoritative and must not be
  treated as active psychological or behavioral profiling.
  """
  import Bitwise

  # Historical Media Bitmasks (non-authoritative in current V1 matching)
  # @media_text 1
  # @media_audio 2
  # @media_video 4

  # Historical Decay Limits (non-authoritative in current V1 matching)
  # @initial_threshold 70
  # @decay_floor 45

  @doc """
  Computes the historical compatibility score for regression-only callers.
  """
  def compute_match_score(participant_a, participant_b) do
    if participant_a.language != participant_b.language do
      0
    else
      s_intent = score_intent(participant_a.intent_vibe_vector, participant_b.intent_vibe_vector)
      s_media = score_media_overlap(participant_a.media_mask, participant_b.media_mask)
      s_history = 15
      s_tempo = score_tempo(participant_a.typing_rate, participant_b.typing_rate)

      s_intent + 20 + s_media + s_history + s_tempo
    end
  end

  defp score_intent(vector_a, vector_b) do
    base_score =
      cond do
        complementary_intents?(vector_a["primary_intent"], vector_b["primary_intent"]) -> 40
        vector_a["primary_intent"] == vector_b["primary_intent"] -> 30
        true -> 0
      end

    similarity_modifier =
      calculate_cosine_similarity(vector_a["vibe_dimensions"], vector_b["vibe_dimensions"])

    round(base_score * similarity_modifier)
  end

  defp score_media_overlap(mask_a, mask_b) do
    if (mask_a &&& mask_b) !== 0, do: 15, else: 0
  end

  # Reserved cadence is unknown in V1; historical callers treat it as neutral, not numeric.
  defp score_tempo(nil, _rate_b), do: 0
  defp score_tempo(_rate_a, nil), do: 0

  defp score_tempo(rate_a, rate_b) do
    if abs(rate_a - rate_b) < 50, do: 10, else: 0
  end

  defp complementary_intents?("VENT", "ADVICE"), do: true
  defp complementary_intents?("ADVICE", "VENT"), do: true
  defp complementary_intents?(_, _), do: false

  defp calculate_cosine_similarity(_dim_a, _dim_b), do: 1.0
end
