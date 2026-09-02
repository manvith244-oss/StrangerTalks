defmodule StrangertalksNew.AvatarCatalog do
  @moduledoc """
  Bounded, static, first-party anonymous avatar catalog and deterministic
  Conversation-scoped pair derivation for Feature 1P.
  """

  @catalog [
    %{key: "moon-fox", label: "Moon Fox"},
    %{key: "rain-owl", label: "Rain Owl"},
    %{key: "sun-bear", label: "Sun Bear"},
    %{key: "star-deer", label: "Star Deer"},
    %{key: "cloud-otter", label: "Cloud Otter"},
    %{key: "dune-hare", label: "Dune Hare"},
    %{key: "ember-cat", label: "Ember Cat"},
    %{key: "frost-wolf", label: "Frost Wolf"},
    %{key: "moss-badger", label: "Moss Badger"},
    %{key: "river-heron", label: "River Heron"}
  ]

  @fallback_self %{
    key: "generic-self",
    label: "You",
    asset_url: "/assets/avatars/generic-self.svg"
  }
  @fallback_peer %{
    key: "generic-peer",
    label: "Other participant",
    asset_url: "/assets/avatars/generic-peer.svg"
  }

  @doc """
  Returns the static V1 avatar catalog.
  """
  def catalog, do: @catalog

  @doc """
  Checks if an avatar key is an approved V1 avatar key.
  """
  def approved?(key) when is_binary(key) do
    Enum.any?(@catalog, &(&1.key == key)) or
      key in ["generic-self", "generic-peer", "generic-1", "generic-2"]
  end

  def approved?(_), do: false

  @doc """
  Fetches an avatar entry by key.
  """
  def fetch(key) when is_binary(key) do
    case Enum.find(@catalog, &(&1.key == key)) do
      nil ->
        if key in ["generic-self", "generic-peer", "generic-1", "generic-2"] do
          label =
            case key do
              "generic-self" -> "You"
              "generic-1" -> "You"
              _ -> "Other participant"
            end

          {:ok, %{key: key, label: label}}
        else
          {:error, :unknown_avatar}
        end

      item ->
        {:ok, item}
    end
  end

  def fetch(_), do: {:error, :unknown_avatar}

  @doc """
  Deterministically derives a distinct avatar for each participant in a Conversation.

  Guarantees:
  1. Identical output regardless of `[p1, p2]` vs `[p2, p1]` input order.
  2. Distinct avatars for both participants (collision-free).
  3. Conversation scope genuinely participates in hash (no participant-only seed).
  4. Same Conversation + same participants -> exact same assignment.
  """
  def derive_pair(conversation_id, p1, p2, catalog_override \\ nil)
      when is_binary(conversation_id) and is_binary(p1) and is_binary(p2) do
    active_catalog = catalog_override || @catalog

    if length(active_catalog) < 2 do
      [first_id, second_id] = Enum.sort([p1, p2])

      %{
        first_id => %{key: "generic-1", label: "You"},
        second_id => %{key: "generic-2", label: "Other participant"}
      }
    else
      [first_id, second_id] = Enum.sort([p1, p2])
      cat_len = length(active_catalog)

      # Derive index for first canonical participant
      val1 = hash_to_uint32("avatar:#{conversation_id}:#{first_id}")
      idx1 = rem(val1, cat_len)
      avatar1 = Enum.at(active_catalog, idx1)

      # Derive index for second canonical participant with deterministic collision resolution
      val2 = hash_to_uint32("avatar:#{conversation_id}:#{second_id}")
      raw_idx2 = rem(val2, cat_len)

      idx2 =
        if raw_idx2 == idx1 do
          rem(idx1 + 1 + rem(val2, cat_len - 1), cat_len)
        else
          raw_idx2
        end

      avatar2 = Enum.at(active_catalog, idx2)

      %{
        first_id => avatar1,
        second_id => avatar2
      }
    end
  end

  @doc """
  Projects canonical participant->avatar map into self/peer view for a specific participant.
  """
  def project_for_participant(canonical_map, viewer_id)
      when is_map(canonical_map) and is_binary(viewer_id) do
    self_avatar = Map.get(canonical_map, viewer_id)
    peer_id = Enum.find(Map.keys(canonical_map), &(&1 != viewer_id))
    peer_avatar = if peer_id, do: Map.get(canonical_map, peer_id), else: nil

    self_proj =
      if self_avatar do
        %{
          avatar_key: self_avatar.key,
          label: self_avatar.label,
          asset_url: "/assets/avatars/#{self_avatar.key}.svg"
        }
      else
        @fallback_self
      end

    peer_proj =
      if peer_avatar do
        %{
          avatar_key: peer_avatar.key,
          label: peer_avatar.label,
          asset_url: "/assets/avatars/#{peer_avatar.key}.svg"
        }
      else
        @fallback_peer
      end

    %{
      self: self_proj,
      peer: peer_proj
    }
  end

  defp hash_to_uint32(data) do
    <<uint::unsigned-big-integer-size(32), _rest::binary>> = :crypto.hash(:sha256, data)
    uint
  end
end
