defmodule StrangertalksNew.AgentSystems.Provider do
  @moduledoc """
  Shared model-provider contract for bounded StrangerTalks agents.

  Providers receive an already-minimized payload and return schema-constrained data. They receive
  no database handle, runtime process, queue authority, safety mutation authority, or send tool.
  """

  @callback structured(
              agent_id :: String.t(),
              payload :: map(),
              instructions :: String.t(),
              schema :: map(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, atom()}
end
