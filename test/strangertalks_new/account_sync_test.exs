defmodule StrangertalksNew.AccountSyncTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Accounts
  alias StrangertalksNew.Accounts.AccountSyncState
  alias StrangertalksNew.{AccountSync, Participants, Repo}

  defmodule FakeDrive do
    @behaviour StrangertalksNew.GoogleContinuity.Provider
    def authorization_url(_, _, _), do: "/fake"
    def exchange_and_verify(_, _), do: {:error, :not_used}

    def refresh_access_token("refresh-secret") do
      update(&Map.update(&1, :refreshes, 1, fn count -> count + 1 end))
      {:ok, "temporary-access"}
    end

    def refresh_access_token(_), do: {:error, :google_reauthorization_required}
    def revoke(_), do: :ok

    def find_sync_file("temporary-access") do
      state = state()

      case state[:file] do
        nil -> {:ok, nil}
        %{id: id} -> {:ok, %{"id" => id}}
      end
    end

    def download_sync_file("temporary-access", file_id) do
      case state()[:file] do
        %{id: ^file_id, envelope: envelope} -> {:ok, envelope}
        _ -> {:error, :sync_file_not_found}
      end
    end

    def create_sync_file("temporary-access", envelope) do
      update(&Map.put(&1, :file, %{id: "app-data-only-file", envelope: envelope}))
      {:ok, "app-data-only-file"}
    end

    def update_sync_file("temporary-access", "app-data-only-file", envelope) do
      update(&Map.put(&1, :file, %{id: "app-data-only-file", envelope: envelope}))
      :ok
    end

    def delete_sync_file("temporary-access", "app-data-only-file") do
      update(&Map.put(&1, :file, nil))
      :ok
    end

    def state, do: Application.get_env(:strangertalks_new, :fake_drive_state, %{})

    defp update(fun),
      do: Application.put_env(:strangertalks_new, :fake_drive_state, fun.(state()))
  end

  setup do
    previous = Application.get_env(:strangertalks_new, :google_continuity)

    Application.put_env(:strangertalks_new, :google_continuity,
      enabled: true,
      provider: FakeDrive,
      client_id: "id",
      client_secret: "secret",
      redirect_uri: "local",
      subject_hmac_key: Base.encode64(:binary.copy(<<9>>, 32)),
      refresh_token_encryption_key: Base.encode64(:binary.copy(<<8>>, 32))
    )

    Application.put_env(:strangertalks_new, :fake_drive_state, %{})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:strangertalks_new, :google_continuity, previous),
        else: Application.delete_env(:strangertalks_new, :google_continuity)

      Application.delete_env(:strangertalks_new, :fake_drive_state)
    end)

    {:ok, account: linked_account()}
  end

  test "empty sync creates one canonical file and later updates it", %{account: account} do
    assert {:ok, %{status: "empty", revision: 0}} = AccountSync.get(account.account_id)
    assert {:ok, %{revision: 1}} = AccountSync.put(account.account_id, 0, envelope(0, "first"))
    assert %{id: "app-data-only-file", envelope: %{"revision" => 1}} = FakeDrive.state().file

    assert {:ok,
            %{status: "ready", revision: 1, envelope: %{"content" => %{"ciphertext" => "first"}}}} =
             AccountSync.get(account.account_id)

    assert {:ok, %{revision: 2}} = AccountSync.put(account.account_id, 1, envelope(1, "second"))
    assert FakeDrive.state().file.id == "app-data-only-file"
    assert Repo.get!(AccountSyncState, account.account_id).last_known_revision == 2
  end

  test "stale writes conflict without overwriting Drive", %{account: account} do
    assert {:ok, _} = AccountSync.put(account.account_id, 0, envelope(0, "first"))
    assert {:error, :sync_conflict} = AccountSync.put(account.account_id, 0, envelope(0, "stale"))
    assert FakeDrive.state().file.envelope["content"]["ciphertext"] == "first"
  end

  test "server stores metadata but never the encrypted envelope or access token", %{
    account: account
  } do
    assert {:ok, _} =
             AccountSync.put(account.account_id, 0, envelope(0, "ciphertext-not-in-postgres"))

    fields = AccountSyncState.__schema__(:fields)
    refute Enum.any?([:envelope, :encrypted_content, :access_token], &(&1 in fields))
    state = Repo.get!(AccountSyncState, account.account_id)
    assert state.encrypted_payload_sha256
    assert state.encrypted_byte_size > 0
  end

  test "delete is idempotent and removes only app-data metadata", %{account: account} do
    assert {:ok, _} = AccountSync.put(account.account_id, 0, envelope(0, "first"))
    assert :ok = AccountSync.delete(account.account_id)
    assert :ok = AccountSync.delete(account.account_id)
    assert is_nil(FakeDrive.state().file)
    assert is_nil(Repo.get(AccountSyncState, account.account_id))
  end

  test "outer validation and ten MiB bound reject invalid input before upload", %{
    account: account
  } do
    assert {:error, :invalid_sync_envelope} =
             AccountSync.put(account.account_id, 0, %{"ciphertext" => "opaque"})

    assert {:error, :sync_too_large} =
             AccountSync.put(
               account.account_id,
               0,
               envelope(0, :binary.copy("x", AccountSync.max_bytes()))
             )

    assert is_nil(FakeDrive.state()[:file])
  end

  defp linked_account do
    {:ok, participant} =
      Participants.create_participant(%{
        created_at: DateTime.utc_now(),
        last_active_at: DateTime.utc_now()
      })

    {:ok, _, state, _} = Accounts.start_oauth("LINK_CURRENT_GUEST", participant.participant_id)
    {:ok, attempt} = Accounts.consume_oauth(state)

    {:ok, result} =
      Accounts.complete_oauth(attempt, %{
        subject: "sync-subject",
        refresh_token: "refresh-secret",
        access_token: "not-persisted",
        scopes: ["openid", "https://www.googleapis.com/auth/drive.appdata"]
      })

    result.account
  end

  defp envelope(revision, ciphertext) do
    %{
      "kind" => "strangertalks_encrypted_sync",
      "version" => 1,
      "revision" => revision,
      "created_at" => "2026-08-06T00:00:00Z",
      "updated_at" => "2026-08-06T00:00:00Z",
      "key_wrap" => %{
        "algorithm" => "AES-GCM",
        "hash" => "SHA-256",
        "iterations" => 210_000,
        "salt" => "salt",
        "iv" => "iv",
        "wrapped_sync_key" => "wrapped"
      },
      "content" => %{"algorithm" => "AES-GCM", "iv" => "iv", "ciphertext" => ciphertext}
    }
  end
end
