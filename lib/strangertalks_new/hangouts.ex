defmodule StrangertalksNew.Hangouts do
  import Ecto.Query

  alias StrangertalksNew.Hangouts.{
    HangoutMembership,
    HangoutMessage,
    HangoutRoom,
    TemporaryIdentity
  }

  alias StrangertalksNew.Repo

  @room_intent_fields [
    :language_tag,
    :experiment_arm,
    :minimum_size,
    :target_size,
    :max_size
  ]

  @message_intent_fields [:client_message_id, :body]
  @current_membership_statuses [:ACTIVE, :DISCONNECTED]

  def create_room(attrs \\ %{})

  def create_room(attrs) when is_map(attrs) do
    canonical_attrs =
      %{
        created_at: now(),
        status: :FORMING,
        language_tag: "en",
        experiment_arm: :GROUP_WITH_CONTENT,
        minimum_size: 3,
        target_size: 4,
        max_size: 6,
        message_sequence: 0,
        content_sequence: 0
      }
      |> Map.merge(intent_attrs(attrs, @room_intent_fields))

    Repo.transaction(fn ->
      %HangoutRoom{}
      |> HangoutRoom.changeset(canonical_attrs)
      |> Repo.insert()
      |> case do
        {:ok, room} -> room
        {:error, changeset} -> Repo.rollback({:invalid_room, changeset})
      end
    end)
    |> normalize_transaction()
  end

  def create_room(_attrs), do: {:error, :invalid_room_input}

  def add_member(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    Repo.transaction(fn ->
      room = lock_room(room_id)

      cond do
        is_nil(room) ->
          Repo.rollback(:room_not_found)

        room.status not in [:FORMING, :ACTIVE] ->
          Repo.rollback(:room_unavailable)

        true ->
          add_or_restore_member(room, participant_id)
      end
    end)
    |> normalize_transaction()
  end

  def add_member(_room_id, _participant_id), do: {:error, :invalid_membership_request}

  def leave_room(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    Repo.transaction(fn ->
      room = lock_room(room_id)

      if is_nil(room) do
        Repo.rollback(:room_not_found)
      end

      case lock_membership(room_id, participant_id) do
        nil ->
          Repo.rollback(:membership_not_found)

        %HangoutMembership{status: :LEFT} = membership ->
          membership

        %HangoutMembership{status: :REMOVED} ->
          Repo.rollback(:membership_removed)

        %HangoutMembership{} = membership ->
          update_membership!(membership, %{
            status: :LEFT,
            left_at: now(),
            last_seen_at: now()
          })
      end
    end)
    |> normalize_transaction()
  end

  def leave_room(_room_id, _participant_id), do: {:error, :invalid_membership_request}

  def activate_if_ready(room_id) when is_binary(room_id) do
    Repo.transaction(fn ->
      case lock_room(room_id) do
        nil ->
          Repo.rollback(:room_not_found)

        %HangoutRoom{status: status} when status in [:ENDING, :ENDED] ->
          Repo.rollback(:terminal_room)

        %HangoutRoom{status: :ACTIVE} = room ->
          room

        %HangoutRoom{status: :FORMING} = room ->
          active_count =
            Repo.aggregate(
              from(m in HangoutMembership,
                where: m.room_id == ^room_id and m.status == :ACTIVE
              ),
              :count,
              :membership_id
            )

          if active_count >= room.minimum_size do
            update_room!(room, %{status: :ACTIVE, activated_at: room.activated_at || now()})
          else
            room
          end
      end
    end)
    |> normalize_transaction()
  end

  def activate_if_ready(_room_id), do: {:error, :invalid_room_request}

  def disconnect_member(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    Repo.transaction(fn ->
      room = lock_room(room_id)

      cond do
        is_nil(room) ->
          Repo.rollback(:room_not_found)

        room.status in [:ENDING, :ENDED] ->
          Repo.rollback(:terminal_room)

        true ->
          case lock_membership(room_id, participant_id) do
            nil ->
              Repo.rollback(:membership_not_found)

            %HangoutMembership{status: :ACTIVE} = membership ->
              update_membership!(membership, %{
                status: :DISCONNECTED,
                last_seen_at: now(),
                left_at: nil,
                disconnect_count: membership.disconnect_count + 1
              })

            %HangoutMembership{status: :DISCONNECTED} = membership ->
              membership

            %HangoutMembership{} ->
              Repo.rollback(:membership_not_active)
          end
      end
    end)
    |> normalize_transaction()
  end

  def disconnect_member(_room_id, _participant_id),
    do: {:error, :invalid_membership_request}

  def reconnect_member(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    Repo.transaction(fn ->
      room = lock_room(room_id)

      cond do
        is_nil(room) ->
          Repo.rollback(:room_not_found)

        room.status in [:ENDING, :ENDED] ->
          Repo.rollback(:terminal_room)

        true ->
          case lock_membership(room_id, participant_id) do
            nil ->
              Repo.rollback(:membership_not_found)

            %HangoutMembership{status: :ACTIVE} = membership ->
              membership

            %HangoutMembership{status: :DISCONNECTED} = membership ->
              update_membership!(membership, %{
                status: :ACTIVE,
                last_seen_at: now(),
                left_at: nil
              })

            %HangoutMembership{} ->
              Repo.rollback(:membership_not_active)
          end
      end
    end)
    |> normalize_transaction()
  end

  def reconnect_member(_room_id, _participant_id),
    do: {:error, :invalid_membership_request}

  def end_room(room_id) when is_binary(room_id) do
    Repo.transaction(fn ->
      case lock_room(room_id) do
        nil ->
          Repo.rollback(:room_not_found)

        %HangoutRoom{status: :ENDED} = room ->
          room

        %HangoutRoom{} = room ->
          update_room!(room, %{status: :ENDED, ended_at: room.ended_at || now()})
      end
    end)
    |> normalize_transaction()
  end

  def end_room(_room_id), do: {:error, :invalid_room_request}

  def internal_room_snapshot(room_id) when is_binary(room_id) do
    case Repo.get(HangoutRoom, room_id) do
      nil ->
        {:error, :room_not_found}

      room ->
        members =
          Repo.all(
            from m in HangoutMembership,
              where:
                m.room_id == ^room_id and
                  m.status in ^@current_membership_statuses,
              order_by: [asc: m.joined_at, asc: m.temporary_identity_slot]
          )

        {:ok, snapshot(room, members)}
    end
  end

  def internal_room_snapshot(_room_id), do: {:error, :invalid_room_request}

  def room_snapshot(room_id, participant_id)
      when is_binary(room_id) and is_binary(participant_id) do
    with {:ok, internal} <- internal_room_snapshot(room_id),
         %HangoutMembership{} <-
           Enum.find(internal.members, &(&1.participant_id == participant_id)) do
      public_members =
        Enum.map(internal.members, fn member ->
          %{
            identity: %{
              slot: member.temporary_identity_slot,
              label: member.temporary_identity_label,
              emoji: member.temporary_identity_emoji
            },
            self: member.participant_id == participant_id,
            status: member.status
          }
        end)

      {:ok, %{internal | members: public_members}}
    else
      nil -> {:error, :membership_not_active}
      {:error, _reason} = error -> error
    end
  end

  def room_snapshot(_room_id, _participant_id), do: {:error, :invalid_snapshot_request}

  def append_message(room_id, participant_id, attrs)
      when is_binary(room_id) and is_binary(participant_id) and is_map(attrs) do
    message_attrs = intent_attrs(attrs, @message_intent_fields)

    Repo.transaction(fn ->
      room = lock_room(room_id)

      cond do
        is_nil(room) ->
          Repo.rollback(:room_not_found)

        room.status != :ACTIVE ->
          Repo.rollback(:room_not_active)

        true ->
          membership = lock_membership(room_id, participant_id)
          append_for_membership(room, membership, message_attrs)
      end
    end)
    |> normalize_transaction()
  end

  def append_message(_room_id, _participant_id, _attrs), do: {:error, :invalid_message_request}

  defp add_or_restore_member(room, participant_id) do
    case lock_membership(room.room_id, participant_id) do
      %HangoutMembership{status: :ACTIVE} = membership ->
        membership

      %HangoutMembership{status: :DISCONNECTED} = membership ->
        update_membership!(membership, %{status: :ACTIVE, last_seen_at: now(), left_at: nil})

      %HangoutMembership{} ->
        Repo.rollback(:membership_terminal)

      nil ->
        insert_member(room, participant_id)
    end
  end

  defp insert_member(room, participant_id) do
    active_count =
      Repo.aggregate(
        from(m in HangoutMembership,
          where:
            m.room_id == ^room.room_id and
              m.status in ^@current_membership_statuses
        ),
        :count,
        :membership_id
      )

    if active_count >= room.max_size do
      Repo.rollback(:room_full)
    end

    occupied_slots =
      Repo.all(
        from m in HangoutMembership,
          where: m.room_id == ^room.room_id,
          select: m.temporary_identity_slot
      )

    identity =
      case TemporaryIdentity.slot_for(room.room_id, participant_id, occupied_slots) do
        {:ok, identity} -> identity
        {:error, reason} -> Repo.rollback(reason)
      end

    timestamp = now()

    changeset =
      HangoutMembership.changeset(
        %HangoutMembership{},
        %{
          status: :ACTIVE,
          temporary_identity_slot: identity.slot,
          temporary_identity_label: identity.label,
          temporary_identity_emoji: identity.emoji,
          joined_at: timestamp,
          last_seen_at: timestamp,
          disconnect_count: 0
        },
        room.room_id,
        participant_id
      )

    case Repo.insert(changeset) do
      {:ok, membership} ->
        membership

      {:error, changeset} ->
        if constraint_error?(
             changeset,
             "hangout_memberships_one_active_room_per_participant_index"
           ) do
          Repo.rollback(:already_in_hangout)
        else
          Repo.rollback({:invalid_membership, changeset})
        end
    end
  end

  defp append_for_membership(_room, nil, _attrs), do: Repo.rollback(:membership_not_found)

  defp append_for_membership(_room, %HangoutMembership{status: status}, _attrs)
       when status != :ACTIVE,
       do: Repo.rollback(:membership_not_active)

  defp append_for_membership(room, membership, attrs) do
    client_message_id = Map.get(attrs, :client_message_id)
    body = Map.get(attrs, :body)

    case existing_message(membership.membership_id, client_message_id) do
      %HangoutMessage{body: ^body} = message ->
        message

      %HangoutMessage{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        insert_message(room, membership, attrs)
    end
  end

  defp insert_message(room, membership, attrs) do
    next_sequence = room.message_sequence + 1

    room
    |> HangoutRoom.changeset(%{message_sequence: next_sequence})
    |> Repo.update()
    |> case do
      {:ok, _room} -> :ok
      {:error, changeset} -> Repo.rollback({:invalid_room_sequence, changeset})
    end

    message_attrs = Map.put(attrs, :created_at, now())

    %HangoutMessage{}
    |> HangoutMessage.changeset(
      message_attrs,
      room.room_id,
      membership.membership_id,
      next_sequence
    )
    |> Repo.insert()
    |> case do
      {:ok, message} -> message
      {:error, changeset} -> Repo.rollback({:invalid_message, changeset})
    end
  end

  defp existing_message(_membership_id, client_message_id)
       when not is_binary(client_message_id) or client_message_id == "",
       do: nil

  defp existing_message(membership_id, client_message_id) do
    Repo.one(
      from m in HangoutMessage,
        where:
          m.membership_id == ^membership_id and
            m.client_message_id == ^client_message_id
    )
  end

  defp update_membership!(membership, attrs) do
    membership
    |> HangoutMembership.changeset(attrs, membership.room_id, membership.participant_id)
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:invalid_membership, changeset})
    end
  end

  defp update_room!(room, attrs) do
    room
    |> HangoutRoom.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:invalid_room, changeset})
    end
  end

  defp lock_room(room_id) do
    Repo.one(from r in HangoutRoom, where: r.room_id == ^room_id, lock: "FOR UPDATE")
  end

  defp lock_membership(room_id, participant_id) do
    Repo.one(
      from m in HangoutMembership,
        where: m.room_id == ^room_id and m.participant_id == ^participant_id,
        lock: "FOR UPDATE"
    )
  end

  defp snapshot(room, members) do
    %{
      room_id: room.room_id,
      status: room.status,
      language_tag: room.language_tag,
      experiment_arm: room.experiment_arm,
      minimum_size: room.minimum_size,
      target_size: room.target_size,
      max_size: room.max_size,
      message_sequence: room.message_sequence,
      content_sequence: room.content_sequence,
      members: members
    }
  end

  defp intent_attrs(attrs, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      string_field = Atom.to_string(field)

      cond do
        Map.has_key?(attrs, field) -> Map.put(acc, field, Map.get(attrs, field))
        Map.has_key?(attrs, string_field) -> Map.put(acc, field, Map.get(attrs, string_field))
        true -> acc
      end
    end)
  end

  defp constraint_error?(changeset, name) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      to_string(Keyword.get(metadata, :constraint_name, "")) == name
    end)
  end

  defp normalize_transaction({:ok, value}), do: {:ok, value}

  defp normalize_transaction({:error, {:invalid_room, changeset}}),
    do: {:error, :invalid_room, changeset}

  defp normalize_transaction({:error, {:invalid_message, changeset}}),
    do: {:error, :invalid_message, changeset}

  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now()
end
