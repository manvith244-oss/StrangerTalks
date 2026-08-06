defmodule StrangertalksNew.Accounts do
  @moduledoc false
  import Ecto.Query

  alias Ecto.Multi

  alias StrangertalksNew.Accounts.{
    AccountSession,
    GoogleAccountLink,
    GoogleOauthAttempt,
    PrivateAccount
  }

  alias StrangertalksNew.GoogleContinuity.TokenCrypto
  alias StrangertalksNew.{AccountSyncLock, Repo}

  @session_seconds 30 * 24 * 60 * 60
  @oauth_seconds 10 * 60

  def start_oauth(mode, participant_id) when mode in ["LINK_CURRENT_GUEST", "SIGN_IN_EXISTING"] do
    state = random_token()
    nonce = random_token()
    now = now()

    attrs = %{
      oauth_attempt_id: Ecto.UUID.generate(),
      state_hash: hash(state),
      nonce_hash: hash(nonce),
      participant_id: participant_id,
      mode: mode,
      created_at: now,
      expires_at: DateTime.add(now, @oauth_seconds, :second)
    }

    with {:ok, attempt} <-
           %GoogleOauthAttempt{} |> Ecto.Changeset.cast(attrs, Map.keys(attrs)) |> Repo.insert() do
      {:ok, attempt, state, nonce}
    end
  end

  def consume_oauth(state) do
    state_hash = hash(state)
    now = now()

    Repo.transaction(fn ->
      attempt =
        Repo.one(
          from a in GoogleOauthAttempt, where: a.state_hash == ^state_hash, lock: "FOR UPDATE"
        )

      cond do
        is_nil(attempt) ->
          Repo.rollback(:invalid_state)

        not is_nil(attempt.consumed_at) ->
          Repo.rollback(:state_replayed)

        DateTime.compare(attempt.expires_at, now) != :gt ->
          Repo.rollback(:state_expired)

        true ->
          attempt
          |> Ecto.Changeset.change(consumed_at: now)
          |> Repo.update!()
      end
    end)
  end

  def complete_oauth(attempt, %{subject: subject} = provider_result) do
    subject_hash = TokenCrypto.subject_hash(subject)

    existing_link =
      Repo.one(
        from l in GoogleAccountLink,
          where: l.provider_subject_hash == ^subject_hash,
          preload: :account
      )

    case {attempt.mode, existing_link} do
      {"SIGN_IN_EXISTING", nil} ->
        {:error, :account_not_found}

      {"SIGN_IN_EXISTING", %{revoked_at: revoked_at}} when not is_nil(revoked_at) ->
        {:error, :google_reauthorization_required}

      {"SIGN_IN_EXISTING", link} ->
        sign_in_existing(link, provider_result)

      {"LINK_CURRENT_GUEST", nil} ->
        link_guest(attempt.participant_id, subject_hash, provider_result)

      {"LINK_CURRENT_GUEST", %{account: %{participant_id: participant_id}} = link}
      when participant_id == attempt.participant_id ->
        reactivate_or_sign_in(link, provider_result)

      {"LINK_CURRENT_GUEST", _link} ->
        {:error, :existing_account_available}
    end
  end

  def authenticate_session(raw_token) when is_binary(raw_token) do
    now = now()

    session =
      Repo.one(
        from s in AccountSession,
          where:
            s.session_token_hash == ^hash(raw_token) and is_nil(s.revoked_at) and
              s.expires_at > ^now,
          preload: :account
      )

    if session do
      session |> Ecto.Changeset.change(last_used_at: now) |> Repo.update()
      {:ok, session}
    else
      {:error, :invalid_session}
    end
  end

  def authenticate_session(_), do: {:error, :invalid_session}

  def revoke_session(%AccountSession{} = session),
    do: session |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update()

  def revoke_all_sessions(account_id) do
    Repo.update_all(
      from(s in AccountSession, where: s.account_id == ^account_id and is_nil(s.revoked_at)),
      set: [revoked_at: now()]
    )

    :ok
  end

  def disconnect(%AccountSession{account_id: account_id}) do
    AccountSyncLock.with_account(account_id, fn -> do_disconnect(account_id) end)
  end

  def active_link(account_id),
    do:
      Repo.one(
        from l in GoogleAccountLink, where: l.account_id == ^account_id and is_nil(l.revoked_at)
      )

  defp link_guest(nil, _hash, _result), do: {:error, :participant_required}

  defp link_guest(participant_id, subject_hash, result) do
    account_id = Ecto.UUID.generate()
    link_id = Ecto.UUID.generate()
    now = now()
    token_attrs = refresh_attrs(result[:refresh_token], link_id, account_id, %{})

    account_attrs = %{
      account_id: account_id,
      participant_id: participant_id,
      created_at: now,
      updated_at: now,
      last_signed_in_at: now
    }

    link_attrs =
      Map.merge(
        %{
          google_account_link_id: link_id,
          account_id: account_id,
          provider_subject_hash: subject_hash,
          granted_scopes: result[:scopes] || [],
          connected_at: now,
          created_at: now,
          updated_at: now
        },
        token_attrs
      )

    Multi.new()
    |> Multi.insert(
      :account,
      Ecto.Changeset.cast(%PrivateAccount{}, account_attrs, Map.keys(account_attrs))
    )
    |> Multi.insert(
      :link,
      Ecto.Changeset.cast(%GoogleAccountLink{}, link_attrs, Map.keys(link_attrs))
    )
    |> Multi.run(:session, fn repo, %{account: account} -> create_session(repo, account) end)
    |> Repo.transaction()
    |> normalize_result()
  end

  defp sign_in_existing(link, result) do
    now = now()

    token_attrs =
      refresh_attrs(result[:refresh_token], link.google_account_link_id, link.account_id, %{})

    Multi.new()
    |> Multi.update(
      :account,
      Ecto.Changeset.change(link.account, last_signed_in_at: now, updated_at: now)
    )
    |> Multi.update(
      :link,
      Ecto.Changeset.change(
        link,
        Map.merge(
          %{
            granted_scopes: result[:scopes] || link.granted_scopes,
            refreshed_at: now,
            updated_at: now
          },
          token_attrs
        )
      )
    )
    |> Multi.run(:session, fn repo, %{account: account} -> create_session(repo, account) end)
    |> Repo.transaction()
    |> normalize_result()
  end

  defp reactivate_or_sign_in(%GoogleAccountLink{revoked_at: nil} = link, result),
    do: sign_in_existing(link, result)

  defp reactivate_or_sign_in(link, %{refresh_token: token} = result) when is_binary(token) do
    now = now()
    token_attrs = refresh_attrs(token, link.google_account_link_id, link.account_id, %{})

    Multi.new()
    |> Multi.update(
      :account,
      Ecto.Changeset.change(link.account, last_signed_in_at: now, updated_at: now)
    )
    |> Multi.update(
      :link,
      Ecto.Changeset.change(
        link,
        Map.merge(token_attrs, %{
          granted_scopes: result[:scopes] || [],
          revoked_at: nil,
          connected_at: now,
          refreshed_at: now,
          updated_at: now
        })
      )
    )
    |> Multi.run(:session, fn repo, %{account: account} -> create_session(repo, account) end)
    |> Repo.transaction()
    |> normalize_result()
  end

  defp reactivate_or_sign_in(_link, _result), do: {:error, :google_reauthorization_required}

  defp do_disconnect(account_id) do
    link =
      Repo.one(
        from l in GoogleAccountLink, where: l.account_id == ^account_id and is_nil(l.revoked_at)
      )

    if is_nil(link) do
      :ok
    else
      with token when is_binary(token) <- TokenCrypto.decrypt_refresh_token(link),
           result when result in [:ok, :already_revoked] <-
             StrangertalksNew.GoogleContinuity.provider().revoke(token),
           {:ok, _} <- disconnect_transaction(link, account_id) do
        :ok
      else
        {:error, reason} when reason in [:revocation_failed, :provider_unavailable] ->
          {:error, :google_revocation_failed}

        error ->
          require Logger
          Logger.error("Google disconnect local persistence failed")
          {:error, {:disconnect_persistence_failed, error}}
      end
    end
  end

  defp disconnect_transaction(link, account_id) do
    now = now()

    Multi.new()
    |> Multi.update(
      :link,
      Ecto.Changeset.change(link,
        encrypted_refresh_token: nil,
        refresh_token_iv: nil,
        refresh_token_tag: nil,
        token_key_version: nil,
        revoked_at: now,
        updated_at: now
      )
    )
    |> Multi.update_all(
      :sessions,
      from(s in AccountSession, where: s.account_id == ^account_id and is_nil(s.revoked_at)),
      set: [revoked_at: now]
    )
    |> Repo.transaction()
  end

  defp create_session(repo, account) do
    raw = random_token()
    now = now()

    attrs = %{
      account_session_id: Ecto.UUID.generate(),
      account_id: account.account_id,
      session_token_hash: hash(raw),
      created_at: now,
      last_used_at: now,
      expires_at: DateTime.add(now, @session_seconds, :second)
    }

    case %AccountSession{} |> Ecto.Changeset.cast(attrs, Map.keys(attrs)) |> repo.insert() do
      {:ok, session} -> {:ok, %{session: session, raw_token: raw, account: account}}
      error -> error
    end
  end

  defp refresh_attrs(nil, _link_id, _account_id, fallback), do: fallback

  defp refresh_attrs(token, link_id, account_id, _fallback),
    do: TokenCrypto.encrypt_refresh_token(token, link_id, account_id)

  defp normalize_result({:ok, %{session: result}}), do: {:ok, result}
  defp normalize_result({:error, _step, reason, _changes}), do: {:error, reason}
  defp hash(value), do: :crypto.hash(:sha256, value)
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
