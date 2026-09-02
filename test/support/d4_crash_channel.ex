defmodule StrangertalksNewWeb.D4CrashChannel do
  use Phoenix.Channel

  @impl true
  def join("conversation:" <> _conversation_id, _payload, socket), do: {:ok, socket}

  @impl true
  def handle_in("d4:crash", _payload, _socket) do
    raise ArgumentError, "representative unhandled Channel failure"
  end
end
