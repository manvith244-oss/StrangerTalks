defmodule StrangertalksNew.Hangouts.PresenceAuthority do
  @moduledoc """
  Server-owned Hangout channel-lifetime authority.

  Each Phoenix channel registers its own process under the participant/room key in a
  duplicate Registry. Registry entries disappear with the owning channel process, so
  presence truth cannot be authored by a browser heartbeat or a client-supplied lease.
  Durable membership is marked disconnected only when the terminating channel was the
  last registered live channel for that participant in that room.
  """

  alias StrangertalksNew.Hangouts.RoomServer

  @registry StrangertalksNew.Hangouts.PresenceRegistry

  def register(room_id, participant_id, lease_id)
      when is_binary(room_id) and is_binary(participant_id) and is_binary(lease_id) do
    case Registry.register(@registry, key(room_id, participant_id), lease_id) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _owner}} -> {:error, :presence_already_registered}
    end
  end

  def register(_room_id, _participant_id, _lease_id), do: {:error, :invalid_presence_lease}

  def unregister(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    Registry.unregister(@registry, key(room_id, participant_id))
    :ok
  end

  def disconnect_if_last(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    presence_key = key(room_id, participant_id)
    Registry.unregister(@registry, presence_key)

    case Registry.lookup(@registry, presence_key) do
      [] -> RoomServer.disconnect(room_id, participant_id)
      [_ | _] -> RoomServer.snapshot(room_id, participant_id)
    end
  end

  def disconnect_if_last(_room_id, _participant_id),
    do: {:error, :invalid_membership_request}

  def live_channel_count(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    @registry
    |> Registry.lookup(key(room_id, participant_id))
    |> length()
  end

  def live_channel_count(_room_id, _participant_id), do: 0

  defp key(room_id, participant_id), do: {room_id, participant_id}
end
