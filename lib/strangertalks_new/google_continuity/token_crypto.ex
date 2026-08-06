defmodule StrangertalksNew.GoogleContinuity.TokenCrypto do
  @moduledoc false
  @version 1

  def subject_hash(subject) when is_binary(subject) do
    {:ok, key} =
      StrangertalksNew.GoogleContinuity.required_config!()[:subject_hmac_key] |> Base.decode64()

    :crypto.mac(:hmac, :sha256, key, subject)
  end

  def encrypt_refresh_token(token, link_id, account_id) when is_binary(token) do
    key = encryption_key!()
    iv = :crypto.strong_rand_bytes(12)
    aad = aad(link_id, account_id, @version)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, token, aad, true)

    %{
      encrypted_refresh_token: ciphertext,
      refresh_token_iv: iv,
      refresh_token_tag: tag,
      token_key_version: @version
    }
  end

  def decrypt_refresh_token(%{
        encrypted_refresh_token: ciphertext,
        refresh_token_iv: iv,
        refresh_token_tag: tag,
        token_key_version: version,
        google_account_link_id: link_id,
        account_id: account_id
      })
      when is_binary(ciphertext) and is_binary(iv) and is_binary(tag) do
    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      encryption_key!(),
      iv,
      ciphertext,
      aad(link_id, account_id, version),
      tag,
      false
    )
  end

  defp encryption_key! do
    {:ok, key} =
      Base.decode64(
        StrangertalksNew.GoogleContinuity.required_config!()[:refresh_token_encryption_key]
      )

    key
  end

  defp aad(link_id, account_id, version), do: "#{link_id}:#{account_id}:#{version}"
end
