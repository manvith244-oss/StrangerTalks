defmodule StrangertalksNew.Hangouts.TemporaryIdentity do
  @identities [
    %{emoji: "🐼", label: "Panda"},
    %{emoji: "🦊", label: "Fox"},
    %{emoji: "🌙", label: "Moon"},
    %{emoji: "🌵", label: "Cactus"},
    %{emoji: "🐸", label: "Frog"},
    %{emoji: "🦦", label: "Otter"},
    %{emoji: "🪁", label: "Kite"},
    %{emoji: "🌊", label: "Wave"},
    %{emoji: "🐯", label: "Tiger"},
    %{emoji: "🍀", label: "Clover"},
    %{emoji: "🐧", label: "Penguin"},
    %{emoji: "☄️", label: "Comet"}
  ]

  def slot_for(room_id, participant_id, occupied_slots)
      when is_binary(room_id) and is_binary(participant_id) and is_list(occupied_slots) do
    identity_count = length(@identities)
    occupied = MapSet.new(Enum.filter(occupied_slots, &is_integer/1))
    start_slot = :erlang.phash2({room_id, participant_id}, identity_count)

    0..(identity_count - 1)
    |> Enum.map(&rem(start_slot + &1, identity_count))
    |> Enum.find(&(not MapSet.member?(occupied, &1)))
    |> case do
      nil ->
        {:error, :identity_pool_exhausted}

      slot ->
        identity = Enum.at(@identities, slot)
        {:ok, Map.put(identity, :slot, slot)}
    end
  end

  def slot_for(_room_id, _participant_id, _occupied_slots),
    do: {:error, :invalid_identity_request}

  def pool_size, do: length(@identities)
end
