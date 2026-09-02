defmodule StrangertalksNew.ConversationLanguages do
  @moduledoc "Central V1 allowlist for explicitly selected per-attempt Conversation Languages."

  @supported ~w(en te hi)

  def supported, do: @supported

  def normalize(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized in @supported,
      do: {:ok, normalized},
      else: {:error, :invalid_conversation_language}
  end

  def normalize(nil), do: {:error, :language_required}
  def normalize(_value), do: {:error, :invalid_conversation_language}
end
