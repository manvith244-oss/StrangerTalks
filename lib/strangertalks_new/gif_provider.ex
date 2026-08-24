defmodule StrangertalksNew.GifProvider do
  @moduledoc """
  Server-controlled seam for optional GIF search.

  The browser supplies only the explicit search query. Provider credentials and
  provider-specific request construction stay behind the configured adapter.
  Search results receive short-lived signed references so chat sends never trust
  an arbitrary browser-supplied media URL. External media is accepted only from
  the server-configured provider host allowlist.
  """

  @max_query_length 80
  @max_results 24
  @max_label_length 160
  @max_provider_length 40
  @max_dimension 4096
  @reference_salt "gif-result-v1"
  @reference_max_age 600

  def configured? do
    adapter() != StrangertalksNew.GifProvider.Disabled and allowed_media_hosts() != []
  end

  def status, do: %{available: configured?()}

  def search(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> {:error, :invalid_query}
      String.length(query) > @max_query_length -> {:error, :invalid_query}
      not configured?() -> {:error, :provider_unavailable}
      true -> call_adapter(query)
    end
  end

  def search(_), do: {:error, :invalid_query}

  def resolve_reference(reference) when is_binary(reference) do
    with {:ok, result} <-
           Phoenix.Token.verify(
             StrangertalksNewWeb.Endpoint,
             @reference_salt,
             reference,
             max_age: @reference_max_age
           ),
         {:ok, item} <- normalize_result(result) do
      {:ok,
       %{
         kind: "gif",
         provider: item.provider,
         asset_path: item.media_url,
         label: item.label,
         width: item.width,
         height: item.height
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def resolve_reference(_), do: {:error, :invalid_payload}

  defp call_adapter(query) do
    case adapter().search(query) do
      {:ok, results} when is_list(results) -> normalize_results(results)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_provider_response}
    end
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  defp normalize_results(results) do
    normalized =
      results
      |> Enum.take(@max_results)
      |> Enum.map(&normalize_result/1)

    if Enum.any?(normalized, &match?({:error, _}, &1)) do
      {:error, :malformed_provider_response}
    else
      items = Enum.map(normalized, fn {:ok, item} -> Map.put(item, :reference, sign_result(item)) end)
      {:ok, items}
    end
  end

  defp sign_result(item) do
    Phoenix.Token.sign(StrangertalksNewWeb.Endpoint, @reference_salt, item)
  end

  defp normalize_result(result) when is_map(result) do
    id = result[:id] || result["id"]
    provider = result[:provider] || result["provider"]
    media_url = result[:media_url] || result["media_url"]
    label = result[:label] || result["label"]
    width = result[:width] || result["width"]
    height = result[:height] || result["height"]

    with true <- is_binary(id) and byte_size(id) in 1..200,
         true <- is_binary(provider) and String.length(provider) in 1..@max_provider_length,
         true <- safe_https_url?(media_url),
         true <- is_binary(label) and String.length(label) in 1..@max_label_length,
         true <- is_integer(width) and width in 1..@max_dimension,
         true <- is_integer(height) and height in 1..@max_dimension do
      {:ok,
       %{
         id: id,
         provider: provider,
         media_url: media_url,
         label: label,
         width: width,
         height: height
       }}
    else
      _ -> {:error, :malformed_provider_response}
    end
  end

  defp normalize_result(_), do: {:error, :malformed_provider_response}

  defp safe_https_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        String.downcase(host) in allowed_media_hosts()

      _ ->
        false
    end
  end

  defp safe_https_url?(_), do: false

  defp allowed_media_hosts do
    :strangertalks_new
    |> Application.get_env(:gif_media_hosts, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp adapter do
    Application.get_env(
      :strangertalks_new,
      :gif_provider_adapter,
      StrangertalksNew.GifProvider.Disabled
    )
  end
end

defmodule StrangertalksNew.GifProvider.Disabled do
  @moduledoc false
  def search(_query), do: {:error, :provider_unavailable}
end
