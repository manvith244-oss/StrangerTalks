defmodule StrangertalksNew.AccountSync do
  @moduledoc false
  import Ecto.Query

  alias StrangertalksNew.AccountSyncLock
  alias StrangertalksNew.Accounts.AccountSyncState
  alias StrangertalksNew.GoogleContinuity.TokenCrypto
  alias StrangertalksNew.{Accounts, Repo}

  @max_bytes 10 * 1024 * 1024

  def get(account_id), do: AccountSyncLock.with_account(account_id, fn -> do_get(account_id) end)

  def put(account_id, base_revision, envelope)
      when is_integer(base_revision) and base_revision >= 0 do
    AccountSyncLock.with_account(account_id, fn ->
      with :ok <- validate_envelope(envelope),
           :ok <- validate_size(envelope),
           {:ok, access_token} <- access_token(account_id),
           {:ok, current} <- current_snapshot(account_id, access_token),
           true <- current.revision == base_revision || {:error, :sync_conflict},
           next <-
             envelope
             |> Map.put("revision", base_revision + 1)
             |> Map.put("updated_at", now_iso()),
           :ok <- validate_size(next),
           {:ok, file_id} <- upload(access_token, current.file_id, next),
           :ok <- cache(account_id, file_id, next) do
        {:ok,
         %{
           status: "synced",
           revision: base_revision + 1,
           last_synced_at: now_iso(),
           encrypted_byte_size: byte_size(Jason.encode!(next))
         }}
      end
    end)
  end

  def put(_account_id, _revision, _envelope), do: {:error, :invalid_sync_envelope}

  def delete(account_id) do
    AccountSyncLock.with_account(account_id, fn ->
      with {:ok, access_token} <- access_token(account_id),
           {:ok, current} <- current_snapshot(account_id, access_token),
           :ok <- maybe_delete(access_token, current.file_id) do
        Repo.delete_all(from(s in AccountSyncState, where: s.account_id == ^account_id))
        :ok
      end
    end)
  end

  def max_bytes, do: @max_bytes

  def validate_envelope(%{
        "kind" => "strangertalks_encrypted_sync",
        "version" => 1,
        "revision" => revision,
        "created_at" => created_at,
        "updated_at" => updated_at,
        "key_wrap" => key_wrap,
        "content" => content
      })
      when is_integer(revision) and revision >= 0 and is_binary(created_at) and
             is_binary(updated_at) and is_map(key_wrap) and is_map(content) do
    required_wrap = ["algorithm", "hash", "iterations", "salt", "iv", "wrapped_sync_key"]
    required_content = ["algorithm", "iv", "ciphertext"]

    valid =
      Enum.all?(required_wrap, &valid_outer_value?(key_wrap, &1)) and
        Enum.all?(required_content, &valid_outer_value?(content, &1)) and
        key_wrap["algorithm"] == "AES-GCM" and key_wrap["hash"] == "SHA-256" and
        key_wrap["iterations"] == 210_000 and content["algorithm"] == "AES-GCM"

    if valid, do: :ok, else: {:error, :invalid_sync_envelope}
  end

  def validate_envelope(_), do: {:error, :invalid_sync_envelope}

  defp do_get(account_id) do
    with {:ok, access_token} <- access_token(account_id),
         {:ok, current} <- current_snapshot(account_id, access_token) do
      if current.file_id do
        :ok = cache(account_id, current.file_id, current.envelope)

        {:ok,
         %{
           status: "ready",
           revision: current.revision,
           envelope: current.envelope,
           last_synced_at: state_time(account_id),
           encrypted_byte_size: byte_size(Jason.encode!(current.envelope))
         }}
      else
        {:ok, %{status: "empty", revision: 0}}
      end
    end
  end

  defp current_snapshot(account_id, access_token) do
    provider = StrangertalksNew.GoogleContinuity.provider()
    cached = Repo.get(AccountSyncState, account_id)

    with {:cached, file_id} when is_binary(file_id) <- {:cached, cached && cached.drive_file_id},
         {:ok, envelope} <- provider.download_sync_file(access_token, file_id),
         :ok <- validate_envelope(envelope) do
      {:ok, %{file_id: file_id, revision: envelope["revision"], envelope: envelope}}
    else
      _ -> locate_snapshot(provider, access_token)
    end
  end

  defp locate_snapshot(provider, access_token) do
    with {:ok, file} <- provider.find_sync_file(access_token) do
      case file do
        nil ->
          {:ok, %{file_id: nil, revision: 0, envelope: nil}}

        %{"id" => file_id} ->
          with {:ok, envelope} <- provider.download_sync_file(access_token, file_id),
               :ok <- validate_envelope(envelope) do
            {:ok, %{file_id: file_id, revision: envelope["revision"], envelope: envelope}}
          end
      end
    end
  end

  defp access_token(account_id) do
    with link when not is_nil(link) <- Accounts.active_link(account_id),
         refresh when is_binary(refresh) <- TokenCrypto.decrypt_refresh_token(link),
         {:ok, access_token} <-
           StrangertalksNew.GoogleContinuity.provider().refresh_access_token(refresh) do
      {:ok, access_token}
    else
      _ -> {:error, :google_reauthorization_required}
    end
  end

  defp upload(access_token, nil, envelope),
    do: StrangertalksNew.GoogleContinuity.provider().create_sync_file(access_token, envelope)

  defp upload(access_token, file_id, envelope) do
    case StrangertalksNew.GoogleContinuity.provider().update_sync_file(
           access_token,
           file_id,
           envelope
         ) do
      :ok -> {:ok, file_id}
      error -> error
    end
  end

  defp cache(account_id, file_id, envelope) do
    encoded = Jason.encode!(envelope)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      account_id: account_id,
      drive_file_id: file_id,
      last_known_revision: envelope["revision"],
      encrypted_payload_sha256: :crypto.hash(:sha256, encoded),
      encrypted_byte_size: byte_size(encoded),
      last_synced_at: now,
      created_at: now,
      updated_at: now
    }

    changeset = Ecto.Changeset.cast(%AccountSyncState{}, attrs, Map.keys(attrs))

    case Repo.insert(changeset,
           on_conflict:
             {:replace,
              [
                :drive_file_id,
                :last_known_revision,
                :encrypted_payload_sha256,
                :encrypted_byte_size,
                :last_synced_at,
                :updated_at
              ]},
           conflict_target: :account_id
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :metadata_cache_failed}
    end
  end

  defp state_time(account_id) do
    case Repo.get(AccountSyncState, account_id) do
      nil -> nil
      state -> state.last_synced_at
    end
  end

  defp maybe_delete(_access_token, nil), do: :ok

  defp maybe_delete(access_token, file_id),
    do: StrangertalksNew.GoogleContinuity.provider().delete_sync_file(access_token, file_id)

  defp validate_size(envelope),
    do:
      if(byte_size(Jason.encode!(envelope)) <= @max_bytes,
        do: :ok,
        else: {:error, :sync_too_large}
      )

  defp valid_outer_value?(map, "iterations"), do: is_integer(map["iterations"])
  defp valid_outer_value?(map, key), do: is_binary(map[key]) and map[key] != ""
  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
