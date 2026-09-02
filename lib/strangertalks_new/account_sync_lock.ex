defmodule StrangertalksNew.AccountSyncLock do
  @moduledoc "Single-node V1 serialization boundary for one account's Drive snapshot."

  def with_account(account_id, function) when is_function(function, 0) do
    unless match?({:ok, _}, Ecto.UUID.cast(account_id)),
      do: raise(ArgumentError, "account sync lock requires a UUID")

    :global.trans({{__MODULE__, account_id}, self()}, function, [node()])
  end
end
