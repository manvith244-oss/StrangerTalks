defmodule StrangertalksNew.AgentSystemsFakeProvider do
  @moduledoc false

  @behaviour StrangertalksNew.AgentSystems.Provider

  @scripts_key {__MODULE__, :scripts}
  @requests_key {__MODULE__, :requests}

  def script(agent_id, {:ok, output} = result) when is_binary(agent_id) and is_map(output) do
    put_script(agent_id, result)
  end

  def script(agent_id, {:error, reason} = result) when is_binary(agent_id) and is_atom(reason) do
    put_script(agent_id, result)
  end

  def reset do
    Process.delete(@scripts_key)
    Process.delete(@requests_key)
    :ok
  end

  def requests do
    @requests_key
    |> Process.get([])
    |> Enum.reverse()
  end

  @impl true
  def structured(agent_id, payload, instructions, schema, opts) do
    record_request(agent_id, payload, instructions, schema, opts)

    case Map.fetch(Process.get(@scripts_key, %{}), agent_id) do
      {:ok, result} ->
        result

      :error ->
        raise ArgumentError, "no AgentSystems fake-provider response scripted for #{inspect(agent_id)}"
    end
  end

  defp put_script(agent_id, result) do
    scripts = Process.get(@scripts_key, %{})
    Process.put(@scripts_key, Map.put(scripts, agent_id, result))
    :ok
  end

  defp record_request(agent_id, payload, instructions, schema, opts) do
    request = %{
      agent_id: agent_id,
      payload: payload,
      instructions: instructions,
      schema: schema,
      opts: opts
    }

    Process.put(@requests_key, [request | Process.get(@requests_key, [])])
    :ok
  end
end
