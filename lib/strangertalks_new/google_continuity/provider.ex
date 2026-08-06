defmodule StrangertalksNew.GoogleContinuity.Provider do
  @moduledoc false
  @callback authorization_url(String.t(), String.t(), String.t()) :: String.t()
  @callback exchange_and_verify(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  @callback refresh_access_token(String.t()) :: {:ok, String.t()} | {:error, atom()}
  @callback revoke(String.t()) :: :ok | :already_revoked | {:error, atom()}
  @callback find_sync_file(String.t()) :: {:ok, nil | map()} | {:error, atom()}
  @callback download_sync_file(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  @callback create_sync_file(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  @callback update_sync_file(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  @callback delete_sync_file(String.t(), String.t()) :: :ok | {:error, atom()}
end
