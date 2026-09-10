defmodule StrangertalksNewWeb.ParticipantMultiTabChannelCollector do
  use GenServer

  def start_link({parent, label}) do
    GenServer.start_link(__MODULE__, {parent, label})
  end

  @impl true
  def init({parent, label}) do
    {:ok, %{parent: parent, label: label}}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Message{} = message, state) do
    send(state.parent, {:channel_push, state.label, message})
    {:noreply, state}
  end

  def handle_info(%Phoenix.Socket.Reply{} = reply, state) do
    send(state.parent, {:channel_reply, state.label, reply})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
