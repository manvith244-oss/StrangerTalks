defmodule StrangertalksNew.AgentSystemsProviderProbeTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.AgentSystems.ProviderProbe

  defmodule FakeProvider do
    @behaviour StrangertalksNew.Companion.Provider

    @impl true
    def generate(context) do
      send(Application.fetch_env!(:strangertalks_new, :provider_probe_test_pid), {
        :probe_generate,
        context
      })

      case Application.get_env(:strangertalks_new, :provider_probe_test_result, :success) do
        :success ->
          {:ok,
           %{
             decision: :assist,
             model: "probe-model",
             reason: nil,
             suggestions: [%{"style" => "natural", "text" => "Hello there."}]
           }}

        :decline ->
          {:ok,
           %{
             decision: :decline,
             model: "probe-model",
             reason: "declined",
             suggestions: []
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  setup do
    previous_flag = System.get_env("AGENT_SYSTEMS_PROVIDER_PROBE")
    previous_config = Application.get_env(:strangertalks_new, :agent_provider_probe)
    previous_pid = Application.get_env(:strangertalks_new, :provider_probe_test_pid)
    previous_result = Application.get_env(:strangertalks_new, :provider_probe_test_result)

    Application.put_env(:strangertalks_new, :agent_provider_probe, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :provider_probe_test_pid, self())
    Application.put_env(:strangertalks_new, :provider_probe_test_result, :success)

    on_exit(fn ->
      restore_env("AGENT_SYSTEMS_PROVIDER_PROBE", previous_flag)
      restore_app_env(:agent_provider_probe, previous_config)
      restore_app_env(:provider_probe_test_pid, previous_pid)
      restore_app_env(:provider_probe_test_result, previous_result)
    end)

    :ok
  end

  test "probe is inert unless explicitly enabled" do
    System.delete_env("AGENT_SYSTEMS_PROVIDER_PROBE")

    assert ProviderProbe.enabled?() == false
    assert :ok = ProviderProbe.run()
    refute_receive {:probe_generate, _}, 20
  end

  test "enabled probe requires a successful assist result" do
    System.put_env("AGENT_SYSTEMS_PROVIDER_PROBE", "true")

    assert ProviderProbe.enabled?() == true
    assert :ok = ProviderProbe.run()

    assert_receive {:probe_generate, context}
    assert context.language == "en"
    assert context.mode == "respond"
    assert context.messages == []
    assert context.participant_id == "probe-self"
  end

  test "enabled probe rejects a decline instead of claiming provider readiness" do
    System.put_env("AGENT_SYSTEMS_PROVIDER_PROBE", "true")
    Application.put_env(:strangertalks_new, :provider_probe_test_result, :decline)

    assert {:error, :invalid_probe_output} = ProviderProbe.run()
  end

  test "enabled probe surfaces provider failure" do
    System.put_env("AGENT_SYSTEMS_PROVIDER_PROBE", "1")
    Application.put_env(:strangertalks_new, :provider_probe_test_result, {:error, :bad_credentials})

    assert {:error, :bad_credentials} = ProviderProbe.run()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_app_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
