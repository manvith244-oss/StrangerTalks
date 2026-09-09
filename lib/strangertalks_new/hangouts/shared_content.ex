defmodule StrangertalksNew.Hangouts.SharedContent do
  @moduledoc """
  Durable shared-stimulus authority for a Hangout room.

  The curated catalog is deterministic; the room row owns the current content id,
  content sequence, and started-at timestamp. Runtime processes may reconstruct
  this state but do not own it.
  """

  import Ecto.Query

  alias StrangertalksNew.Hangouts.{ContentCatalog, HangoutRoom}
  alias StrangertalksNew.Repo

  def ensure_initial(room_id) when is_binary(room_id) do
    Repo.transaction(fn ->
      case lock_room(room_id) do
        nil ->
          Repo.rollback(:room_not_found)

        %HangoutRoom{status: status} when status in [:ENDING, :ENDED] ->
          Repo.rollback(:terminal_room)

        %HangoutRoom{experiment_arm: :GROUP_NO_CONTENT} ->
          nil

        %HangoutRoom{status: :FORMING} ->
          nil

        %HangoutRoom{status: :ACTIVE} = room ->
          cond do
            current_content_present?(room) -> content_state!(room)
            room.content_sequence == 0 -> advance_locked(room)
            true -> nil
          end
      end
    end)
    |> normalize_transaction()
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
          {:ok, content_state!(room)}
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

  defp advance_with_guard(room_id, expected_sequence) do
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
    |> normalize_transaction()
  end

  defp advance_locked(room) do
    next_sequence = room.content_sequence + 1
    item = item_for_sequence!(room.language_tag, next_sequence)
    started_at = DateTime.utc_now()

    room =
      room
      |> HangoutRoom.changeset(%{
        current_content_id: item.id,
        content_sequence: next_sequence,
        current_content_started_at: started_at
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback({:invalid_room_content, changeset})
      end

    content_state!(room)
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

  defp content_state!(room) do
    case ContentCatalog.fetch(room.current_content_id) do
      {:ok, content} ->
        %{
          content: content,
          sequence: room.content_sequence,
          started_at: room.current_content_started_at
        }

      {:error, :unknown_content} ->
        raise "persisted Hangout content id is not present in the curated catalog"
    end
  end

  defp current_content_present?(room) do
    is_binary(room.current_content_id) and room.current_content_id != "" and
      room.content_sequence > 0 and match?(%DateTime{}, room.current_content_started_at)
  end

  defp lock_room(room_id) do
    Repo.one(from r in HangoutRoom, where: r.room_id == ^room_id, lock: "FOR UPDATE")
  end

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}
end
