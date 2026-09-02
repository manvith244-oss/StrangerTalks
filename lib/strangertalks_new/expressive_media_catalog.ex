defmodule StrangertalksNew.ExpressiveMediaCatalog do
  @moduledoc false

  alias StrangertalksNew.GifProvider

  @items %{
    "warm-wave" => %{
      kind: "sticker",
      asset_path: "/assets/expressive/warm-wave.svg",
      label: "A friendly wave sticker"
    },
    "bright-spark" => %{
      kind: "sticker",
      asset_path: "/assets/expressive/bright-spark.svg",
      label: "A bright spark sticker"
    },
    "happy-bounce" => %{
      kind: "loop",
      asset_path: "/assets/expressive/happy-bounce.svg",
      label: "A happy bouncing animated sticker"
    },
    "calm-breathe" => %{
      kind: "loop",
      asset_path: "/assets/expressive/calm-breathe.svg",
      label: "A calm breathing animated sticker"
    }
  }

  def fetch("gif:" <> reference), do: GifProvider.resolve_reference(reference)

  def fetch(id) when is_binary(id) do
    case Map.fetch(@items, id) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :invalid_payload}
    end
  end

  def fetch(_id), do: {:error, :invalid_payload}
end
