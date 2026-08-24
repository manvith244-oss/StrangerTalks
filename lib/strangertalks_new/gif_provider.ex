defmodule StrangertalksNew.GifProvider do
  @moduledoc """
  Server-controlled seam for optional GIF search.

  The browser supplies only the explicit search query. Provider credentials and
  provider-specific request construction stay behind the configured adapter.
  """

  @max_query_length 80
  @max_results 24
  @max_label_length 160
  @max_dimension 4096

  def configured? do
    adapter() != StrangertalksNew.GifProvider.Disabled
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
      {:ok, Enum.map(normalized, fn {:ok, item} -> item end)}
    end
  end

  defp normalize_result(result) when is_map(result) do
    id = result[:id] || result["id"]
    media_url = result[:media_url] || result["media_url"]
    label = result[:label] || result["label"]
    width = result[:width] || result["width"]
    height = result[:height] || result["height"]

    with true <- is_binary(id) and byte_size(id) in 1..200,
         true <- safe_https_url?(media_url),
         true <- is_binary(label) and String.length(label) in 1..@max_label_length,
         true <- is_integer(width) and width in 1..@max_dimension,
         true <- is_integer(height) and height in 1..@max_dimension do
      {:ok, %{id: id, media_url: media_url, label: label, width: width, height: height}}
    else
      _ -> {:error, :malformed_provider_response}
    end
  end

  defp normalize_result(_), do: {:error, :malformed_provider_response}

  defp safe_https_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp safe_https_url?(_), do: false

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
