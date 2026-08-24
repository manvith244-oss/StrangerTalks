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

    def search("wrong-host") do
      {:ok,
       [
         %{
           id: "wrong-host",
           provider: "fake",
           media_url: "https://tracker.example.test/happy.gif",
           label: "Wrong host",
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
    old_adapter = Application.get_env(:strangertalks_new, :gif_provider_adapter)
    old_hosts = Application.get_env(:strangertalks_new, :gif_media_hosts)
    Application.put_env(:strangertalks_new, :gif_provider_adapter, FakeProvider)
    Application.put_env(:strangertalks_new, :gif_media_hosts, ["media.example.test"])

    on_exit(fn ->
      restore_env(:gif_provider_adapter, old_adapter)
      restore_env(:gif_media_hosts, old_hosts)
    end)

    :ok
  end

  test "only the explicit search query reaches the provider and result gets a signed send reference" do
    assert GifProvider.configured?()
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

  test "empty, provider error, rate limit, malformed payload and non-allowlisted media remain bounded" do
    assert {:ok, []} = GifProvider.search("empty")
    assert {:error, :provider_error} = GifProvider.search("error")
    assert {:error, :rate_limited} = GifProvider.search("rate")
    assert {:error, :malformed_provider_response} = GifProvider.search("malformed")
    assert {:error, :malformed_provider_response} = GifProvider.search("wrong-host")
    assert {:error, :invalid_query} = GifProvider.search("")
    assert {:error, :invalid_query} = GifProvider.search(String.duplicate("x", 81))
  end

  test "provider without media allowlist is unavailable" do
    Application.put_env(:strangertalks_new, :gif_media_hosts, [])
    refute GifProvider.configured?()
    assert {:error, :provider_unavailable} = GifProvider.search("happy dance")
  end

  test "tampered GIF references never become expressive media" do
    assert {:error, :invalid_payload} = ExpressiveMediaCatalog.fetch("gif:not-a-valid-token")
  end

  defp restore_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
