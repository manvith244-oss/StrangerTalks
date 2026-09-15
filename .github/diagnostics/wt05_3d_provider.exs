defmodule WT05SameAccountProviderState do
  use Agent

  def start_link(_) do
    Agent.start_link(
      fn -> %{exchange_count: 0, files: %{}} end,
      name: __MODULE__
    )
  end

  def next_identity do
    Agent.get_and_update(__MODULE__, fn state ->
      count = state.exchange_count + 1
      identity = if count <= 2, do: :same, else: :other
      {identity, %{state | exchange_count: count}}
    end)
  end

  def find(access_token) do
    Agent.get(__MODULE__, fn state ->
      case state.files[access_token] do
        nil -> {:ok, nil}
        %{id: id} -> {:ok, %{"id" => id}}
      end
    end)
  end

  def download(access_token, file_id) do
    Agent.get(__MODULE__, fn state ->
      case state.files[access_token] do
        %{id: ^file_id, envelope: envelope} -> {:ok, envelope}
        _ -> {:error, :sync_file_not_found}
      end
    end)
  end

  def create(access_token, envelope) do
    id = "wt05-sync-" <> Base.url_encode64(:crypto.hash(:sha256, access_token), padding: false)
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:files, access_token], %{id: id, envelope: envelope})
    end)
    {:ok, id}
  end

  def update(access_token, file_id, envelope) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.files[access_token] do
        %{id: ^file_id} ->
          {:ok, put_in(state, [:files, access_token], %{id: file_id, envelope: envelope})}
        _ ->
          {{:error, :sync_file_not_found}, state}
      end
    end)
  end

  def delete(access_token, file_id) do
    Agent.update(__MODULE__, fn state ->
      case state.files[access_token] do
        %{id: ^file_id} -> %{state | files: Map.delete(state.files, access_token)}
        _ -> state
      end
    end)
    :ok
  end
end

defmodule WT05SameAccountProvider do
  @behaviour StrangertalksNew.GoogleContinuity.Provider

  @impl true
  def authorization_url(state, _nonce, _mode) do
    "http://localhost:4000/auth/google/callback?" <>
      URI.encode_query(%{state: state, code: "wt05-provider"})
  end

  @impl true
  def exchange_and_verify("wt05-provider", _nonce) do
    case WT05SameAccountProviderState.next_identity() do
      :same ->
        {:ok,
         %{
           subject: "wt05-same-account-subject",
           refresh_token: "wt05-refresh-same",
           access_token: "wt05-access-same",
           scopes: ["openid", "https://www.googleapis.com/auth/drive.appdata"]
         }}

      :other ->
        {:ok,
         %{
           subject: "wt05-unrelated-account-subject",
           refresh_token: "wt05-refresh-other",
           access_token: "wt05-access-other",
           scopes: ["openid", "https://www.googleapis.com/auth/drive.appdata"]
         }}
    end
  end

  def exchange_and_verify(_, _), do: {:error, :invalid_code}

  @impl true
  def refresh_access_token("wt05-refresh-same"), do: {:ok, "wt05-access-same"}
  def refresh_access_token("wt05-refresh-other"), do: {:ok, "wt05-access-other"}
  def refresh_access_token(_), do: {:error, :invalid_refresh_token}

  @impl true
  def revoke(_), do: :ok

  @impl true
  def find_sync_file(access_token), do: WT05SameAccountProviderState.find(access_token)

  @impl true
  def download_sync_file(access_token, file_id),
    do: WT05SameAccountProviderState.download(access_token, file_id)

  @impl true
  def create_sync_file(access_token, envelope),
    do: WT05SameAccountProviderState.create(access_token, envelope)

  @impl true
  def update_sync_file(access_token, file_id, envelope),
    do: WT05SameAccountProviderState.update(access_token, file_id, envelope)

  @impl true
  def delete_sync_file(access_token, file_id),
    do: WT05SameAccountProviderState.delete(access_token, file_id)
end

{:ok, _} = WT05SameAccountProviderState.start_link([])

Application.put_env(
  :strangertalks_new,
  :google_continuity,
  enabled: true,
  provider: WT05SameAccountProvider,
  client_id: "wt05-disposable",
  client_secret: "wt05-disposable",
  redirect_uri: "http://localhost:4000/auth/google/callback",
  subject_hmac_key: Base.encode64(:binary.copy(<<9>>, 32)),
  refresh_token_encryption_key: Base.encode64(:binary.copy(<<7>>, 32))
)

Application.put_env(:strangertalks_new, :account_cookie_secure, false)

repo = Application.fetch_env!(:strangertalks_new, StrangertalksNew.Repo)
repo = repo |> Keyword.put(:pool, DBConnection.ConnectionPool) |> Keyword.put(:pool_size, 24)
Application.put_env(:strangertalks_new, StrangertalksNew.Repo, repo)

endpoint = Application.fetch_env!(:strangertalks_new, StrangertalksNewWeb.Endpoint)
Application.put_env(
  :strangertalks_new,
  StrangertalksNewWeb.Endpoint,
  Keyword.put(endpoint, :server, true)
)

{:ok, _} = Application.ensure_all_started(:strangertalks_new)
Process.sleep(:infinity)
