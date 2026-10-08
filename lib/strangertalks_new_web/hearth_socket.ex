defmodule StrangertalksNewWeb.HearthSocket do
  use Phoenix.Socket

  alias StrangertalksNewWeb.HearthToken

  channel "hearth:*", StrangertalksNewWeb.HearthChannel

  @impl true
  def connect(_params, socket, %{auth_token: token}) when is_binary(token) do
    with {:ok, authority} <- HearthToken.verify_authority(token) do
      {:ok,
       socket
       |> assign(:participant_id, authority.participant_id)
       |> assign(:hearth_source_fingerprint, authority.source_fingerprint)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "hearth_socket:#{socket.assigns.participant_id}"
end
