defmodule StrangertalksNew.TestMalformedNormalMediaOwner do
  use GenServer

  def start_link(conversation_id) when is_binary(conversation_id) do
    GenServer.start_link(__MODULE__, :malformed,
      name:
        {:via, Registry,
         {StrangertalksNew.DistributedRegistry, "conversation:#{conversation_id}"}}
    )
  end

  def child_spec(conversation_id) do
    %{
      id: {__MODULE__, conversation_id},
      start: {__MODULE__, :start_link, [conversation_id]},
      restart: :temporary
    }
  end

  @impl true
  def init(:malformed), do: {:ok, :malformed}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end
