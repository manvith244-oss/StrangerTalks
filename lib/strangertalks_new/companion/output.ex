defmodule StrangertalksNew.Companion.Output do
  @moduledoc false

  @max_suggestions 4
  @max_text_chars 700
  @max_style_chars 40
  @max_reason_chars 240

  def validate(%{decision: :decline} = result) do
    reason = clean_optional(result[:reason], @max_reason_chars)

    {:ok,
     %{
       decision: :decline,
       reason: reason || "I can’t help with that request.",
       suggestions: [],
       model: result[:model]
     }}
  end

  def validate(%{decision: :assist, suggestions: suggestions} = result)
      when is_list(suggestions) do
    normalized =
      suggestions
      |> Enum.map(&normalize_suggestion/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, suggestion} -> suggestion end)
      |> Enum.uniq_by(&String.downcase(&1.text))
      |> Enum.take(@max_suggestions)

    if length(normalized) in 2..@max_suggestions do
      {:ok,
       %{
         decision: :assist,
         reason: clean_optional(result[:reason], @max_reason_chars),
         suggestions: normalized,
         model: result[:model]
       }}
    else
      {:error, :companion_invalid_output}
    end
  end

  def validate(_result), do: {:error, :companion_invalid_output}

  defp normalize_suggestion(%{style: style, text: text})
       when is_binary(style) and is_binary(text) do
    style = String.trim(style)
    text = String.trim(text)

    cond do
      style == "" or text == "" -> {:error, :invalid}
      String.length(style) > @max_style_chars -> {:error, :invalid}
      String.length(text) > @max_text_chars -> {:error, :invalid}
      true -> {:ok, %{style: style, text: text}}
    end
  end

  defp normalize_suggestion(%{"style" => style, "text" => text}),
    do: normalize_suggestion(%{style: style, text: text})

  defp normalize_suggestion(_suggestion), do: {:error, :invalid}

  defp clean_optional(nil, _limit), do: nil

  defp clean_optional(value, limit) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.length(value) <= limit -> value
      true -> String.slice(value, 0, limit)
    end
  end

  defp clean_optional(_value, _limit), do: nil
end
