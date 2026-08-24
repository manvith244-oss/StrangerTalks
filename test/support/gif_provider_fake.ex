defmodule StrangertalksNew.TestGifProvider do
  @moduledoc false

  def search("empty"), do: {:ok, []}
  def search("error"), do: {:error, :provider_error}
  def search("rate"), do: {:error, :rate_limited}

  def search("malformed") do
    {:ok,
     [
       %{
         id: "malformed",
         provider: "test-fixture",
         media_url: "javascript:alert(1)",
         label: "Malformed GIF",
         width: 160,
         height: 120
       }
     ]}
  end

  def search("timeout") do
    Process.sleep(250)
    {:ok, []}
  end

  def search(query) do
    slug =
      query
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    {:ok,
     [
       %{
         id: "gif-#{slug}",
         provider: "test-fixture",
         media_url: "https://media.example.test/#{slug}.gif",
         label: "Fixture GIF #{query}",
         width: 160,
         height: 120
       }
     ]}
  end
end
