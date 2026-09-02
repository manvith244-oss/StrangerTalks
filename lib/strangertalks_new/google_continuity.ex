defmodule StrangertalksNew.GoogleContinuity do
  @moduledoc false

  def enabled?, do: config()[:enabled] == true
  def config, do: Application.get_env(:strangertalks_new, :google_continuity, enabled: false)
  def provider, do: config()[:provider] || StrangertalksNew.GoogleContinuity.GoogleProvider

  def required_config! do
    values = config()

    if values[:enabled] do
      for key <- [
            :client_id,
            :client_secret,
            :redirect_uri,
            :subject_hmac_key,
            :refresh_token_encryption_key
          ] do
        value = values[key]

        if not is_binary(value) or value == "",
          do: raise("Google continuity is enabled but #{key} is missing")
      end

      case Base.decode64(values[:refresh_token_encryption_key]) do
        {:ok, key} when byte_size(key) == 32 ->
          :ok

        _ ->
          raise "Google continuity refresh-token encryption key must decode to exactly 32 bytes"
      end

      case Base.decode64(values[:subject_hmac_key]) do
        {:ok, key} when byte_size(key) == 32 -> :ok
        _ -> raise "Google continuity subject HMAC key must decode to exactly 32 bytes"
      end
    end

    values
  end
end
