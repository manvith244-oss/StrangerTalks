defmodule StrangertalksNew.IcebreakerCatalog do
  @moduledoc false

  @identities [
    "ocean-or-space",
    "tiny-smile-story",
    "instant-skill",
    "new-city-afternoon",
    "small-comfort",
    "ordinary-meaning",
    "conversation-direction"
  ]

  @items %{
    "ocean-or-space" => %{
      text: "Would you rather explore the ocean or outer space?"
    },
    "tiny-smile-story" => %{
      text: "Tell a tiny story about something that made you smile recently."
    },
    "instant-skill" => %{
      text: "If you could instantly master one harmless skill, what would it be?"
    },
    "new-city-afternoon" => %{
      text: "Imagine you both have a free afternoon in a new city—where do you start?"
    },
    "small-comfort" => %{
      text: "What’s a small comfort you think more people should know about?"
    },
    "ordinary-meaning" => %{
      text: "What’s something ordinary that means more to you than people might guess?"
    },
    "conversation-direction" => %{
      text:
        "Would you rather keep things light, swap stories, or talk about something meaningful?"
    }
  }

  def identity_for(conversation_id) when is_binary(conversation_id) do
    Enum.at(@identities, :erlang.phash2(conversation_id, length(@identities)))
  end

  def fetch(identity) when is_binary(identity) do
    case Map.fetch(@items, identity) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :unknown_identity}
    end
  end

  def fetch(_identity), do: {:error, :unknown_identity}

  def approved?(identity), do: match?({:ok, _item}, fetch(identity))

  def identities, do: @identities
end
