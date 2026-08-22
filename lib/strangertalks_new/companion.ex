defmodule StrangertalksNew.Companion do
  @moduledoc """
  A01 Conversation Companion orchestration boundary.

  The model can reason only over an explicitly captured, bounded Conversation context. It has no
  send, queue, relationship, block, or configuration mutation capability. Authoritative
  Conversation/safety state is checked before generation and again before any result is returned.

  At most one Companion generation may be in flight for the same participant and Conversation on
  the V1 node. The lock is process-owned through the existing unique Registry and disappears if
  the HTTP/request process exits.
  """

  alias StrangertalksNew.Companion.{Context, OpenAIProvider, Output}

  @registry StrangertalksNew.DistributedRegistry

  def request(conversation_id, participant_id, attrs) when is_map(attrs) do
    started_at = System.monotonic_time()
    lock_key = {:companion_request, conversation_id, participant_id}

    result =
      case Registry.register(@registry, lock_key, nil) do
        {:ok, _value} ->
          try do
            run_request(conversation_id, participant_id, attrs)
          after
            Registry.unregister(@registry, lock_key)
          end

        {:error, {:already_registered, _pid}} ->
          {:error, :companion_busy}
      end

    emit_telemetry(started_at, attrs, result)
    result
  end

  def request(_conversation_id, _participant_id, _attrs), do: {:error, :invalid_payload}

  defp run_request(conversation_id, participant_id, attrs) do
    with {:ok, context} <- Context.capture(conversation_id, participant_id, attrs),
         provider <- provider(),
         {:ok, raw_result} <- provider.generate(context),
         {:ok, output} <- Output.validate(raw_result),
         :ok <- Context.revalidate(context) do
      {:ok,
       %{
         request_id: context.request_id,
         status: if(output.decision == :assist, do: "ready", else: "declined"),
         conversation_id: context.conversation_id,
         language: context.language,
         mode: context.mode,
         tone: context.tone,
         draft_fingerprint: context.draft_fingerprint,
         suggestions: output.suggestions,
         reason: output.reason
       }}
    end
  end

  defp provider do
    :strangertalks_new
    |> Application.get_env(:companion, [])
    |> Keyword.get(:provider, OpenAIProvider)
  end

  defp emit_telemetry(started_at, attrs, result) do
    duration = System.monotonic_time() - started_at

    metadata = %{
      mode: safe_metadata(attrs, "mode"),
      result: if(match?({:ok, _}, result), do: :success, else: :failure)
    }

    :telemetry.execute(
      [:strangertalks_new, :companion, :request],
      %{duration: duration},
      metadata
    )
  end

  defp safe_metadata(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key)) do
      value when is_binary(value) -> String.slice(value, 0, 40)
      _ -> "unknown"
    end
  end
end
