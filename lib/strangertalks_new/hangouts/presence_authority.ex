defmodule StrangertalksNew.Hangouts.PresenceAuthority do
  @moduledoc """
  Server-owned Hangout channel-lifetime authority.

  The authority is one supervised process that serializes registration, replacement,
  termination and liveness decisions for every Hangout channel. Each channel owns one
  server-generated lease and is monitored by process identity; browsers cannot author
  presence truth.

  PresenceAuthority and Phoenix Endpoint share a rest-for-one supervisor. If this
  authority process is lost, the Endpoint and all channel processes are torn down with
  it so no live transport can survive missing presence state.
  """

  use GenServer

  alias StrangertalksNew.Hangouts.RoomServer

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{registrations: %{}, refs: %{}}}
  end

  def register(room_id, participant_id, lease_id)
      when is_binary(room_id) and is_binary(participant_id) and is_binary(lease_id) do
    safe_call({:register, room_id, participant_id, lease_id}, {:error, :presence_authority_unavailable})
  end

  def register(_room_id, _participant_id, _lease_id), do: {:error, :invalid_presence_lease}

  def unregister(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    safe_call({:unregister, room_id, participant_id}, :ok)
  end

  def unregister(_room_id, _participant_id), do: :ok

  def disconnect_if_last(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    safe_call(
      {:disconnect_if_last, room_id, participant_id},
      {:error, :presence_authority_unavailable}
    )
  end

  def disconnect_if_last(_room_id, _participant_id),
    do: {:error, :invalid_membership_request}

  def revoke_other_channels(room_id, participant_id, leaving_pid)
      when is_binary(room_id) and is_binary(participant_id) and is_pid(leaving_pid) do
    safe_call({:revoke_other_channels, room_id, participant_id, leaving_pid}, :ok)
  end

  def revoke_other_channels(_room_id, _participant_id, _leaving_pid),
    do: {:error, :invalid_presence_revoke}

  def live_channel_count(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    safe_call({:live_channel_count, room_id, participant_id}, 0)
  end

  def live_channel_count(_room_id, _participant_id), do: 0

  @impl true
  def handle_call({:register, room_id, participant_id, lease_id}, {pid, _tag}, state) do
    case Map.get(state.registrations, pid) do
      nil ->
        ref = Process.monitor(pid)
        registration = %{key: {room_id, participant_id}, lease_id: lease_id, ref: ref}

        new_state = %{
          registrations: Map.put(state.registrations, pid, registration),
          refs: Map.put(state.refs, ref, pid)
        }

        {:reply, :ok, new_state}

      %{key: {^room_id, ^participant_id}, lease_id: ^lease_id} ->
        {:reply, :ok, state}

      _existing ->
        {:reply, {:error, :presence_already_registered}, state}
    end
  end

  def handle_call({:unregister, room_id, participant_id}, {pid, _tag}, state) do
    {removed?, new_state} = remove_registration(state, pid, {room_id, participant_id})
    {:reply, if(removed?, do: :ok, else: :ok), new_state}
  end

  def handle_call({:disconnect_if_last, room_id, participant_id}, {pid, _tag}, state) do
    key = {room_id, participant_id}
    {_removed?, new_state} = remove_registration(state, pid, key)

    reply =
      if any_registered?(new_state, key) do
        RoomServer.snapshot(room_id, participant_id)
      else
        RoomServer.disconnect_authoritatively(room_id, participant_id)
      end

    {:reply, reply, new_state}
  end

  def handle_call({:revoke_other_channels, room_id, participant_id, leaving_pid}, _from, state) do
    key = {room_id, participant_id}

    Enum.each(state.registrations, fn
      {pid, %{key: ^key}} when pid != leaving_pid ->
        send(pid, {:hangout_presence_revoked, room_id, participant_id})

      _registration ->
        :ok
    end)

    {:reply, :ok, state}
  end

  def handle_call({:live_channel_count, room_id, participant_id}, _from, state) do
    {:reply, count_registered(state, {room_id, participant_id}), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.refs, ref) do
      ^pid ->
        case Map.get(state.registrations, pid) do
          %{key: {room_id, participant_id} = key} ->
            {_removed?, new_state} = remove_registration(state, pid, key, demonitor?: false)

            if not any_registered?(new_state, key) do
              _ = RoomServer.disconnect_authoritatively(room_id, participant_id)
            end

            {:noreply, new_state}

          _ ->
            {:noreply, %{state | refs: Map.delete(state.refs, ref)}}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp remove_registration(state, pid, key, opts \\ []) do
    case Map.get(state.registrations, pid) do
      %{key: ^key, ref: ref} ->
        if Keyword.get(opts, :demonitor?, true), do: Process.demonitor(ref, [:flush])

        {true,
         %{
           registrations: Map.delete(state.registrations, pid),
           refs: Map.delete(state.refs, ref)
         }}

      _ ->
        {false, state}
    end
  end

  defp any_registered?(state, key), do: count_registered(state, key) > 0

  defp count_registered(state, key) do
    Enum.count(state.registrations, fn {_pid, registration} -> registration.key == key end)
  end

  defp safe_call(message, fallback) do
    try do
      GenServer.call(__MODULE__, message)
    catch
      :exit, _reason -> fallback
    end
  end
end
