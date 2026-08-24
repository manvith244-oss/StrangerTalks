defmodule StrangertalksNew.C11Policy do
  @moduledoc """
  Subordinate C11 Zero-Bill Admission and Provider Reservation Policy Module.

  Enforces strict free-tier capacity limits for live communication relay infrastructure.
  Guarantees zero paid media overflow and linearizable reservation gating with
  account-wide cross-Conversation synchronization via `:global.trans` without
  an independent GenServer or persistent database tables.
  """

  @account_budget_lock_resource {:strangertalks_c11_account_budget_lock, :account_wide}
  @default_max_fallback_reservations 0
  @default_quarantine_seconds 300

  @type provider :: :oracle | :cloudflare
  @type reservation :: %{
          provider: provider(),
          reserved_at: integer(),
          expires_at: integer(),
          conversation_id: String.t(),
          call_attempt_id: String.t()
        }

  @type state :: %{
          primary_available: boolean(),
          fallback_available: boolean(),
          quotas_verified: boolean(),
          max_fallback_reservations: non_neg_integer(),
          credential_ttl_seconds: non_neg_integer() | nil,
          active_reservations: %{String.t() => reservation()},
          terminal_exposures: %{String.t() => integer()},
          quarantine_until: integer() | nil,
          usage_snapshot: map() | nil,
          usage_snapshot_at: integer() | nil,
          usage_max_staleness_ms: integer(),
          provider_credentials: map()
        }

  @doc """
  Constant single-node account budget lock resource tuple for `:global.trans`.
  """
  def account_budget_lock_resource, do: @account_budget_lock_resource

  @doc """
  Executes the given function within the account-wide C11 critical section lock.
  """
  def with_account_lock(fun) when is_function(fun, 0) do
    :global.trans({@account_budget_lock_resource, self()}, fun, [node()])
  end

  @doc """
  Initializes default C11 policy state.
  In production, without explicit verified provider configuration, this fails closed.
  """
  def init_state(opts \\ []) do
    snapshot = Keyword.get(opts, :usage_snapshot, nil)

    snapshot_at =
      Keyword.get(
        opts,
        :usage_snapshot_at,
        if(snapshot, do: System.monotonic_time(:millisecond), else: nil)
      )

    %{
      primary_available: Keyword.get(opts, :primary_available, false),
      fallback_available: Keyword.get(opts, :fallback_available, false),
      quotas_verified: Keyword.get(opts, :quotas_verified, false),
      max_fallback_reservations:
        Keyword.get(opts, :max_fallback_reservations, @default_max_fallback_reservations),
      credential_ttl_seconds: Keyword.get(opts, :credential_ttl_seconds, nil),
      active_reservations: %{},
      terminal_exposures: %{},
      quarantine_until: Keyword.get(opts, :quarantine_until, nil),
      usage_snapshot: snapshot,
      usage_snapshot_at: snapshot_at,
      usage_max_staleness_ms: Keyword.get(opts, :usage_max_staleness_ms, 60_000),
      provider_credentials:
        Keyword.get(
          opts,
          :provider_credentials,
          Application.get_env(:strangertalks_new, :turn_provider_credentials, %{})
        )
    }
  end

  @doc """
  Derives all current active call reservations and terminal exposures across
  active ConversationServers registered in StrangertalksNew.DistributedRegistry.
  Must be executed under the C11 account-wide lock.
  """
  def derive_node_reservations do
    sup_pids =
      case Process.whereis(StrangertalksNew.ConversationDynamicSupervisor) do
        nil ->
          []

        sup_pid ->
          try do
            DynamicSupervisor.which_children(sup_pid)
            |> Enum.map(fn
              {_, pid, _, _} when is_pid(pid) -> pid
              _ -> nil
            end)
            |> Enum.filter(&is_pid/1)
          catch
            :exit, _ -> []
          end
      end

    reg_pids =
      case Process.whereis(StrangertalksNew.DistributedRegistry) do
        nil ->
          []

        _ ->
          try do
            Registry.select(StrangertalksNew.DistributedRegistry, [
              {{:"$1", :"$2", :_}, [], [:"$2"]}
            ])
          catch
            :exit, _ -> []
          end
      end

    pids = Enum.uniq(sup_pids ++ reg_pids)

    Enum.reduce(pids, {%{}, %{}}, fn pid, {acc_res, acc_exp} ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          case GenServer.call(pid, :get_c11_reservation, 2000) do
            %{active_reservation: res, terminal_exposure: exp} ->
              acc_res =
                if is_map(res) and is_binary(Map.get(res, :call_attempt_id)) do
                  Map.put(acc_res, res.call_attempt_id, res)
                else
                  acc_res
                end

              acc_exp =
                if is_map(exp) and is_binary(Map.get(exp, :call_attempt_id)) and
                     is_integer(Map.get(exp, :expires_at)) do
                  Map.put(acc_exp, exp.call_attempt_id, exp.expires_at)
                else
                  acc_exp
                end

              {acc_res, acc_exp}

            _ ->
              {acc_res, acc_exp}
          end
        catch
          :exit, _ -> {acc_res, acc_exp}
        end
      else
        {acc_res, acc_exp}
      end
    end)
  end

  @doc """
  Sets the system in post-BEAM-restart quarantine mode.
  During quarantine, fallback admissions fail closed unless verified safe.
  """
  def enter_restart_quarantine(state, quarantine_seconds \\ @default_quarantine_seconds) do
    now = System.monotonic_time(:millisecond)
    %{state | quarantine_until: now + quarantine_seconds * 1000}
  end

  @doc """
  Checks if quarantine is currently active.
  """
  def quarantined?(state, now \\ nil) do
    current = now || System.monotonic_time(:millisecond)

    case state.quarantine_until do
      nil -> false
      until_time -> current < until_time
    end
  end

  @doc """
  Linearizable admission evaluation.
  Returns `{:ok, provider, updated_state}` or `{:error, reason, state}`.
  """
  def admit_and_reserve(state, conversation_id, call_attempt_id, now \\ nil) do
    current_time = now || System.monotonic_time(:millisecond)
    state = cleanup_expired_exposures(state, current_time)
    oracle_ready = state.primary_available and provider_configured?(state, :oracle)
    cloudflare_ready = state.fallback_available and provider_configured?(state, :cloudflare)

    cond do
      not state.quotas_verified ->
        {:error, :unverified_provider_quotas, state}

      is_nil(state.credential_ttl_seconds) or not is_integer(state.credential_ttl_seconds) or
          state.credential_ttl_seconds <= 0 ->
        {:error, :unverified_credential_ttl, state}

      oracle_ready ->
        reservation = %{
          provider: :oracle,
          reserved_at: current_time,
          expires_at: current_time + state.credential_ttl_seconds * 1000,
          conversation_id: conversation_id,
          call_attempt_id: call_attempt_id
        }

        {:ok, :oracle, put_in(state.active_reservations[call_attempt_id], reservation)}

      cloudflare_ready and quarantined?(state, current_time) ->
        {:error, :quarantine_active, state}

      cloudflare_ready and stale_or_missing_snapshot?(state, current_time) ->
        {:error, :stale_usage_snapshot, state}

      cloudflare_ready and safe_capacity_available?(state) ->
        reservation = %{
          provider: :cloudflare,
          reserved_at: current_time,
          expires_at: current_time + state.credential_ttl_seconds * 1000,
          conversation_id: conversation_id,
          call_attempt_id: call_attempt_id
        }

        {:ok, :cloudflare, put_in(state.active_reservations[call_attempt_id], reservation)}

      (state.primary_available and not provider_configured?(state, :oracle)) or
          (state.fallback_available and not provider_configured?(state, :cloudflare)) ->
        {:error, :provider_not_configured, state}

      true ->
        {:error, :capacity_busy, state}
    end
  end

  @doc """
  Gating for credential extensions.
  """
  def admit_extension(state, call_attempt_id, now \\ nil) do
    current_time = now || System.monotonic_time(:millisecond)

    cond do
      is_nil(state.credential_ttl_seconds) or not is_integer(state.credential_ttl_seconds) or
          state.credential_ttl_seconds <= 0 ->
        {:error, :unverified_credential_ttl, state}

      true ->
        case Map.get(state.active_reservations, call_attempt_id) do
          nil ->
            {:error, :no_active_reservation, state}

          %{provider: provider} = reservation when provider in [:oracle, :cloudflare] ->
            cond do
              not provider_configured?(state, provider) ->
                {:error, :provider_not_configured, state}

              provider == :cloudflare and stale_or_missing_snapshot?(state, current_time) ->
                {:error, :stale_usage_snapshot, state}

              true ->
                updated = %{
                  reservation
                  | expires_at: current_time + state.credential_ttl_seconds * 1000
                }

                {:ok, provider, put_in(state.active_reservations[call_attempt_id], updated)}
            end
        end
    end
  end

  @doc """
  Records human call termination.
  Moves active reservation to terminal exposure window so it cannot be immediately reused
  until the provider allocation has certainly expired.
  """
  def record_call_terminal(state, call_attempt_id, now \\ nil) do
    current_time = now || System.monotonic_time(:millisecond)

    case Map.pop(state.active_reservations, call_attempt_id) do
      {nil, _} ->
        state

      {reservation, remaining_reservations} ->
        exposure_until = max(reservation.expires_at, current_time + 10_000)
        new_exposures = Map.put(state.terminal_exposures, call_attempt_id, exposure_until)
        %{state | active_reservations: remaining_reservations, terminal_exposures: new_exposures}
    end
  end

  @doc """
  Releases exposure window when cleanup is confirmed or time has elapsed.
  """
  def release_exposure(state, call_attempt_id) do
    new_exposures = Map.delete(state.terminal_exposures, call_attempt_id)
    %{state | terminal_exposures: new_exposures}
  end

  @doc """
  Generates ephemeral credentials for authorized provider.
  Uses opaque identifier tokens without embedding raw conversation or participant IDs.
  Fails closed with `{:error, :unverified_credential_ttl}` if TTL is absent or non-positive.
  """
  def authorize_credentials(provider, _conversation_id, _participant_id, call_attempt_id, ttl) do
    if is_nil(ttl) or not is_integer(ttl) or ttl <= 0 do
      {:error, :unverified_credential_ttl}
    else
      config = provider_config(provider)

      if valid_provider_config?(provider, config),
        do: issue_provider_credentials(provider, config, call_attempt_id, ttl),
        else: {:error, :provider_not_configured}
    end
  end

  defp issue_provider_credentials(:oracle, config, call_attempt_id, ttl) do
    opaque_token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    username = "#{System.system_time(:second) + ttl}:#{opaque_token}"
    credential = :crypto.mac(:hmac, :sha, config.shared_secret, username) |> Base.encode64()

    {:ok,
     %{
       provider: :oracle,
       ice_servers: [%{urls: config.urls, username: username, credential: credential}],
       ice_transport_policy: "relay",
       ttl_seconds: ttl,
       call_attempt_id: call_attempt_id
     }}
  end

  defp issue_provider_credentials(:cloudflare, config, call_attempt_id, ttl) do
    result =
      case Map.get(config, :client) do
        client when is_atom(client) ->
          if function_exported?(client, :generate_ice_servers, 2),
            do: client.generate_ice_servers(config, ttl),
            else: {:error, :provider_credential_unavailable}

        _ ->
          endpoint = Map.get(config, :endpoint, "https://rtc.live.cloudflare.com")

          url =
            "#{String.trim_trailing(endpoint, "/")}/v1/turn/keys/#{URI.encode(config.key_id)}/credentials/generate-ice-servers"

          case Req.post(url,
                 headers: [{"authorization", "Bearer #{config.api_token}"}],
                 json: %{ttl: ttl},
                 receive_timeout: 5_000
               ) do
            {:ok, %Req.Response{status: 201, body: body}} ->
              {:ok, Map.get(body, "iceServers") || Map.get(body, :iceServers) || []}

            _ ->
              {:error, :provider_credential_unavailable}
          end
      end

    with {:ok, servers} <- result,
         relay_servers when relay_servers != [] <- relay_only_ice_servers(servers) do
      {:ok,
       %{
         provider: :cloudflare,
         ice_servers: relay_servers,
         ice_transport_policy: "relay",
         ttl_seconds: ttl,
         call_attempt_id: call_attempt_id
       }}
    else
      _ -> {:error, :provider_credential_unavailable}
    end
  end

  defp relay_only_ice_servers(servers) when is_list(servers) do
    Enum.flat_map(servers, fn server ->
      urls =
        (Map.get(server, "urls") || Map.get(server, :urls) || [])
        |> List.wrap()
        |> Enum.filter(fn url ->
          is_binary(url) and
            (String.starts_with?(url, "turn:") or String.starts_with?(url, "turns:"))
        end)

      username = Map.get(server, "username") || Map.get(server, :username)
      credential = Map.get(server, "credential") || Map.get(server, :credential)

      if urls != [] and is_binary(username) and username != "" and is_binary(credential) and
           credential != "",
         do: [%{urls: urls, username: username, credential: credential}],
         else: []
    end)
  end

  defp relay_only_ice_servers(_), do: []

  defp provider_config(provider) do
    Application.get_env(:strangertalks_new, :turn_provider_credentials, %{}) |> Map.get(provider)
  end

  defp provider_configured?(state, provider),
    do: valid_provider_config?(provider, Map.get(state.provider_credentials, provider))

  defp valid_provider_config?(:oracle, %{
         strategy: :coturn_rest,
         urls: urls,
         shared_secret: secret
       }) do
    is_list(urls) and urls != [] and
      Enum.all?(urls, fn url ->
        is_binary(url) and
          (String.starts_with?(url, "turn:") or String.starts_with?(url, "turns:"))
      end) and
      is_binary(secret) and secret != ""
  end

  defp valid_provider_config?(:cloudflare, %{
         strategy: :cloudflare_api,
         key_id: key_id,
         api_token: token
       }) do
    is_binary(key_id) and key_id != "" and is_binary(token) and token != ""
  end

  defp valid_provider_config?(_, _), do: false

  # --- Internal Helpers ---

  defp safe_capacity_available?(state) do
    active_count =
      state.active_reservations
      |> Enum.count(fn {_, res} -> res.provider == :cloudflare end)

    exposure_count = map_size(state.terminal_exposures)

    total_committed = active_count + exposure_count
    total_committed < state.max_fallback_reservations
  end

  defp stale_or_missing_snapshot?(state, current_time) do
    case {state.usage_snapshot, state.usage_snapshot_at} do
      {nil, _} -> true
      {_, nil} -> true
      {_, snapshot_at} -> current_time - snapshot_at > state.usage_max_staleness_ms
    end
  end

  defp cleanup_expired_exposures(state, current_time) do
    valid_exposures =
      state.terminal_exposures
      |> Enum.filter(fn {_, expiry} -> expiry > current_time end)
      |> Map.new()

    %{state | terminal_exposures: valid_exposures}
  end
end
