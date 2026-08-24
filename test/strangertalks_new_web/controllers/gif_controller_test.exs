defmodule StrangertalksNewWeb.GifControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.GifProvider

  defmodule FakeProvider do
    def search("none"), do: {:ok, []}
    def search("rate"), do: {:error, :rate_limited}
    def search("broken"), do: {:error, :provider_error}

    def search(query) do
      send(self(), {:gif_query, query})

      {:ok,
       [
         %{
           id: "gif-1",
           provider: "fake",
           media_url: "https://media.example.test/a.gif",
           label: "A GIF",
           width: 200,
           height: 120
         }
       ]}
    end
  end

  setup do
    old_adapter = Application.get_env(:strangertalks_new, :gif_provider_adapter)
    old_hosts = Application.get_env(:strangertalks_new, :gif_media_hosts)

    on_exit(fn ->
      restore_env(:gif_provider_adapter, old_adapter)
      restore_env(:gif_media_hosts, old_hosts)
    end)

    :ok
  end

  test "status and search are truthfully unavailable when no provider is configured", %{conn: conn} do
    Application.put_env(:strangertalks_new, :gif_provider_adapter, StrangertalksNew.GifProvider.Disabled)
    Application.put_env(:strangertalks_new, :gif_media_hosts, [])

    assert %{"available" => false} = conn |> get("/api/gifs/status") |> json_response(200)
    assert %{"error" => "provider_unavailable"} = conn |> get("/api/gifs/search", %{q: "happy"}) |> json_response(503)
  end

  test "search sends only q to the configured adapter and returns a signed reference", %{conn: conn} do
    configure_fake_provider()

    response = conn |> get("/api/gifs/search", %{q: "happy dance", participant_id: "must-not-forward"}) |> json_response(200)
    assert_received {:gif_query, "happy dance"}
    assert [%{"id" => "gif-1", "reference" => reference}] = response["results"]
    assert is_binary(reference)
    refute Map.has_key?(hd(response["results"]), "participant_id")
  end

  test "empty, invalid, rate-limit and provider failures remain bounded", %{conn: conn} do
    configure_fake_provider()

    assert %{"results" => []} = conn |> get("/api/gifs/search", %{q: "none"}) |> json_response(200)
    assert %{"error" => "invalid_query"} = recycle(conn) |> get("/api/gifs/search", %{q: "   "}) |> json_response(400)
    assert %{"error" => "provider_rate_limited"} = recycle(conn) |> get("/api/gifs/search", %{q: "rate"}) |> json_response(429)
    assert %{"error" => "provider_error"} = recycle(conn) |> get("/api/gifs/search", %{q: "broken"}) |> json_response(502)
  end

  defp configure_fake_provider do
    Application.put_env(:strangertalks_new, :gif_provider_adapter, FakeProvider)
    Application.put_env(:strangertalks_new, :gif_media_hosts, ["media.example.test"])
    assert GifProvider.configured?()
  end

  defp restore_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
