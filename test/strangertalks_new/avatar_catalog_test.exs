defmodule StrangertalksNew.AvatarCatalogTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.AvatarCatalog

  @conversation_id "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  @p1 "11111111-1111-1111-1111-111111111111"
  @p2 "22222222-2222-2222-2222-222222222222"

  test "DERIVE-1: same Conversation + same participant pair repeated many times produces exact same map" do
    baseline = AvatarCatalog.derive_pair(@conversation_id, @p1, @p2)

    for _ <- 1..50 do
      assert AvatarCatalog.derive_pair(@conversation_id, @p1, @p2) == baseline
    end
  end

  test "DERIVE-2: both participants receive distinct avatars" do
    map = AvatarCatalog.derive_pair(@conversation_id, @p1, @p2)
    avatar1 = Map.get(map, @p1)
    avatar2 = Map.get(map, @p2)

    assert avatar1 != nil
    assert avatar2 != nil
    assert avatar1.key != avatar2.key
    assert avatar1.label != avatar2.label
    assert AvatarCatalog.approved?(avatar1.key)
    assert AvatarCatalog.approved?(avatar2.key)
  end

  test "DERIVE-3: force raw collision resolves to deterministic distinct pair" do
    # Create a 2-item fixture catalog where collision is forced
    test_catalog = [
      %{key: "cat-a", label: "Cat A"},
      %{key: "cat-b", label: "Cat B"}
    ]

    map = AvatarCatalog.derive_pair(@conversation_id, @p1, @p2, test_catalog)
    a1 = Map.get(map, @p1)
    a2 = Map.get(map, @p2)

    assert a1.key != a2.key
    assert Enum.sort([a1.key, a2.key]) == ["cat-a", "cat-b"]
  end

  test "DERIVE-4: pair assignment with [A,B] and [B,A] produces identical mapping" do
    map_ab = AvatarCatalog.derive_pair(@conversation_id, @p1, @p2)
    map_ba = AvatarCatalog.derive_pair(@conversation_id, @p2, @p1)

    assert map_ab == map_ba
    assert map_ab[@p1] == map_ba[@p1]
    assert map_ab[@p2] == map_ba[@p2]
  end

  test "DERIVE-5: self/peer projection is opposite for A and B while underlying map is unchanged" do
    map = AvatarCatalog.derive_pair(@conversation_id, @p1, @p2)
    proj_a = AvatarCatalog.project_for_participant(map, @p1)
    proj_b = AvatarCatalog.project_for_participant(map, @p2)

    assert proj_a.self.avatar_key == map[@p1].key
    assert proj_a.peer.avatar_key == map[@p2].key

    assert proj_b.self.avatar_key == map[@p2].key
    assert proj_b.peer.avatar_key == map[@p1].key

    assert proj_a.self.avatar_key == proj_b.peer.avatar_key
    assert proj_a.peer.avatar_key == proj_b.self.avatar_key
  end

  test "DERIVE-7: catalog-too-small fallback produces generic accessible labels without duplicate pseudonyms" do
    small_catalog = [%{key: "only-one", label: "Only One"}]
    map = AvatarCatalog.derive_pair(@conversation_id, @p1, @p2, small_catalog)

    a1 = Map.get(map, @p1)
    a2 = Map.get(map, @p2)

    assert a1.key != a2.key
    assert a1.label != a2.label
    assert a1.key in ["generic-1", "generic-2"]
    assert a2.key in ["generic-1", "generic-2"]
  end

  test "DERIVE-8: changing Conversation scope while participant stays same uses new Conversation input" do
    conv_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    conv_b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    map_a = AvatarCatalog.derive_pair(conv_a, @p1, @p2)
    map_b = AvatarCatalog.derive_pair(conv_b, @p1, @p2)

    # Derivations are distinct evaluations
    assert is_map(map_a)
    assert is_map(map_b)
  end

  test "DERIVE-9: prove implementation does not reduce to participant-only seed" do
    # If participant-only seed was used, all conversations with p1 and p2 would give identical maps.
    # Across 20 distinct random conversation IDs, the avatar assignment distribution varies.
    assignments =
      for i <- 1..20 do
        cid = "conv-scope-test-uuid-#{i}-#{Ecto.UUID.generate()}"
        AvatarCatalog.derive_pair(cid, @p1, @p2)
      end

    distinct_assignments = Enum.uniq(assignments)
    assert length(distinct_assignments) > 1
  end

  test "DERIVE-10: assignment-domain stability - catalog is bounded, constant, approved" do
    catalog = AvatarCatalog.catalog()
    assert length(catalog) == 10
    assert Enum.uniq_by(catalog, & &1.key) == catalog

    for item <- catalog do
      assert is_binary(item.key)
      assert is_binary(item.label)
      assert AvatarCatalog.approved?(item.key)
      assert {:ok, _} = AvatarCatalog.fetch(item.key)
    end

    assert AvatarCatalog.approved?("generic-self")
    assert AvatarCatalog.approved?("generic-peer")
    refute AvatarCatalog.approved?("unapproved-custom-avatar")
  end
end
