defmodule StrangertalksNew.Hangouts.DomainContractTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.Hangouts.ContentCatalog
  alias StrangertalksNew.Hangouts.HangoutMembership
  alias StrangertalksNew.Hangouts.HangoutMessage
  alias StrangertalksNew.Hangouts.HangoutReport
  alias StrangertalksNew.Hangouts.HangoutRoom
  alias StrangertalksNew.Hangouts.TemporaryIdentity

  @now DateTime.from_naive!(~N[2026-09-10 00:30:00.000000], "Etc/UTC")
  @participant_id "11111111-1111-1111-1111-111111111111"
  @other_participant_id "22222222-2222-2222-2222-222222222222"
  @room_id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  test "room contract accepts an extensible language tag and tunable small-group bounds" do
    changeset =
      HangoutRoom.changeset(%HangoutRoom{}, %{
        created_at: @now,
        status: :FORMING,
        language_tag: "pt-BR",
        experiment_arm: :GROUP_WITH_CONTENT,
        minimum_size: 3,
        target_size: 4,
        max_size: 6
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :language_tag) == "pt-BR"
    assert Ecto.Changeset.get_field(changeset, :target_size) == 4
  end

  test "room contract rejects impossible capacity ordering" do
    changeset =
      HangoutRoom.changeset(%HangoutRoom{}, %{
        created_at: @now,
        status: :FORMING,
        language_tag: "en",
        experiment_arm: :GROUP_WITH_CONTENT,
        minimum_size: 5,
        target_size: 4,
        max_size: 4
      })

    refute changeset.valid?
    assert "must be less than or equal to target size" in errors_on(changeset).minimum_size
  end

  test "membership identity is room-scoped and participant ids are set by authority" do
    changeset =
      HangoutMembership.changeset(
        %HangoutMembership{},
        %{
          joined_at: @now,
          last_seen_at: @now,
          status: :ACTIVE,
          temporary_identity_slot: 2,
          temporary_identity_label: "Moon",
          temporary_identity_emoji: "🌙"
        },
        @room_id,
        @participant_id
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :room_id) == @room_id
    assert Ecto.Changeset.get_field(changeset, :participant_id) == @participant_id
  end

  test "message body is bounded by bytes and sequencing comes from room authority" do
    valid =
      HangoutMessage.changeset(
        %HangoutMessage{},
        %{body: "hello room", client_message_id: "client-1", created_at: @now},
        @room_id,
        "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        7
      )

    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :sequence) == 7

    oversized = String.duplicate("a", HangoutMessage.max_body_bytes() + 1)

    invalid =
      HangoutMessage.changeset(
        %HangoutMessage{},
        %{body: oversized, client_message_id: "client-2", created_at: @now},
        @room_id,
        "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        8
      )

    refute invalid.valid?
    assert "is too large" in errors_on(invalid).body
  end

  test "temporary identities are deterministic for a participant and avoid occupied room slots" do
    assert {:ok, first} = TemporaryIdentity.slot_for(@room_id, @participant_id, [])
    assert {:ok, same} = TemporaryIdentity.slot_for(@room_id, @participant_id, [])
    assert first == same
    assert is_integer(first.slot)
    assert is_binary(first.label)
    assert is_binary(first.emoji)

    assert {:ok, alternate} =
             TemporaryIdentity.slot_for(@room_id, @participant_id, [first.slot])

    refute alternate.slot == first.slot
  end

  test "curated content is first-party approved and language metadata stays extensible" do
    items = ContentCatalog.items("pt-BR")

    assert length(items) > 0

    assert Enum.all?(items, fn item ->
             item.source == :FIRST_PARTY and item.safety_status == :APPROVED and
               item.publication_status == :ACTIVE and is_binary(item.id) and
               item.language_tag in ["pt-BR", "und"]
           end)
  end

  test "hangout reports reject self-reporting while allowing another active participant target" do
    self_report =
      HangoutReport.changeset(
        %HangoutReport{},
        %{
          created_at: @now,
          updated_at: @now,
          category: "HARASSMENT",
          status: "SUBMITTED",
          evidence: "context"
        },
        @room_id,
        @participant_id,
        @participant_id
      )

    refute self_report.valid?
    assert "cannot report yourself" in errors_on(self_report).reported_participant_id

    other_report =
      HangoutReport.changeset(
        %HangoutReport{},
        %{
          created_at: @now,
          updated_at: @now,
          category: "HARASSMENT",
          status: "SUBMITTED",
          evidence: "context"
        },
        @room_id,
        @participant_id,
        @other_participant_id
      )

    assert other_report.valid?
  end
end
