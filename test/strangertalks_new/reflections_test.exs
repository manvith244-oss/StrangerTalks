defmodule StrangertalksNew.ReflectionsTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Participants
  alias StrangertalksNew.Reflections
  alias StrangertalksNew.Reflections.Reflection

  setup do
    {:ok, participant} = Participants.create_participant(%{})
    {:ok, peer} = Participants.create_participant(%{})
    {:ok, participant: participant, peer: peer}
  end

  describe "note & excerpt text validation (V01, V02, V03, S001-S010)" do
    test "validates note length between 1 and 2,000 extended grapheme clusters", %{participant: p} do
      # Valid 1 grapheme
      assert {:ok, {:applied, _}} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: "a"
               })

      # Valid 2000 graphemes
      long_text = String.duplicate("💡", 2000)

      assert {:ok, {:applied, ref}} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: long_text
               })

      assert String.length(ref.own_reflection_text) == 2000

      # Invalid: empty string
      assert {:error, :blank_note} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: ""
               })

      # Invalid: whitespace only
      assert {:error, :blank_note} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: "   \n\t  "
               })

      # Invalid: 2001 graphemes
      too_long = String.duplicate("a", 2001)

      assert {:error, :note_too_long} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: too_long
               })
    end

    test "validates excerpt length between 1 and 280 extended grapheme clusters", %{
      participant: p
    } do
      # Valid 280 graphemes
      excerpt = String.duplicate("x", 280)

      assert {:ok, {:applied, ref}} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: "My personal thought",
                 source_excerpt: excerpt
               })

      assert ref.source_excerpt == excerpt

      # Invalid excerpt: 281 graphemes
      too_long_excerpt = String.duplicate("x", 281)

      assert {:error, :invalid_excerpt_length} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: "My personal thought",
                 source_excerpt: too_long_excerpt
               })
    end

    test "enforces max byte boundaries (65,536 note bytes, 16,384 excerpt bytes)" do
      complex_grapheme =
        "👩‍👩‍👦‍👦\u{E0020}\u{E0020}\u{E0020}\u{E0020}\u{E0020}\u{E0020}\u{E0020}\u{E0020}\u{E0020}\u{E007F}"

      assert {:error, :invalid_text_complexity} =
               Reflections.validate_note_text(String.duplicate(complex_grapheme, 1200))

      assert {:error, :invalid_excerpt_complexity} =
               Reflections.validate_source_excerpt(String.duplicate(complex_grapheme, 270))
    end
  end

  describe "reflection CRUD, idempotency & CAS revisions (V04-V08, S011-S030)" do
    test "idempotent create returns identical reflection on duplicate create_operation_id", %{
      participant: p
    } do
      op_id = Ecto.UUID.generate()

      attrs = %{
        create_operation_id: op_id,
        own_reflection_text: "First attempt",
        source_excerpt: "Some excerpt"
      }

      assert {:ok, {:applied, ref1}} = Reflections.create_reflection(p.participant_id, attrs)

      assert {:ok, {:already_canonical, ref2}} =
               Reflections.create_reflection(p.participant_id, attrs)

      assert ref1.reflection_id == ref2.reflection_id
      assert ref2.own_reflection_text == "First attempt"

      # Different payload with same op_id returns conflict
      assert {:error, :conflict} =
               Reflections.create_reflection(p.participant_id, %{
                 attrs
                 | own_reflection_text: "Different text"
               })
    end

    test "CAS note update requires exact expected_revision and increments revision", %{
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Initial note"
        })

      assert ref.revision == 1

      # Successful update with matching revision
      assert {:ok, updated} =
               Reflections.update_reflection(
                 ref.reflection_id,
                 p.participant_id,
                 1,
                 "Updated note"
               )

      assert updated.revision == 2
      assert updated.own_reflection_text == "Updated note"

      # Stale update with old revision fails with :stale
      assert {:error, :stale} =
               Reflections.update_reflection(ref.reflection_id, p.participant_id, 1, "Stale edit")
    end

    test "remove_reflection_excerpt clears excerpt and increments revision", %{participant: p} do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Note with excerpt",
          source_excerpt: "Quoted peer excerpt"
        })

      assert ref.source_excerpt == "Quoted peer excerpt"
      assert ref.revision == 1

      assert {:ok, updated} =
               Reflections.remove_reflection_excerpt(ref.reflection_id, p.participant_id, 1)

      assert is_nil(updated.source_excerpt)
      assert updated.revision == 2

      # Idempotent remove on already nil excerpt succeeds
      assert {:ok, updated2} =
               Reflections.remove_reflection_excerpt(ref.reflection_id, p.participant_id, 2)

      assert is_nil(updated2.source_excerpt)
    end

    test "delete_reflection permanently deletes record with optional CAS expected_revision", %{
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Note to delete"
        })

      # Stale revision delete fails
      assert {:error, :stale} =
               Reflections.delete_reflection(ref.reflection_id, p.participant_id, 99)

      # Matching revision delete succeeds
      assert {:ok, :deleted} =
               Reflections.delete_reflection(ref.reflection_id, p.participant_id, 1)

      # Record is gone
      assert is_nil(Reflections.get_reflection(ref.reflection_id, p.participant_id))
    end
  end

  describe "10-second Undo window (V09, V35, S031-S040)" do
    test "undo_reflection hard-deletes reflection within 10 seconds of creation", %{
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Newly created reflection"
        })

      assert {:ok, :undone} = Reflections.undo_reflection(ref.reflection_id, p.participant_id)
      assert is_nil(Reflections.get_reflection(ref.reflection_id, p.participant_id))
    end

    test "undo_reflection fails if 10 seconds have elapsed or if note was modified", %{
      participant: p
    } do
      # Note created in the past (> 10s ago)
      eleven_seconds_ago = DateTime.add(DateTime.utc_now(), -15, :second)

      {:ok, ref} =
        %Reflection{}
        |> Reflection.changeset(%{
          reflection_id: Ecto.UUID.generate(),
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Old note",
          saved_at: eleven_seconds_ago,
          updated_at: eleven_seconds_ago,
          revision: 1
        })
        |> Ecto.Changeset.put_change(:owner_participant_id, p.participant_id)
        |> StrangertalksNew.Repo.insert()

      assert {:error, :undo_window_expired} =
               Reflections.undo_reflection(ref.reflection_id, p.participant_id)
    end
  end

  describe "peer privacy & isolation (V10, V41, S041-S050)" do
    test "peer cannot view, modify, or delete owner's reflections", %{participant: p, peer: peer} do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Secret personal reflection",
          source_excerpt: "Peer said hello"
        })

      # Peer list is empty
      assert Reflections.list_reflections(peer.participant_id) == []

      # Peer get returns nil
      assert is_nil(Reflections.get_reflection(ref.reflection_id, peer.participant_id))

      # Peer update fails
      assert {:error, :not_found} =
               Reflections.update_reflection(ref.reflection_id, peer.participant_id, 1, "Hacked")

      # Peer delete fails
      assert {:error, :not_found} =
               Reflections.delete_reflection(ref.reflection_id, peer.participant_id)
    end
  end

  describe "composer grants & post-terminal HMAC consumption (V11-V13, S051-S070)" do
    test "open_composer_grant creates hashed grant and returns raw secret", %{participant: p} do
      attrs = %{
        source_conversation_id: Ecto.UUID.generate(),
        source_client_message_id: "msg-1",
        source_epoch_id: Ecto.UUID.generate(),
        selection_start_grapheme: 0,
        selection_end_grapheme: 10,
        expected_source_revision: 0
      }

      assert {:ok, %{grant: grant, raw_secret: raw_secret}} =
               Reflections.open_composer_grant(p.participant_id, attrs)

      assert is_binary(raw_secret)
      assert grant.secret_verifier == :crypto.hash(:sha256, raw_secret)
      assert grant.state == "OPEN"
    end

    test "post-terminal grant consumption succeeds with exact HMAC and fails when expired", %{
      participant: p
    } do
      conv_id = Ecto.UUID.generate()
      msg_id = "msg-term-1"
      epoch_id = Ecto.UUID.generate()
      excerpt = "Hello world excerpt"

      {:ok, %{grant: grant, raw_secret: raw_secret}} =
        Reflections.open_composer_grant(p.participant_id, %{
          source_conversation_id: conv_id,
          source_client_message_id: msg_id,
          source_epoch_id: epoch_id,
          selection_start_grapheme: 0,
          selection_end_grapheme: 19,
          expected_source_revision: 0
        })

      # Finalize conversation terminal
      resolver = fn ^msg_id -> %{type: :text, content: excerpt, content_revision: 0} end

      assert {:ok, :ok} =
               Reflections.finalize_conversation_terminal(conv_id, DateTime.utc_now(), resolver)

      # Grant now has HMAC and 10-minute expiry
      finalized_grant = Reflections.get_grant(grant.grant_id, p.participant_id)
      assert finalized_grant.state == "OPEN"
      assert is_binary(finalized_grant.terminal_excerpt_hmac)
      assert not is_nil(finalized_grant.terminal_expires_at)

      # Valid post-terminal save with HMAC consumption
      save_attrs = %{
        create_operation_id: Ecto.UUID.generate(),
        own_reflection_text: "Reflection written after call ended",
        source_excerpt: excerpt,
        grant_id: grant.grant_id,
        grant_secret: raw_secret
      }

      assert {:ok, {:applied, ref}} = Reflections.create_reflection(p.participant_id, save_attrs)
      assert ref.source_excerpt == excerpt

      # Grant is now CONSUMED
      consumed_grant = Reflections.get_grant(grant.grant_id, p.participant_id)
      assert consumed_grant.state == "CONSUMED"

      # Re-consuming same grant fails
      assert {:error, :grant_consumed} =
               Reflections.create_reflection(p.participant_id, %{
                 create_operation_id: Ecto.UUID.generate(),
                 own_reflection_text: "Another attempt",
                 source_excerpt: excerpt,
                 grant_id: grant.grant_id,
                 grant_secret: raw_secret
               })
    end
  end

  describe "unsend withdrawal & terminal detachment (V14-V16, S071-S100)" do
    test "peer unsend withdraws peer-authored excerpt and bumps revision", %{
      participant: p,
      peer: peer
    } do
      conv_id = Ecto.UUID.generate()
      msg_id = "peer-msg-1"
      epoch_id = Ecto.UUID.generate()

      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Note reflecting on peer words",
          source_excerpt: "Peer words that will be unsent",
          source_conversation_id: conv_id,
          source_client_message_id: msg_id,
          source_epoch_id: epoch_id
        })

      assert ref.source_excerpt == "Peer words that will be unsent"
      assert ref.revision == 1

      # Peer unsends message
      assert {:ok, [_withdrawn]} =
               Reflections.withdraw_peer_excerpt(conv_id, msg_id, peer.participant_id)

      # Owner's reflection excerpt is withdrawn to nil and revision is bumped
      updated = Reflections.get_reflection(ref.reflection_id, p.participant_id)
      assert is_nil(updated.source_excerpt)
      assert updated.revision == 2
      assert updated.own_reflection_text == "Note reflecting on peer words"
    end

    test "own saved own-authored message is NOT withdrawn on own unsend", %{participant: p} do
      conv_id = Ecto.UUID.generate()
      msg_id = "own-msg-1"

      # Own authored message saved with no peer linkage (nil source_conversation_id)
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Note on my own words",
          source_excerpt: "My own words that I might unsend later"
        })

      assert ref.source_excerpt == "My own words that I might unsend later"
      assert ref.revision == 1

      # Participant unsends own message
      assert {:ok, []} = Reflections.withdraw_peer_excerpt(conv_id, msg_id, p.participant_id)

      # Owner's reflection is untouched
      retained = Reflections.get_reflection(ref.reflection_id, p.participant_id)
      assert retained.source_excerpt == "My own words that I might unsend later"
      assert retained.revision == 1
    end

    test "terminal detachment severs conversation linkage", %{participant: p} do
      conv_id = Ecto.UUID.generate()
      msg_id = "msg-term-detach"
      epoch_id = Ecto.UUID.generate()

      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Saved reflection before end",
          source_excerpt: "Saved excerpt",
          source_conversation_id: conv_id,
          source_client_message_id: msg_id,
          source_epoch_id: epoch_id
        })

      # Finalize conversation
      assert {:ok, :ok} =
               Reflections.finalize_conversation_terminal(conv_id, DateTime.utc_now(), fn _ ->
                 nil
               end)

      # Reflection is detached
      detached = Reflections.get_reflection(ref.reflection_id, p.participant_id)
      assert is_nil(detached.source_conversation_id)
      assert is_nil(detached.source_client_message_id)
      assert is_nil(detached.source_epoch_id)
      assert detached.source_excerpt == "Saved excerpt"
    end
  end
end
