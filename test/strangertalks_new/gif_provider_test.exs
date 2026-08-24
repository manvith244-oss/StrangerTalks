defmodule StrangertalksNew.GifProviderTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ExpressiveMediaCatalog
  alias StrangertalksNew.GifProvider

  defmodule FakeProvider do
    def search("empty"), do: {:ok, []}
    def search("error"), do: {:error, :provider_error}
    def search("rate"), do: {:error, :rate_limited}

    def search("malformed") do
      {:ok,
       [
         %{
           id: "bad",
           provider: "fake",
           media_url: "javascript:alert(1)",
           label: "bad",
           width: 320,
           height: 200
         }
       ]}
    end

    def search(query) do
      send(self(), {:provider_query, query})

      {:ok,
       [
         %{
           id: "gif-1",
           provider: "fake",
           media_url: "https://media.example.test/happy.gif",
           label: "Happy dance",
           width: 320,
           height: 240
         }
       ]}
    end
  end

  setup do
    old = Application.get_env(:strangertalks_new, :gif_provider_adapter)
    Application.put_env(:strangertalks_new, :gif_provider_adapter, FakeProvider)

    on_exit(fn ->
      if old do
        Application.put_env(:strangertalks_new, :gif_provider_adapter, old)
      else
        Application.delete_env(:strangertalks_new, :gif_provider_adapter)
      end
    end)

    :ok
  end

  test "only the explicit search query reaches the provider and result gets a signed send reference" do
    assert {:ok, [result]} = GifProvider.search("happy dance")
    assert_received {:provider_query, "happy dance"}
    assert result.provider == "fake"
    assert result.media_url == "https://media.example.test/happy.gif"
    assert is_binary(result.reference)
    refute result.reference =~ "happy dance"

    assert {:ok, canonical} = ExpressiveMediaCatalog.fetch("gif:" <> result.reference)
    assert canonical.kind == "gif"
    assert canonical.provider == "fake"
    assert canonical.asset_path == "https://media.example.test/happy.gif"
    assert canonical.label == "Happy dance"
  end

  test "empty, provider error, rate limit and malformed payload remain bounded" do
    assert {:ok, []} = GifProvider.search("empty")
    assert {:error, :provider_error} = GifProvider.search("error")
    assert {:error, :rate_limited} = GifProvider.search("rate")
    assert {:error, :malformed_provider_response} = GifProvider.search("malformed")
    assert {:error, :invalid_query} = GifProvider.search("")
    assert {:error, :invalid_query} = GifProvider.search(String.duplicate("x", 81))
  end

  test "tampered GIF references never become expressive media" do
    assert {:error, :invalid_payload} = ExpressiveMediaCatalog.fetch("gif:not-a-valid-token")
  end
end
