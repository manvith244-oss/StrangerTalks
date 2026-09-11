defmodule StrangertalksNew.Hangouts.PresenceAuthority do
  @moduledoc """
  Server-owned Hangout channel-lifetime authority.

  Each Phoenix channel registers its own process under the participant/room key in a
  duplicate Registry. Registry entries disappear with the owning channel process, so
  presence truth cannot be authored by a browser heartbeat or a client-supplied lease.
  Durable membership is marked disconnected only when the terminating channel was the
  last registered live channel for that participant in that room.

  The Registry and Phoenix Endpoint share a rest-for-one supervisor. If Registry
  authority is lost, every socket process is torn down with it; termination therefore
  fails closed to durable disconnect instead of allowing live sockets with missing
  presence registrations.
  """

  alias StrangertalksNew.Hangouts.RoomServer

  @registry StrangertalksNew.Hangouts.PresenceRegistry

  def register(room_id, participant_id, lease_id)
      when is_binary(room_id) and is_binary(participant_id) and is_binary(lease_id) do
    case registry_call(fn ->
           Registry.register(@registry, key(room_id, participant_id), lease_id)
         end) do
      {:ok, {:ok, _owner}} -> :ok
      {:ok, {:error, {:already_registered, _owner}}} -> {:error, :presence_already_registered}
      {:error, :registry_unavailable} -> {:error, :presence_authority_unavailable}
    end
  end

  def register(_room_id, _participant_id, _lease_id), do: {:error, :invalid_presence_lease}

  def unregister(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    _ = registry_call(fn -> Registry.unregister(@registry, key(room_id, participant_id)) end)
    :ok
  end

  def disconnect_if_last(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    presence_key = key(room_id, participant_id)

    with {:ok, _} <- registry_call(fn -> Registry.unregister(@registry, presence_key) end),
         {:ok, registrations} <- registry_call(fn -> Registry.lookup(@registry, presence_key) end) do
      case registrations do
        [] -> RoomServer.disconnect(room_id, participant_id)
        [_ | _] -> RoomServer.snapshot(room_id, participant_id)
      end
    else
      {:error, :registry_unavailable} ->
        # Presence Registry failure restarts the Endpoint and therefore all channel
        # processes. With no transport allowed to survive that failure domain, the
        # safe durable state during teardown is DISCONNECTED.
        RoomServer.disconnect(room_id, participant_id)
    end
  end

  def disconnect_if_last(_room_id, _participant_id),
    do: {:error, :invalid_membership_request}

  def revoke_other_channels(room_id, participant_id, leaving_pid)
      when is_binary(room_id) and is_binary(participant_id) and is_pid(leaving_pid) do
    case registry_call(fn -> Registry.lookup(@registry, key(room_id, participant_id)) end) do
      {:ok, registrations} ->
        Enum.each(registrations, fn
          {pid, _lease_id} when pid != leaving_pid ->
            send(pid, {:hangout_presence_revoked, room_id, participant_id})

          _registration ->
            :ok
        end)

        :ok

      {:error, :registry_unavailable} ->
        # Transport restart already revokes every channel in this failure domain.
        :ok
    end
  end

  def revoke_other_channels(_room_id, _participant_id, _leaving_pid),
    do: {:error, :invalid_presence_revoke}

  def live_channel_count(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    case registry_call(fn -> Registry.lookup(@registry, key(room_id, participant_id)) end) do
      {:ok, registrations} -> length(registrations)
      {:error, :registry_unavailable} -> 0
    end
  end

  def live_channel_count(_room_id, _participant_id), do: 0

  defp registry_call(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    catch
      :exit, _reason -> {:error, :registry_unavailable}
    end
  end

  defp key(room_id, participant_id), do: {room_id, participant_id}
end
