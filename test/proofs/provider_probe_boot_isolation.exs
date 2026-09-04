defmodule StrangertalksNew.ProviderProbeBootIsolationProof.FakeProvider do
  @behaviour StrangertalksNew.Companion.Provider

  @impl true
  def generate(context) do
    send(
      Application.fetch_env!(:strangertalks_new, :provider_probe_proof_pid),
      {:provider_probe_called, context}
    )

    case Application.fetch_env!(:strangertalks_new, :provider_probe_proof_result) do
      :success ->
        {:ok,
         %{
           decision: :assist,
           model: "proof-model",
           reason: nil,
           suggestions: [%{"style" => "natural", "text" => "Hello there."}]
         }}

      :malformed_success ->
        {:ok, "not-a-provider-result"}

      :semantic_invalid_success ->
        {:ok, %{decision: :assist, model: nil, reason: nil, suggestions: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule StrangertalksNew.ProviderProbeBootIsolationProof do
  alias StrangertalksNew.AgentSystems.ProviderProbe
  alias StrangertalksNew.ProviderProbeBootIsolationProof.FakeProvider

  @core_processes [
    StrangertalksNew.Supervisor,
    StrangertalksNew.ConversationDynamicSupervisor,
    StrangertalksNew.QueueEngine.QueueState,
    StrangertalksNew.QueueEngine.SafetyReceiver,
    StrangertalksNewWeb.Endpoint
  ]

  @provider_failures [
    {:connection_failure, :connection_failure},
    {:timeout, :timeout},
    {:http_401, {:http_status, 401}},
    {:http_403, {:http_status, 403}},
    {:http_429, {:http_status, 429}},
    {:http_500, {:http_status, 500}},
    {:http_502, {:http_status, 502}},
    {:http_503, {:http_status, 503}},
    {:http_504, {:http_status, 504}}
  ]

  def run do
    Application.put_env(:strangertalks_new, :agent_provider_probe, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :provider_probe_proof_pid, self())

    prove_disabled_control()
    prove_enabled_failure_isolated()
    prove_failure_matrix()
    prove_malformed_and_semantic_invalid()
    prove_provider_recovery_without_restart()
    prove_restart_during_provider_outage()

    IO.puts("T_A04_002_PROVIDER_PROBE_ISOLATION_PROOF=PASS")
  after
    stop_application()
    System.delete_env("AGENT_SYSTEMS_PROVIDER_PROBE")
    Application.delete_env(:strangertalks_new, :agent_provider_probe)
    Application.delete_env(:strangertalks_new, :provider_probe_proof_pid)
    Application.delete_env(:strangertalks_new, :provider_probe_proof_result)
  end

  defp prove_disabled_control do
    stop_application()
    System.put_env("AGENT_SYSTEMS_PROVIDER_PROBE", "false")

    Application.put_env(
      :strangertalks_new,
      :provider_probe_proof_result,
      {:error, :connection_failure}
    )

    start_result = Application.ensure_all_started(:strangertalks_new)
    IO.inspect(start_result, label: "PROBE_DISABLED_PROVIDER_UNAVAILABLE_BOOT_RESULT")
    assert_started!(start_result, :probe_disabled_provider_unavailable)
    assert_core_alive!(:probe_disabled_provider_unavailable)
    refute_probe_call!(:probe_disabled_provider_unavailable)
  end

  defp prove_enabled_failure_isolated do
    stop_application()
    System.put_env("AGENT_SYSTEMS_PROVIDER_PROBE", "true")

    Application.put_env(
      :strangertalks_new,
      :provider_probe_proof_result,
      {:error, :connection_failure}
    )

    start_result = Application.ensure_all_started(:strangertalks_new)
    IO.inspect(start_result, label: "PROBE_ENABLED_PROVIDER_FAILURE_BOOT_RESULT")

    case start_result do
      {:ok, _started} ->
        IO.puts("T_A04_002_BOOT_PHASE=POST_FIX_EXPECTED_GREEN")

      {:error,
       {:strangertalks_new,
        {{:agent_provider_probe_failed, reason},
         {StrangertalksNew.Application, :start, [:normal, []]}}}} ->
        raise_pre_fix_red!(reason, start_result)

      {:error, {:strangertalks_new, {:agent_provider_probe_failed, reason}}} ->
        raise_pre_fix_red!(reason, start_result)

      other ->
        raise "unexpected application-start failure during provider isolation proof: #{inspect(other)}"
    end

    assert_core_alive!(:probe_enabled_provider_failure)
    refute_probe_call!(:probe_enabled_provider_failure_boot)

    assert_equal!(
      {:error, :connection_failure},
      ProviderProbe.run(),
      :explicit_provider_verification_failure
    )

    assert_probe_call!(:explicit_provider_verification_failure)
    assert_core_alive!(:after_explicit_provider_verification_failure)
  end

  defp prove_failure_matrix do
    Enum.each(@provider_failures, fn {label, reason} ->
      Application.put_env(:strangertalks_new, :provider_probe_proof_result, {:error, reason})

      assert_equal!({:error, reason}, ProviderProbe.run(), label)
      assert_probe_call!(label)
      assert_core_alive!(label)

      IO.puts("FAILURE_MATRIX=#{label}:verification_failed_core_alive")
    end)
  end

  defp prove_malformed_and_semantic_invalid do
    Application.put_env(:strangertalks_new, :provider_probe_proof_result, :malformed_success)

    assert_equal!(
      {:error, :invalid_probe_output},
      ProviderProbe.run(),
      :malformed_provider_response
    )

    assert_probe_call!(:malformed_provider_response)
    assert_core_alive!(:malformed_provider_response)
    IO.puts("FAILURE_MATRIX=malformed_provider_response:verification_failed_core_alive")

    Application.put_env(
      :strangertalks_new,
      :provider_probe_proof_result,
      :semantic_invalid_success
    )

    assert_equal!(
      {:error, :invalid_probe_output},
      ProviderProbe.run(),
      :semantic_invalid_response
    )

    assert_probe_call!(:semantic_invalid_response)
    assert_core_alive!(:semantic_invalid_response)
    IO.puts("FAILURE_MATRIX=semantic_invalid_response:verification_failed_core_alive")
  end

  defp prove_provider_recovery_without_restart do
    supervisor_before = Process.whereis(StrangertalksNew.Supervisor)

    Application.put_env(:strangertalks_new, :provider_probe_proof_result, :success)
    assert_equal!(:ok, ProviderProbe.run(), :provider_recovery)
    assert_probe_call!(:provider_recovery)
    assert_core_alive!(:provider_recovery)

    supervisor_after = Process.whereis(StrangertalksNew.Supervisor)
    assert_equal!(supervisor_before, supervisor_after, :provider_recovery_did_not_restart_phoenix)

    IO.puts("FAILURE_MATRIX=provider_recovery:verification_succeeded_without_phoenix_restart")
  end

  defp prove_restart_during_provider_outage do
    Application.put_env(:strangertalks_new, :provider_probe_proof_result, {:error, :timeout})
    stop_application()

    start_result = Application.ensure_all_started(:strangertalks_new)
    IO.inspect(start_result, label: "PROVIDER_OUTAGE_RESTART_RESULT")
    assert_started!(start_result, :provider_outage_restart)
    assert_core_alive!(:provider_outage_restart)
    refute_probe_call!(:provider_outage_restart_boot)

    assert_equal!({:error, :timeout}, ProviderProbe.run(), :provider_outage_restart_verification)
    assert_probe_call!(:provider_outage_restart_verification)
    assert_core_alive!(:provider_outage_restart_after_verification)

    IO.puts("FAILURE_MATRIX=phoenix_restart_during_provider_outage:core_restarted")
  end

  defp raise_pre_fix_red!(reason, start_result) do
    IO.puts("T_A04_002_BOOT_PHASE=PRE_FIX_EXPECTED_RED")
    IO.inspect(reason, label: "RED_CAUSAL_PROVIDER_PROBE_FAILURE")
    IO.inspect(start_result, label: "RED_CAUSAL_APPLICATION_START_RESULT")

    raise "RED proof: enabled ProviderProbe failure still controls Application.start/2 and stops core Phoenix"
  end

  defp assert_started!({:ok, _apps}, _label), do: :ok

  defp assert_started!(other, label) do
    raise "#{label} expected application startup success, got #{inspect(other)}"
  end

  defp assert_core_alive!(label) do
    Enum.each(@core_processes, fn name ->
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          unless Process.alive?(pid) do
            raise "#{label} expected #{inspect(name)} to be alive"
          end

        nil ->
          raise "#{label} expected #{inspect(name)} to be registered and alive"
      end
    end)
  end

  defp assert_probe_call!(label) do
    receive do
      {:provider_probe_called, context} ->
        unless context.participant_id == "probe-self" and context.messages == [] do
          raise "#{label} received unexpected probe context #{inspect(context)}"
        end
    after
      1_000 ->
        raise "#{label} expected explicit ProviderProbe.run/0 to call the configured provider"
    end
  end

  defp refute_probe_call!(label) do
    receive do
      {:provider_probe_called, context} ->
        raise "#{label} unexpectedly called external provider during core application boot: #{inspect(context)}"
    after
      100 ->
        :ok
    end
  end

  defp assert_equal!(expected, actual, label) do
    unless expected == actual do
      raise "#{label} expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  defp stop_application do
    case Application.stop(:strangertalks_new) do
      :ok -> :ok
      {:error, {:not_started, :strangertalks_new}} -> :ok
    end
  end
end

StrangertalksNew.ProviderProbeBootIsolationProof.run()
