# filepath: lib/strangertalks_new/conversation_lifecycle/memories.ex
defmodule StrangertalksNew.ConversationLifecycle.Memories do
  @moduledoc """
  Exposes exactly the three mandatory public context functions defined in Section 6
  of the Engineering Constitution for managing memory persistence records.
  """
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Memory

  @spec create_memory(map()) :: {:ok, Memory.t()} | {:error, Ecto.Changeset.t()}
  def create_memory(attrs \\ %{}) do
    %Memory{}
    |> Memory.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_memory(binary()) :: Memory.t() | nil
  def get_memory(memory_id) do
    # Soft delete filtering constraint: Exclude records that have been marked deleted
    from(m in Memory, where: m.memory_id == ^memory_id and is_nil(m.deleted_at))
    |> Repo.one()
  end

  @spec change_memory(Memory.t(), map()) :: Ecto.Changeset.t()
  def change_memory(%Memory{} = memory, attrs \\ %{}) do
    Memory.changeset(memory, attrs)
  end
end
