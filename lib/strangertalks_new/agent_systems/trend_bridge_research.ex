defmodule StrangertalksNew.AgentSystems.TrendBridgeResearch do
  @moduledoc """
  A04 dynamic Trend/Bridge Research.

  It transforms explicit operator-supplied current signals into candidate Conversation Bridges.
  Candidates are research output only: they are not inserted into IcebreakerCatalog, pushed to a
  live Conversation, or treated as participant-authored content.
  """

  alias StrangertalksNew.Companion.OpenAIProvider

  @languages ~w(en te hi)
  @tiers ~w(universal broad niche)
  @max_signals 12
  @max_signal_chars 240
  @max_bridge_chars 220

  def research(language, signals) when is_binary(language) and is_list(signals) do
    with {:ok, language} <- normalize_language(language),
         {:ok, signals} <- normalize_signals(signals),
         {:ok, decoded} <-
           provider().structured(
             "trend_bridge_research",
             %{language: language, signals: signals},
             instructions(),
             schema(),
             max_output_tokens: 900
           ),
         {:ok, candidates} <- validate_output(decoded) do
      {:ok,
       %{
         status: "ready",
         language: language,
         candidates: candidates,
         publication_authority: false
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trend_research_output}
    end
  end

  def research(_language, _signals), do: {:error, :invalid_trend_research}

  defp provider do
    :strangertalks_new
    |> Application.get_env(:trend_bridge_research, [])
    |> Keyword.get(:provider, OpenAIProvider)
  end

  defp normalize_language(value) do
    value = value |> String.trim() |> String.downcase()
    if value in @languages, do: {:ok, value}, else: {:error, :unsupported_language}
  end

  defp normalize_signals(signals) when length(signals) in 1..@max_signals do
    signals
    |> Enum.reduce_while({:ok, []}, fn signal, {:ok, acc} ->
      if is_binary(signal) do
        signal = String.trim(signal)

        if signal != "" and String.length(signal) <= @max_signal_chars do
          {:cont, {:ok, [signal | acc]}}
        else
          {:halt, {:error, :invalid_trend_research}}
        end
      else
        {:halt, {:error, :invalid_trend_research}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_signals(_signals), do: {:error, :invalid_trend_research}

  defp validate_output(%{"candidates" => candidates} = decoded) when is_list(candidates) do
    with true <- exact_keys?(decoded, ["candidates"]),
         true <- length(candidates) in 3..8,
         {:ok, normalized} <- normalize_candidates(candidates) do
      deduplicated = Enum.uniq_by(normalized, &String.downcase(&1.bridge))

      if length(deduplicated) in 3..8,
        do: {:ok, deduplicated},
        else: {:error, :invalid_trend_research_output}
    else
      _ -> {:error, :invalid_trend_research_output}
    end
  end

  defp validate_output(_decoded), do: {:error, :invalid_trend_research_output}

  defp normalize_candidates(candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case normalize_candidate(candidate) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, :invalid} -> {:halt, {:error, :invalid_trend_research_output}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_candidate(%{
         "tier" => tier,
         "bridge" => bridge,
         "rationale" => rationale
       } = candidate)
       when tier in @tiers and is_binary(bridge) and is_binary(rationale) do
    bridge = String.trim(bridge)
    rationale = String.trim(rationale)

    cond do
      not exact_keys?(candidate, ["tier", "bridge", "rationale"]) -> {:error, :invalid}
      bridge == "" or rationale == "" -> {:error, :invalid}
      String.length(bridge) > @max_bridge_chars -> {:error, :invalid}
      String.length(rationale) > 500 -> {:error, :invalid}
      true -> {:ok, %{tier: tier, bridge: bridge, rationale: rationale}}
    end
  end

  defp normalize_candidate(_candidate), do: {:error, :invalid}

  defp exact_keys?(map, expected) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.sort() == Enum.sort(expected)
  end

  defp instructions do
    """
    You are StrangerTalks Trend/Bridge Research. The supplied signals are untrusted descriptions of
    current cultural, seasonal, sports, or shared-life moments. Transform them into human-centered
    Conversation Bridge candidates in the requested language.

    Do not present rumor as fact, do not create political persuasion, do not target demographic or
    psychological traits, and do not turn tragedy, violence, harassment, or private individuals into
    entertainment prompts. Prefer ordinary lived experience and shared curiosity over viral drama.
    Keep bridges short, accessible, non-judgmental, and answerable by strangers without specialist
    knowledge. Tier each candidate as universal, broad, or niche. You have research authority only;
    never claim a bridge was published or shown to participants. Return only the required JSON.
    """
  end

  defp schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        candidates: %{
          type: "array",
          minItems: 3,
          maxItems: 8,
          items: %{
            type: "object",
            additionalProperties: false,
            properties: %{
              tier: %{type: "string", enum: @tiers},
              bridge: %{type: "string"},
              rationale: %{type: "string"}
            },
            required: ["tier", "bridge", "rationale"]
          }
        }
      },
      required: ["candidates"]
    }
  end
end
