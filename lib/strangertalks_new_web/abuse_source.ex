defmodule StrangertalksNewWeb.AbuseSource do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  def from_conn(%Plug.Conn{remote_ip: remote_ip} = conn) do
    selected_ip =
      if private_or_local?(remote_ip) do
        forwarded_source(conn) || remote_ip
      else
        remote_ip
      end

    case ip_to_string(selected_ip) do
      {:ok, source} -> {:ok, {:ip, source}}
      :error -> {:error, :source_unavailable}
    end
  end

  def from_conn(_conn), do: {:error, :source_unavailable}

  defp forwarded_source(conn) do
    parsed =
      conn
      |> get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.map(&parse_ip/1)
      |> Enum.reject(&is_nil/1)

    Enum.find(parsed, &(not private_or_local?(&1))) || List.first(parsed)
  end

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp ip_to_string(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8] do
    case :inet.ntoa(ip) do
      {:error, _reason} -> :error
      chars -> {:ok, List.to_string(chars)}
    end
  end

  defp ip_to_string(_ip), do: :error

  defp private_or_local?({10, _, _, _}), do: true
  defp private_or_local?({127, _, _, _}), do: true
  defp private_or_local?({169, 254, _, _}), do: true
  defp private_or_local?({192, 168, _, _}), do: true
  defp private_or_local?({172, second, _, _}) when second in 16..31, do: true
  defp private_or_local?({100, second, _, _}) when second in 64..127, do: true
  defp private_or_local?({0, _, _, _}), do: true
  defp private_or_local?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_or_local?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  defp private_or_local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_or_local?(_ip), do: false
end
