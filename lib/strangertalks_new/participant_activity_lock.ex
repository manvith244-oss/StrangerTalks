defmodule StrangertalksNew.ParticipantActivityLock do
  @moduledoc """
  Single-node V1 serialization boundary for participant activity changes.

  Callers must supply internal participant UUIDs. Locks are acquired in stable
  UUID order so operations involving the same participants cannot deadlock.
  `:global.trans/3` releases each lock when the callback returns, raises, exits,
  or its process terminates. Multi-node coordination remains future work.
  """

  @spec with_participants([Ecto.UUID.t()], (-> result)) :: result when result: term()
  def with_participants(participant_ids, function)
      when is_list(participant_ids) and is_function(function, 0) do
    participant_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn participant_id ->
      unless match?({:ok, _}, Ecto.UUID.cast(participant_id)) do
        raise ArgumentError, "participant activity locks require UUIDs"
      end
    end)
    |> then(fn _ -> acquire(participant_ids |> Enum.uniq() |> Enum.sort(), function) end)
  end

  defp acquire([], function), do: function.()

  defp acquire([participant_id | rest], function) do
    :global.trans(
      {{__MODULE__, participant_id}, self()},
      fn -> acquire(rest, function) end,
      [node()]
    )
  end
end
