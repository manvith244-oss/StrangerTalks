defmodule StrangertalksNew.AgentSystems.ProviderProbe do
  @moduledoc """
  Opt-in production smoke probe for the bounded Agent provider path.

  The probe is disabled by default. When `AGENT_SYSTEMS_PROVIDER_PROBE=true`, application boot
  performs one synthetic A01 request through generation, critic and moderation before the release
  is considered healthy. No participant, Conversation, database record or user content is read.
  """

  require Logger

  alias StrangertalksNew.Companion.OpenAIProvider

  def run do
    if enabled?() do
      case provider().generate(probe_context()) do
        {:ok, %{decision: :assist, model: model, suggestions: suggestions}}
        when is_binary(model) and is_list(suggestions) and suggestions != [] ->
          Logger.info("Agent provider production probe passed",
            operation: :agent_provider_probe,
            model: model
          )

          :ok

        {:ok, _unexpected} ->
          {:error, :invalid_probe_output}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  def enabled?, do: System.get_env("AGENT_SYSTEMS_PROVIDER_PROBE", "false") in ~w(true 1 yes)

  defp provider do
    :strangertalks_new
    |> Application.get_env(:agent_provider_probe, [])
    |> Keyword.get(:provider, OpenAIProvider)
  end

  defp probe_context do
    %{
      conversation_id: "production-provider-probe",
      participant_id: "probe-self",
      peer_id: "probe-stranger",
      language: "en",
      door: "JUST_TALK",
      mode: "respond",
      tone: "natural",
      request: "Give me one short, friendly greeting I could say to a stranger.",
      draft: nil,
      messages: [],
      conversation_start: nil
    }
  end
end
