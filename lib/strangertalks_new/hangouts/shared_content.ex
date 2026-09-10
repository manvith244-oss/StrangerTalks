defmodule StrangertalksNew.Hangouts.SharedContent do
  @moduledoc """
  Durable shared-stimulus authority for a Hangout room.

  Content selection remains deterministic, while catalogue truth and every room
  content sequence are persisted. Runtime processes may cache this state but do
  not own it.
  """

  import Ecto.Query

  alias StrangertalksNew.Hangouts.{
    ContentCatalog,
    HangoutContentItem,
    HangoutRoom,
    HangoutRoomContent,
    Observability
  }

  alias StrangertalksNew.Repo

  def ensure_initial(room_id) when is_binary(room_id) do
    result =
      Repo.transaction(fn ->
        case lock_room(room_id) do
          nil ->
            Repo.rollback(:room_not_found)

          %HangoutRoom{status: status} when status in [:ENDING, :ENDED] ->
            Repo.rollback(:terminal_room)

          %HangoutRoom{experiment_arm: :GROUP_NO_CONTENT} ->
            {:unchanged, nil}

          %HangoutRoom{status: :FORMING} ->
            {:unchanged, nil}

          %HangoutRoom{status: :ACTIVE} = room ->
            cond do
              current_content_present?(room) ->
                {:unchanged, room |> current_record_for_locked_room!() |> content_state()}

              room.content_sequence == 0 ->
                {:activated, advance_locked(room)}

              true ->
                {:unchanged, nil}
            end
        end
      end)

    case result do
      {:ok, {:activated, content_state}} ->
        emit_transition(room_id, content_state)
        {:ok, content_state}

      {:ok, {:unchanged, value}} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ensure_initial(_room_id), do: {:error, :invalid_room_request}

  def current(room_id) when is_binary(room_id) do
    case Repo.get(HangoutRoom, room_id) do
      nil ->
        {:error, :room_not_found}

      %HangoutRoom{experiment_arm: :GROUP_NO_CONTENT} ->
        {:ok, nil}

      %HangoutRoom{} = room ->
        if current_content_present?(room) do
          case current_record(room) do
            %HangoutRoomContent{} = record -> {:ok, content_state(record)}
            nil -> ensure_initial(room_id)
          end
        else
          {:ok, nil}
        end
    end
  end

  def current(_room_id), do: {:error, :invalid_room_request}

  def advance(room_id) when is_binary(room_id), do: advance_with_guard(room_id, :any)
  def advance(_room_id), do: {:error, :invalid_room_request}

  def advance(room_id, expected_sequence)
      when is_binary(room_id) and is_integer(expected_sequence) and expected_sequence >= 0 do
    advance_with_guard(room_id, expected_sequence)
  end

  def advance(_room_id, _expected_sequence), do: {:error, :invalid_room_request}

  @doc false
  def advance_locked(%HangoutRoom{} = room) do
    next_sequence = room.content_sequence + 1
    item = item_for_sequence!(room.language_tag, next_sequence)
    started_at = DateTime.utc_now()

    persist_content_item!(item)
    record = persist_room_content!(room, item, next_sequence, started_at)

    room
    |> HangoutRoom.changeset(%{
      current_content_id: item.id,
      content_sequence: next_sequence,
      current_content_started_at: started_at
    })
    |> Repo.update()
    |> case do
      {:ok, _updated} -> content_state(record)
      {:error, changeset} -> Repo.rollback({:invalid_room_content, changeset})
    end
  end

  @doc false
  def current_record_for_locked_room!(%HangoutRoom{} = room) do
    case current_record(room) do
      %HangoutRoomContent{} = record ->
        record

      nil ->
        case ContentCatalog.fetch(room.current_content_id) do
          {:ok, item} ->
            persist_content_item!(item)
            persist_room_content!(room, item, room.content_sequence, room.current_content_started_at)

          {:error, :unknown_content} ->
            Repo.rollback(:content_unavailable)
        end
    end
  end

  @doc false
  def emit_transition(room_id, content_state) when is_binary(room_id) and is_map(content_state) do
    event = if content_state.sequence == 1, do: :content_activated, else: :content_advanced

    Observability.emit_room(room_id, event, %{
      count: 1,
      content_sequence: content_state.sequence
    })
  end

  defp advance_with_guard(room_id, expected_sequence) do
    result =
      Repo.transaction(fn ->
        case lock_room(room_id) do
          nil ->
            Repo.rollback(:room_not_found)

          %HangoutRoom{status: status} when status in [:ENDING, :ENDED] ->
            Repo.rollback(:terminal_room)

          %HangoutRoom{experiment_arm: :GROUP_NO_CONTENT} ->
            Repo.rollback(:content_disabled)

          %HangoutRoom{status: status} when status != :ACTIVE ->
            Repo.rollback(:room_not_active)

          %HangoutRoom{} = room ->
            if expected_sequence == :any or expected_sequence == room.content_sequence do
              advance_locked(room)
            else
              Repo.rollback(:stale_content)
            end
        end
      end)

    case result do
      {:ok, content_state} ->
        emit_transition(room_id, content_state)
        {:ok, content_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_content_item!(item) do
    now = DateTime.utc_now()

    attrs = %{
      content_id: item.id,
      kind: enum_text(item.kind),
      language_tag: item.language_tag,
      source: enum_text(item.source),
      safety_status: enum_text(item.safety_status),
      publication_status: enum_text(item.publication_status),
      body: item.body,
      options: Map.get(item, :options, []),
      created_at: now,
      updated_at: now
    }

    %HangoutContentItem{}
    |> HangoutContentItem.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :kind,
           :language_tag,
           :source,
           :safety_status,
           :publication_status,
           :body,
           :options,
           :updated_at
         ]},
      conflict_target: :content_id
    )
    |> case do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback({:invalid_content_item, changeset})
    end
  end

  defp persist_room_content!(room, item, sequence, started_at) do
    attrs = %{
      room_id: room.room_id,
      content_id: item.id,
      sequence: sequence,
      started_at: started_at,
      kind: enum_text(item.kind),
      language_tag: item.language_tag,
      source: enum_text(item.source),
      safety_status: enum_text(item.safety_status),
      publication_status: enum_text(item.publication_status),
      body: item.body,
      options: Map.get(item, :options, []),
      created_at: DateTime.utc_now()
    }

    %HangoutRoomContent{}
    |> HangoutRoomContent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback({:invalid_room_content_history, changeset})
    end
  end

  defp current_record(room) do
    Repo.one(
      from rc in HangoutRoomContent,
        where: rc.room_id == ^room.room_id and rc.sequence == ^room.content_sequence
    )
  end

  defp item_for_sequence!(language_tag, sequence) do
    items =
      language_tag
      |> ContentCatalog.items()
      |> Enum.filter(fn item ->
        item.source == :FIRST_PARTY and item.safety_status == :APPROVED and
          item.publication_status == :ACTIVE
      end)

    case items do
      [] -> Repo.rollback(:content_unavailable)
      items -> Enum.at(items, rem(sequence - 1, length(items)))
    end
  end

  defp content_state(record) do
    %{
      content: %{
        id: record.content_id,
        kind: known_atom(record.kind),
        language_tag: record.language_tag,
        source: known_atom(record.source),
        safety_status: known_atom(record.safety_status),
        publication_status: known_atom(record.publication_status),
        body: record.body,
        options: record.options
      },
      sequence: record.sequence,
      started_at: record.started_at
    }
  end

  defp enum_text(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_text(value) when is_binary(value), do: value

  defp known_atom("QUESTION"), do: :QUESTION
  defp known_atom("POLL"), do: :POLL
  defp known_atom("FIRST_PARTY"), do: :FIRST_PARTY
  defp known_atom("APPROVED"), do: :APPROVED
  defp known_atom("ACTIVE"), do: :ACTIVE
  defp known_atom(value), do: value

  defp current_content_present?(room) do
    is_binary(room.current_content_id) and room.current_content_id != "" and
      room.content_sequence > 0 and match?(%DateTime{}, room.current_content_started_at)
  end

  defp lock_room(room_id) do
    Repo.one(from r in HangoutRoom, where: r.room_id == ^room_id, lock: "FOR UPDATE")
  end
end
