defmodule StrangertalksNew.Reflections do
  @moduledoc """
  Purpose-built context for Feature 1T: Private Save / Reflection.
  """

  import Ecto.Query
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Reflections.{ComposerGrant, Reflection}
  alias StrangertalksNewWeb.Endpoint

  @max_note_graphemes 2000
  @max_note_bytes 65_536
  @max_excerpt_graphemes 280
  @max_excerpt_bytes 16_384
  @undo_window_seconds 10
  @post_terminal_window_seconds 600

  @doc """
  Validates own reflection note text.
  Requires valid UTF-8, NFC normalized, trimmed, 1..2,000 graphemes, <=65,536 bytes.
  """
  def validate_note_text(raw_text) when is_binary(raw_text) do
    if not String.valid?(raw_text) do
      {:error, :invalid_utf8}
    else
      normalized = :unicode.characters_to_nfc_binary(raw_text)
      trimmed = String.trim(normalized)
      graphemes = String.length(trimmed)
      bytes = byte_size(trimmed)

      cond do
        graphemes < 1 -> {:error, :blank_note}
        graphemes > @max_note_graphemes -> {:error, :note_too_long}
        bytes > @max_note_bytes -> {:error, :invalid_text_complexity}
        true -> {:ok, trimmed}
      end
    end
  end

  def validate_note_text(_), do: {:error, :blank_note}

  @doc """
  Validates optional source excerpt text.
  If present, requires 1..280 graphemes, <=16,384 bytes.
  """
  def validate_source_excerpt(nil), do: {:ok, nil}

  def validate_source_excerpt(excerpt) when is_binary(excerpt) do
    if not String.valid?(excerpt) do
      {:error, :invalid_utf8}
    else
      graphemes = String.length(excerpt)
      bytes = byte_size(excerpt)

      cond do
        graphemes < 1 or graphemes > @max_excerpt_graphemes -> {:error, :invalid_excerpt_length}
        bytes > @max_excerpt_bytes -> {:error, :invalid_excerpt_complexity}
        true -> {:ok, excerpt}
      end
    end
  end

  def validate_source_excerpt(_), do: {:error, :invalid_excerpt}

  @doc """
  Lists all reflections for an authenticated owner participant.
  """
  def list_reflections(participant_id) when is_binary(participant_id) do
    from(r in Reflection,
      where: r.owner_participant_id == ^participant_id,
      order_by: [desc: r.saved_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single reflection owned by participant.
  """
  def get_reflection(reflection_id, participant_id)
      when is_binary(reflection_id) and is_binary(participant_id) do
    Repo.get_by(Reflection,
      reflection_id: reflection_id,
      owner_participant_id: participant_id
    )
  end

  @doc """
  Creates a new Reflection with idempotency support on create_operation_id.
  """
  def create_reflection(participant_id, attrs) when is_binary(participant_id) and is_map(attrs) do
    with {:ok, op_id} <- parse_uuid(attrs[:create_operation_id] || attrs["create_operation_id"]),
         {:ok, note} <-
           validate_note_text(attrs[:own_reflection_text] || attrs["own_reflection_text"]),
         {:ok, excerpt} <-
           validate_source_excerpt(attrs[:source_excerpt] || attrs["source_excerpt"]),
         {:ok, verified_grant} <-
           verify_optional_grant(
             attrs[:grant_id] || attrs["grant_id"],
             attrs[:grant_secret] || attrs["grant_secret"],
             excerpt,
             participant_id
           ) do
      case Repo.get_by(Reflection,
             owner_participant_id: participant_id,
             create_operation_id: op_id
           ) do
        %Reflection{} = existing ->
          if existing.own_reflection_text == note and existing.source_excerpt == excerpt do
            {:ok, {:already_canonical, existing}}
          else
            {:error, :conflict}
          end

        nil ->
          now = DateTime.utc_now()

          source_conv_id =
            case attrs[:source_conversation_id] || attrs["source_conversation_id"] do
              nil -> nil
              cid -> parse_uuid_or_nil(cid)
            end

          source_msg_id =
            attrs[:source_client_message_id] || attrs["source_client_message_id"]

          source_epoch_id =
            case attrs[:source_epoch_id] || attrs["source_epoch_id"] do
              nil -> nil
              eid -> parse_uuid_or_nil(eid)
            end

          reflection_params = %{
            owner_participant_id: participant_id,
            own_reflection_text: note,
            source_excerpt: excerpt,
            revision: 1,
            create_operation_id: op_id,
            saved_at: now,
            updated_at: now,
            source_conversation_id: source_conv_id,
            source_client_message_id: source_msg_id,
            source_epoch_id: source_epoch_id
          }

          Repo.transaction(fn ->
            if verified_grant do
              verified_grant
              |> ComposerGrant.changeset(%{
                state: "CONSUMED",
                updated_at: now
              })
              |> Repo.update!()
            end

            %Reflection{}
            |> Reflection.changeset(reflection_params)
            |> Ecto.Changeset.put_change(:owner_participant_id, participant_id)
            |> Repo.insert()
            |> case do
              {:ok, reflection} ->
                broadcast_owner(participant_id, "reflection:changed", %{
                  reflection_id: reflection.reflection_id,
                  revision: reflection.revision
                })

                reflection

              {:error,
               %Ecto.Changeset{errors: [owner_participant_id: {"has already been taken", _}]}} ->
                case Repo.get_by(Reflection,
                       owner_participant_id: participant_id,
                       create_operation_id: op_id
                     ) do
                  %Reflection{} = existing
                  when existing.own_reflection_text == note and existing.source_excerpt == excerpt ->
                    {:already_canonical, existing}

                  _ ->
                    Repo.rollback(:conflict)
                end

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)
          |> case do
            {:ok, {:already_canonical, existing}} -> {:ok, {:already_canonical, existing}}
            {:ok, %Reflection{} = reflection} -> {:ok, {:applied, reflection}}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp verify_optional_grant(nil, _secret, _excerpt, _participant_id), do: {:ok, nil}

  defp verify_optional_grant(grant_id, secret, excerpt, participant_id) do
    with {:ok, gid} <- parse_uuid(grant_id),
         %ComposerGrant{} = grant <- get_grant(gid, participant_id),
         true <- grant.state == "OPEN" || {:error, :grant_consumed},
         true <-
           (is_binary(secret) and :crypto.hash(:sha256, secret) == grant.secret_verifier) ||
             {:error, :invalid_grant_secret} do
      if grant.terminal_expires_at do
        if DateTime.compare(DateTime.utc_now(), grant.terminal_expires_at) == :gt do
          {:error, :grant_expired}
        else
          if is_nil(excerpt) do
            {:ok, grant}
          else
            if is_nil(grant.terminal_excerpt_hmac) do
              {:error, :grant_invalid}
            else
              expected_hmac = :crypto.mac(:hmac, :sha256, grant.grant_id, excerpt)

              if expected_hmac == grant.terminal_excerpt_hmac do
                {:ok, grant}
              else
                {:error, :grant_invalid}
              end
            end
          end
        end
      else
        {:ok, grant}
      end
    else
      nil -> {:error, :grant_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates own reflection text using revision CAS.
  """
  def update_reflection(reflection_id, participant_id, expected_revision, new_text)
      when is_binary(reflection_id) and is_binary(participant_id) and
             is_integer(expected_revision) do
    with %Reflection{} = reflection <- get_reflection(reflection_id, participant_id),
         true <- reflection.revision == expected_revision || {:error, :stale},
         {:ok, note} <- validate_note_text(new_text) do
      now = DateTime.utc_now()

      reflection
      |> Reflection.changeset(%{
        own_reflection_text: note,
        revision: reflection.revision + 1,
        updated_at: now
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast_owner(participant_id, "reflection:changed", %{
            reflection_id: updated.reflection_id,
            revision: updated.revision
          })

          {:ok, updated}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes source excerpt from a reflection while preserving own note.
  """
  def remove_excerpt(reflection_id, participant_id, expected_revision)
      when is_binary(reflection_id) and is_binary(participant_id) and
             is_integer(expected_revision) do
    with %Reflection{} = reflection <- get_reflection(reflection_id, participant_id),
         true <- reflection.revision == expected_revision || {:error, :stale} do
      now = DateTime.utc_now()

      reflection
      |> Reflection.changeset(%{
        source_excerpt: nil,
        source_conversation_id: nil,
        source_client_message_id: nil,
        source_epoch_id: nil,
        revision: reflection.revision + 1,
        updated_at: now
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast_owner(participant_id, "reflection:excerpt_removed", %{
            reflection_id: updated.reflection_id,
            revision: updated.revision
          })

          {:ok, updated}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Hard deletes a reflection.
  """
  def delete_reflection(reflection_id, participant_id, expected_revision \\ nil)
      when is_binary(reflection_id) and is_binary(participant_id) do
    with %Reflection{} = reflection <- get_reflection(reflection_id, participant_id),
         true <-
           is_nil(expected_revision) or reflection.revision == expected_revision ||
             {:error, :stale} do
      case Repo.delete(reflection) do
        {:ok, _deleted} ->
          broadcast_owner(participant_id, "reflection:deleted", %{
            reflection_id: reflection_id
          })

          {:ok, :deleted}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Undoes a newly-created reflection within the 10-second server time window.
  """
  def undo_create(reflection_id, participant_id)
      when is_binary(reflection_id) and is_binary(participant_id) do
    case get_reflection(reflection_id, participant_id) do
      nil ->
        {:error, :not_found}

      %Reflection{} = reflection ->
        diff = DateTime.diff(DateTime.utc_now(), reflection.saved_at, :second)

        if diff <= @undo_window_seconds do
          case Repo.delete(reflection) do
            {:ok, _deleted} ->
              broadcast_owner(participant_id, "reflection:deleted", %{
                reflection_id: reflection_id
              })

              {:ok, :undone}

            error ->
              error
          end
        else
          {:error, :undo_window_expired}
        end
    end
  end

  def undo_reflection(reflection_id, participant_id),
    do: undo_create(reflection_id, participant_id)

  def remove_reflection_excerpt(reflection_id, participant_id, expected_revision),
    do: remove_excerpt(reflection_id, participant_id, expected_revision)

  @doc """
  Opens a new composer grant and returns the record plus raw secret.
  """
  def open_composer_grant(participant_id, attrs)
      when is_binary(participant_id) and is_map(attrs) do
    raw_secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    secret_verifier = :crypto.hash(:sha256, raw_secret)
    now = DateTime.utc_now()

    source_conv_id =
      case attrs[:source_conversation_id] || attrs["source_conversation_id"] do
        nil -> nil
        cid -> parse_uuid_or_nil(cid)
      end

    source_msg_id =
      attrs[:source_client_message_id] || attrs["source_client_message_id"]

    source_epoch_id =
      case attrs[:source_epoch_id] || attrs["source_epoch_id"] do
        nil -> nil
        eid -> parse_uuid_or_nil(eid)
      end

    grant_params = %{
      secret_verifier: secret_verifier,
      opened_at: now,
      source_conversation_id: source_conv_id,
      source_client_message_id: source_msg_id,
      source_epoch_id: source_epoch_id,
      selection_start_grapheme:
        attrs[:selection_start_grapheme] || attrs["selection_start_grapheme"],
      selection_end_grapheme: attrs[:selection_end_grapheme] || attrs["selection_end_grapheme"],
      expected_source_revision:
        attrs[:expected_source_revision] || attrs["expected_source_revision"],
      state: "OPEN",
      created_at: now,
      updated_at: now
    }

    %ComposerGrant{}
    |> ComposerGrant.changeset(grant_params)
    |> Ecto.Changeset.put_change(:owner_participant_id, participant_id)
    |> Repo.insert()
    |> case do
      {:ok, grant} ->
        {:ok, %{grant: grant, raw_secret: raw_secret}}

      error ->
        error
    end
  end

  @doc """
  Gets a composer grant.
  """
  def get_grant(grant_id, participant_id)
      when is_binary(grant_id) and is_binary(participant_id) do
    Repo.get_by(ComposerGrant, grant_id: grant_id, owner_participant_id: participant_id)
  end

  @doc """
  Consumes a post-terminal grant to create a Reflection.
  Validates secret, expiry, and exact HMAC on candidate excerpt if applicable.
  """
  def consume_post_terminal_grant(
        grant_id,
        participant_id,
        raw_secret,
        create_operation_id,
        note_text,
        candidate_excerpt
      )
      when is_binary(grant_id) and is_binary(participant_id) and is_binary(raw_secret) do
    with %ComposerGrant{} = grant <- get_grant(grant_id, participant_id),
         true <- grant.state == "OPEN" || {:error, :grant_consumed},
         true <-
           :crypto.hash(:sha256, raw_secret) == grant.secret_verifier ||
             {:error, :invalid_grant_secret},
         true <-
           (not is_nil(grant.terminal_expires_at) and
              DateTime.compare(DateTime.utc_now(), grant.terminal_expires_at) in [:lt, :eq]) ||
             {:error, :grant_expired},
         {:ok, validated_excerpt} <-
           verify_terminal_excerpt(grant, candidate_excerpt) do
      Repo.transaction(fn ->
        grant
        |> ComposerGrant.changeset(%{state: "CONSUMED", updated_at: DateTime.utc_now()})
        |> Repo.update!()

        attrs = %{
          create_operation_id: create_operation_id,
          own_reflection_text: note_text,
          source_excerpt: validated_excerpt,
          source_conversation_id: nil,
          source_client_message_id: nil,
          source_epoch_id: nil
        }

        case create_reflection(participant_id, attrs) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      nil -> {:error, :grant_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_terminal_excerpt(grant, candidate_excerpt) do
    if is_nil(grant.terminal_excerpt_hmac) do
      {:ok, nil}
    else
      if is_nil(candidate_excerpt) or not is_binary(candidate_excerpt) do
        {:error, :source_mismatch}
      else
        expected_hmac = :crypto.mac(:hmac, :sha256, grant.grant_id, candidate_excerpt)

        if expected_hmac == grant.terminal_excerpt_hmac do
          validate_source_excerpt(candidate_excerpt)
        else
          {:error, :source_mismatch}
        end
      end
    end
  end

  @doc """
  Withdraws all other-participant saved source excerpts for an unsent message in a conversation.
  Also invalidates matching open composer grants.
  Returns {:ok, list_of_affected_reflections}.
  """
  def withdraw_peer_excerpt(conversation_id, client_message_id, author_participant_id)
      when is_binary(conversation_id) and is_binary(client_message_id) and
             is_binary(author_participant_id) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      reflections_query =
        from(r in Reflection,
          where:
            r.source_conversation_id == ^conversation_id and
              r.source_client_message_id == ^client_message_id and
              r.owner_participant_id != ^author_participant_id
        )

      reflections = Repo.all(reflections_query)

      updated_reflections =
        Enum.map(reflections, fn r ->
          r
          |> Reflection.changeset(%{
            source_excerpt: nil,
            source_conversation_id: nil,
            source_client_message_id: nil,
            source_epoch_id: nil,
            revision: r.revision + 1,
            updated_at: now
          })
          |> Repo.update!()
        end)

      grants_query =
        from(g in ComposerGrant,
          where:
            g.source_conversation_id == ^conversation_id and
              g.source_client_message_id == ^client_message_id and
              g.owner_participant_id != ^author_participant_id and
              g.state == "OPEN"
        )

      Repo.update_all(grants_query, set: [state: "INVALIDATED", updated_at: now])

      # Broadcast invalidation to affected owners
      Enum.each(updated_reflections, fn r ->
        broadcast_owner(r.owner_participant_id, "reflection:excerpt_removed", %{
          reflection_id: r.reflection_id,
          revision: r.revision
        })
      end)

      updated_reflections
    end)
  end

  @doc """
  Finalizes conversation terminal state across all reflections and composer grants.
  Detaches source links on reflections and computes HMAC on valid open grants with 10-minute expiry.
  """
  def finalize_conversation_terminal(conversation_id, ended_at, source_resolver_fn)
      when is_binary(conversation_id) and is_function(source_resolver_fn, 1) do
    Repo.transaction(fn ->
      ended_at = ended_at || DateTime.utc_now()
      expires_at = DateTime.add(ended_at, @post_terminal_window_seconds, :second)

      # 1. Detach all reflections
      from(r in Reflection,
        where: r.source_conversation_id == ^conversation_id
      )
      |> Repo.update_all(
        set: [
          source_conversation_id: nil,
          source_client_message_id: nil,
          source_epoch_id: nil,
          updated_at: ended_at
        ]
      )

      # 2. Finalize all open grants
      open_grants =
        from(g in ComposerGrant,
          where: g.source_conversation_id == ^conversation_id and g.state == "OPEN"
        )
        |> Repo.all()

      Enum.each(open_grants, fn grant ->
        msg_result =
          if is_binary(grant.source_client_message_id) do
            source_resolver_fn.(grant.source_client_message_id)
          else
            nil
          end

        case msg_result do
          %{content: content, content_revision: rev} = msg
          when rev == grant.expected_source_revision and is_binary(content) and
                 (not is_map_key(msg, :availability) or msg.availability != :unsent) ->
            slice =
              if is_integer(grant.selection_start_grapheme) and
                   is_integer(grant.selection_end_grapheme) and
                   grant.selection_end_grapheme > grant.selection_start_grapheme do
                len = grant.selection_end_grapheme - grant.selection_start_grapheme
                String.slice(content, grant.selection_start_grapheme, len)
              else
                content
              end

            hmac = :crypto.mac(:hmac, :sha256, grant.grant_id, slice)

            grant
            |> ComposerGrant.changeset(%{
              terminal_excerpt_hmac: hmac,
              terminal_expires_at: expires_at,
              source_conversation_id: nil,
              source_client_message_id: nil,
              source_epoch_id: nil,
              updated_at: ended_at
            })
            |> Repo.update!()

          _ineligible_or_changed ->
            grant
            |> ComposerGrant.changeset(%{
              terminal_excerpt_hmac: nil,
              terminal_expires_at: expires_at,
              source_conversation_id: nil,
              source_client_message_id: nil,
              source_epoch_id: nil,
              updated_at: ended_at
            })
            |> Repo.update!()
        end
      end)

      :ok
    end)
  end

  # --- Helpers ---

  defp broadcast_owner(participant_id, event, payload) do
    Endpoint.broadcast("participant:#{participant_id}", event, payload)
  end

  defp parse_uuid(nil), do: {:error, :invalid_operation_id}

  defp parse_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, valid} -> {:ok, valid}
      _ -> {:error, :invalid_operation_id}
    end
  end

  defp parse_uuid(_), do: {:error, :invalid_operation_id}

  defp parse_uuid_or_nil(nil), do: nil

  defp parse_uuid_or_nil(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, valid} -> valid
      _ -> nil
    end
  end

  defp parse_uuid_or_nil(_), do: nil
end
