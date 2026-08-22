defmodule StrangertalksNew.AgentSystems.ProviderProbe do
  @moduledoc """
  Opt-in production smoke probe for the bounded Agent provider path.

  The probe is disabled by default. When `AGENT_SYSTEMS_PROVIDER_PROBE=true`, application boot
  performs one synthetic A01 request through generation, critic and moderation before the release
  is considered healthy. No participant, Conversation, database record or user content is read.

  Startup diagnostics include only boolean provider-readiness state and the non-secret model name.
  Secret values are never logged or printed.
  """

  require Logger

  alias StrangertalksNew.Companion.OpenAIProvider

  def run do
    status = configuration_status()

    readiness_line =
      "[agent-provider] config companion_enabled=#{status.companion_enabled} " <>
        "agent_systems_enabled=#{status.agent_systems_enabled} " <>
        "probe_enabled=#{status.probe_enabled} " <>
        "openai_key_present=#{status.openai_key_present}"

    IO.puts(readiness_line)

    Logger.info("Agent provider configuration state",
      operation: :agent_provider_configuration,
      companion_enabled: status.companion_enabled,
      agent_systems_enabled: status.agent_systems_enabled,
      probe_enabled: status.probe_enabled,
      openai_key_present: status.openai_key_present
    )

    if status.probe_enabled do
      case provider().generate(probe_context()) do
        {:ok, %{decision: :assist, model: model, suggestions: suggestions}}
        when is_binary(model) and is_list(suggestions) and suggestions != [] ->
          IO.puts("[agent-provider] production probe passed model=#{model}")

          Logger.info("Agent provider production probe passed",
            operation: :agent_provider_probe,
            model: model
          )

          :ok

        {:ok, _unexpected} ->
          IO.puts("[agent-provider] production probe failed reason=invalid_probe_output")
          {:error, :invalid_probe_output}

        {:error, reason} ->
          IO.puts("[agent-provider] production probe failed reason=#{reason}")
          {:error, reason}
      end
    else
      IO.puts("[agent-provider] production probe skipped")
      :ok
    end
  end

  def enabled?, do: configuration_status().probe_enabled

  def configuration_status do
    %{
      companion_enabled: env_truthy?("COMPANION_ENABLED"),
      agent_systems_enabled: env_truthy?("AGENT_SYSTEMS_ENABLED"),
      probe_enabled: env_truthy?("AGENT_SYSTEMS_PROVIDER_PROBE"),
      openai_key_present: present?(System.get_env("OPENAI_API_KEY"))
    }
  end

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

  defp env_truthy?(name), do: System.get_env(name, "false") in ~w(true 1 yes)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
