defmodule StrangertalksNew.Hangouts.RoomSupervisor do
  use DynamicSupervisor

  alias StrangertalksNew.Hangouts.RoomServer

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_room(room_id) when is_binary(room_id) do
    DynamicSupervisor.start_child(__MODULE__, {RoomServer, room_id})
  end
end
