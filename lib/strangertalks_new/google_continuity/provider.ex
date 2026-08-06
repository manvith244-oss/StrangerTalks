defmodule StrangertalksNew.GoogleContinuity.Provider do
  @moduledoc false
  @callback authorization_url(String.t(), String.t(), String.t()) :: String.t()
  @callback exchange_and_verify(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  @callback refresh_access_token(String.t()) :: {:ok, String.t()} | {:error, atom()}
  @callback revoke(String.t()) :: :ok | {:error, atom()}
end
