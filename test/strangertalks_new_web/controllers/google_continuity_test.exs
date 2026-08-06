defmodule StrangertalksNewWeb.GoogleContinuityTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Accounts
  alias StrangertalksNew.Accounts.{AccountSession, GoogleAccountLink, PrivateAccount}
  alias StrangertalksNew.GoogleContinuity.TokenCrypto
  alias StrangertalksNew.{Participant, Participants, Repo}
  alias StrangertalksNewWeb.ParticipantToken

  defmodule FakeProvider do
    @behaviour StrangertalksNew.GoogleContinuity.Provider
    def authorization_url(state, nonce, mode),
      do: "/fake-google?" <> URI.encode_query(state: state, nonce: nonce, mode: mode)

    def exchange_and_verify(_code, nonce) do
      result = Application.fetch_env!(:strangertalks_new, :fake_google_result)

      if result[:expected_nonce] in [nil, nonce],
        do: {:ok, Map.delete(result, :expected_nonce)},
        else: {:error, :invalid_nonce}
    end

    def refresh_access_token(_token), do: {:ok, "memory-only-access-token"}
    def revoke(_token), do: Application.get_env(:strangertalks_new, :fake_revoke_result, :ok)
    def find_sync_file(_token), do: {:ok, nil}
    def download_sync_file(_token, _file_id), do: {:error, :sync_file_not_found}
    def create_sync_file(_token, _envelope), do: {:error, :not_used}
    def update_sync_file(_token, _file_id, _envelope), do: {:error, :not_used}
    def delete_sync_file(_token, _file_id), do: :ok
  end

  setup do
    previous = Application.get_env(:strangertalks_new, :google_continuity)

    config = [
      enabled: true,
      provider: FakeProvider,
      client_id: "client",
      client_secret: "secret",
      redirect_uri: "http://localhost/auth/google/callback",
      subject_hmac_key: Base.encode64(:binary.copy(<<9>>, 32)),
      refresh_token_encryption_key: Base.encode64(:binary.copy(<<7>>, 32))
    ]

    Application.put_env(:strangertalks_new, :google_continuity, config)
    Application.put_env(:strangertalks_new, :account_cookie_secure, false)

    Application.put_env(:strangertalks_new, :fake_google_result, %{
      subject: "google-subject-a",
      refresh_token: "refresh-secret",
      access_token: "ephemeral",
      scopes: ["openid", "https://www.googleapis.com/auth/drive.appdata"]
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:strangertalks_new, :google_continuity, previous),
        else: Application.delete_env(:strangertalks_new, :google_continuity)

      Application.delete_env(:strangertalks_new, :account_cookie_secure)
      Application.delete_env(:strangertalks_new, :fake_google_result)
      Application.delete_env(:strangertalks_new, :fake_revoke_result)
    end)

    :ok
  end

  test "guest flow remains available while Google continuity is disabled", %{conn: conn} do
    Application.put_env(:strangertalks_new, :google_continuity, enabled: false)
    assert %{"token" => _} = conn |> post(~p"/api/participants", %{}) |> json_response(201)

    assert conn |> get(~p"/auth/google/start?mode=login") |> json_response(404) == %{
             "error" => %{"reason" => "google_continuity_disabled"}
           }

    assert conn |> get(~p"/api/account/session") |> json_response(200) == %{
             "available" => false,
             "connected" => false
           }
  end

  test "OAuth attempt stores hashes, expires, and is single use" do
    participant = participant()

    assert {:ok, attempt, state, nonce} =
             Accounts.start_oauth("LINK_CURRENT_GUEST", participant.participant_id)

    refute attempt.state_hash == state
    refute attempt.nonce_hash == nonce
    assert {:ok, consumed} = Accounts.consume_oauth(state)
    assert consumed.consumed_at
    assert {:error, :state_replayed} = Accounts.consume_oauth(state)

    {:ok, expired, expired_state, _} =
      Accounts.start_oauth("LINK_CURRENT_GUEST", participant.participant_id)

    expired
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :state_expired} = Accounts.consume_oauth(expired_state)
  end

  test "subject HMAC is deterministic and never stores the raw subject" do
    assert TokenCrypto.subject_hash("one") == TokenCrypto.subject_hash("one")
    refute TokenCrypto.subject_hash("one") == TokenCrypto.subject_hash("two")
    result = link_participant(participant(), "one")
    link = Repo.one!(GoogleAccountLink)
    refute link.provider_subject_hash == "one"
    refute inspect(link) =~ "one"
    assert result.account.participant_id
  end

  test "new link preserves participant, encrypts refresh token, and persists no profile or access token" do
    participant = participant()
    result = link_participant(participant, "private-sub")
    assert result.account.participant_id == participant.participant_id
    assert Repo.aggregate(Participant, :count, :participant_id) == 1
    link = Repo.one!(GoogleAccountLink)
    refute link.encrypted_refresh_token == "refresh-secret"
    assert TokenCrypto.decrypt_refresh_token(link) == "refresh-secret"
    columns = GoogleAccountLink.__schema__(:fields)
    refute Enum.any?([:email, :name, :photo, :access_token], &(&1 in columns))
  end

  test "returning login restores the participant without duplicates and preserves an old refresh token" do
    participant = participant()
    first = link_participant(participant, "returning")
    old_ciphertext = Repo.one!(GoogleAccountLink).encrypted_refresh_token
    {:ok, _attempt, state, _nonce} = Accounts.start_oauth("SIGN_IN_EXISTING", nil)
    {:ok, attempt} = Accounts.consume_oauth(state)

    assert {:ok, second} =
             Accounts.complete_oauth(attempt, %{
               subject: "returning",
               refresh_token: nil,
               access_token: "never-stored",
               scopes: ["openid"]
             })

    assert second.account.participant_id == first.account.participant_id
    assert Repo.aggregate(Participant, :count, :participant_id) == 1
    assert Repo.aggregate(PrivateAccount, :count, :account_id) == 1
    assert Repo.one!(GoogleAccountLink).encrypted_refresh_token == old_ciphertext
    assert Repo.aggregate(AccountSession, :count, :account_session_id) == 2
  end

  test "link conflict never merges two participants" do
    first = participant()
    second = participant()
    link_participant(first, "claimed")
    {:ok, _attempt, state, _} = Accounts.start_oauth("LINK_CURRENT_GUEST", second.participant_id)
    {:ok, attempt} = Accounts.consume_oauth(state)

    assert {:error, :existing_account_available} =
             Accounts.complete_oauth(attempt, %{
               subject: "claimed",
               refresh_token: "other",
               access_token: "ephemeral",
               scopes: []
             })

    assert Repo.aggregate(Participant, :count, :participant_id) == 2
    assert Repo.aggregate(PrivateAccount, :count, :account_id) == 1
  end

  test "HTTP link sets a private account cookie and session API exposes no Google identity", %{
    conn: conn
  } do
    participant = participant()
    token = ParticipantToken.sign(participant.participant_id)

    started =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/auth/google/start?mode=link")

    [location] = get_resp_header(started, "location")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    Application.put_env(:strangertalks_new, :fake_google_result, %{
      subject: "http-sub",
      refresh_token: "refresh-secret",
      access_token: "ephemeral",
      scopes: ["openid"],
      expected_nonce: query["nonce"]
    })

    callback =
      started |> recycle() |> get(~p"/auth/google/callback?state=#{query["state"]}&code=valid")

    account_cookie = callback.resp_cookies["strangertalks_account"]
    assert account_cookie.http_only
    assert account_cookie.same_site == "Lax"
    assert account_cookie.value
    refute Repo.one!(AccountSession).session_token_hash == account_cookie.value
    response = callback |> recycle() |> get(~p"/api/account/session") |> json_response(200)
    assert response["connected"]
    assert response["participant_id"] == participant.participant_id
    refute Map.has_key?(response, "email")
    refute inspect(response) =~ "http-sub"
  end

  test "current logout, all-device logout, and disconnect have separate effects" do
    participant = participant()
    first = link_participant(participant, "logout")
    {:ok, _attempt, state, _} = Accounts.start_oauth("SIGN_IN_EXISTING", nil)
    {:ok, attempt} = Accounts.consume_oauth(state)

    {:ok, second} =
      Accounts.complete_oauth(attempt, %{
        subject: "logout",
        refresh_token: nil,
        access_token: "ephemeral",
        scopes: []
      })

    assert {:ok, _} = Accounts.revoke_session(first.session)
    assert {:error, :invalid_session} = Accounts.authenticate_session(first.raw_token)
    assert {:ok, _} = Accounts.authenticate_session(second.raw_token)
    assert :ok = Accounts.disconnect(second.session)
    assert {:error, :invalid_session} = Accounts.authenticate_session(second.raw_token)
    link = Repo.one!(GoogleAccountLink)
    assert link.revoked_at
    assert is_nil(link.encrypted_refresh_token)
  end

  test "refresh token encryption rejects ciphertext, tag, IV, AAD and version tampering" do
    link_participant(participant(), "tamper")
    link = Repo.one!(GoogleAccountLink)

    for field <- [:encrypted_refresh_token, :refresh_token_tag, :refresh_token_iv] do
      changed =
        Map.update!(link, field, fn <<byte, rest::binary>> ->
          <<Bitwise.bxor(byte, 1), rest::binary>>
        end)

      assert :error == TokenCrypto.decrypt_refresh_token(changed)
    end

    assert :error == TokenCrypto.decrypt_refresh_token(%{link | account_id: Ecto.UUID.generate()})

    assert :error ==
             TokenCrypto.decrypt_refresh_token(%{
               link
               | google_account_link_id: Ecto.UUID.generate()
             })

    assert :error == TokenCrypto.decrypt_refresh_token(%{link | token_key_version: 2})

    other = link_participant(participant(), "other-row")
    other_link = Repo.get_by!(GoogleAccountLink, account_id: other.account.account_id)

    swapped = %{
      other_link
      | encrypted_refresh_token: link.encrypted_refresh_token,
        refresh_token_iv: link.refresh_token_iv,
        refresh_token_tag: link.refresh_token_tag,
        token_key_version: link.token_key_version
    }

    assert :error == TokenCrypto.decrypt_refresh_token(swapped)
  end

  test "revoked subject requires reauthorization for login and owner can relink the same row" do
    owner = participant()
    result = link_participant(owner, "relink")
    link_id = Repo.one!(GoogleAccountLink).google_account_link_id
    assert :ok = Accounts.disconnect(result.session)

    {:ok, _, state, _} = Accounts.start_oauth("SIGN_IN_EXISTING", nil)
    {:ok, attempt} = Accounts.consume_oauth(state)

    assert {:error, :google_reauthorization_required} =
             Accounts.complete_oauth(attempt, %{
               subject: "relink",
               refresh_token: "new",
               scopes: []
             })

    {:ok, _, state, _} = Accounts.start_oauth("LINK_CURRENT_GUEST", owner.participant_id)
    {:ok, attempt} = Accounts.consume_oauth(state)

    assert {:ok, _} =
             Accounts.complete_oauth(attempt, %{
               subject: "relink",
               refresh_token: "new",
               scopes: []
             })

    assert Repo.aggregate(GoogleAccountLink, :count, :google_account_link_id) == 1
    assert Repo.one!(GoogleAccountLink).google_account_link_id == link_id
    assert is_nil(Repo.one!(GoogleAccountLink).revoked_at)
  end

  test "disconnect preserves credentials and sessions when provider revocation is unresolved" do
    result = link_participant(participant(), "retry-disconnect")
    link = Repo.one!(GoogleAccountLink)
    Application.put_env(:strangertalks_new, :fake_revoke_result, {:error, :revocation_failed})
    assert {:error, :google_revocation_failed} = Accounts.disconnect(result.session)
    assert Repo.one!(GoogleAccountLink).encrypted_refresh_token == link.encrypted_refresh_token
    assert {:ok, _} = Accounts.authenticate_session(result.raw_token)
  end

  test "cookie account mutations require the session-specific CSRF token", %{conn: conn} do
    result = link_participant(participant(), "csrf")
    conn = put_req_cookie(conn, "strangertalks_account", result.raw_token)
    session_body = conn |> get(~p"/api/account/session") |> json_response(200)

    assert conn |> recycle() |> delete(~p"/api/account/sessions") |> json_response(403) == %{
             "error" => %{"reason" => "forbidden"}
           }

    assert conn
           |> recycle()
           |> put_req_header("x-strangertalks-csrf", "wrong")
           |> delete(~p"/api/account/sessions")
           |> json_response(403) == %{"error" => %{"reason" => "forbidden"}}

    valid =
      conn
      |> recycle()
      |> put_req_header("x-strangertalks-csrf", session_body["csrf_token"])
      |> delete(~p"/api/account/sessions")

    assert response(valid, 204)
  end

  defp participant do
    {:ok, participant} =
      Participants.create_participant(%{
        created_at: DateTime.utc_now(),
        last_active_at: DateTime.utc_now()
      })

    participant
  end

  defp link_participant(participant, subject) do
    {:ok, _attempt, state, _nonce} =
      Accounts.start_oauth("LINK_CURRENT_GUEST", participant.participant_id)

    {:ok, attempt} = Accounts.consume_oauth(state)

    {:ok, result} =
      Accounts.complete_oauth(attempt, %{
        subject: subject,
        refresh_token: "refresh-secret",
        access_token: "ephemeral",
        scopes: ["openid", "https://www.googleapis.com/auth/drive.appdata"]
      })

    result
  end
end
