defmodule StrangertalksNewWeb.Team5AccountParticipantAuthorityTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Accounts
  alias StrangertalksNew.{Participants, Repo}
  alias StrangertalksNewWeb.{Endpoint, ParticipantToken}

  setup do
    previous = Application.get_env(:strangertalks_new, :google_continuity)

    Application.put_env(:strangertalks_new, :google_continuity,
      enabled: true,
      client_id: "client",
      client_secret: "secret",
      redirect_uri: "http://localhost/auth/google/callback",
      subject_hmac_key: Base.encode64(:binary.copy(<<9>>, 32)),
      refresh_token_encryption_key: Base.encode64(:binary.copy(<<7>>, 32))
    )

    Application.put_env(:strangertalks_new, :account_cookie_secure, false)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:strangertalks_new, :google_continuity, previous),
        else: Application.delete_env(:strangertalks_new, :google_continuity)

      Application.delete_env(:strangertalks_new, :account_cookie_secure)
    end)

    :ok
  end

  test "linking continuity invalidates the pre-link guest participant token" do
    participant = participant()
    guest_token = ParticipantToken.sign(participant.participant_id)

    _result = link_participant(participant, "team5-guest-rotation")

    assert {:error, _reason} = ParticipantToken.verify(guest_token)
  end

  test "legacy pre-version guest token survives only until continuity is adopted" do
    participant = participant()

    legacy_token =
      Phoenix.Token.sign(Endpoint, ParticipantToken.salt(), participant.participant_id)

    assert {:ok, participant.participant_id} == ParticipantToken.verify(legacy_token)

    _result = link_participant(participant, "team5-legacy-rotation")

    assert {:error, _reason} = ParticipantToken.verify(legacy_token)
  end

  test "logout revokes the participant token issued by that account session", %{conn: conn} do
    participant = participant()
    result = link_participant(participant, "team5-session-revocation")

    conn = put_req_cookie(conn, "strangertalks_account", result.raw_token)
    session_body = conn |> get(~p"/api/account/session") |> json_response(200)
    connected_token = session_body["participant_token"]

    assert {:ok, participant.participant_id} == ParticipantToken.verify(connected_token)

    logout =
      conn
      |> recycle()
      |> put_req_header("x-strangertalks-csrf", session_body["csrf_token"])
      |> delete(~p"/api/account/session")

    assert response(logout, 204)
    assert {:error, _reason} = ParticipantToken.verify(connected_token)
  end

  test "single-device logout revokes only that session-bound participant credential", %{
    conn: conn
  } do
    participant = participant()
    first = link_participant(participant, "team5-two-sessions")
    second = sign_in_existing("team5-two-sessions")

    first_token = account_participant_token(first.raw_token)
    second_token = account_participant_token(second.raw_token)

    conn = put_req_cookie(conn, "strangertalks_account", first.raw_token)
    session_body = conn |> get(~p"/api/account/session") |> json_response(200)

    logout =
      conn
      |> recycle()
      |> put_req_header("x-strangertalks-csrf", session_body["csrf_token"])
      |> delete(~p"/api/account/session")

    assert response(logout, 204)
    assert {:error, _reason} = ParticipantToken.verify(first_token)
    assert {:ok, participant.participant_id} == ParticipantToken.verify(second_token)
  end

  test "logout-all revokes every session-bound participant credential", %{conn: conn} do
    participant = participant()
    first = link_participant(participant, "team5-logout-all")
    second = sign_in_existing("team5-logout-all")

    first_token = account_participant_token(first.raw_token)
    second_token = account_participant_token(second.raw_token)

    conn = put_req_cookie(conn, "strangertalks_account", first.raw_token)
    session_body = conn |> get(~p"/api/account/session") |> json_response(200)

    logout_all =
      conn
      |> recycle()
      |> put_req_header("x-strangertalks-csrf", session_body["csrf_token"])
      |> delete(~p"/api/account/sessions")

    assert response(logout_all, 204)
    assert {:error, _reason} = ParticipantToken.verify(first_token)
    assert {:error, _reason} = ParticipantToken.verify(second_token)
  end

  test "session expiry invalidates its session-bound participant credential" do
    participant = participant()
    result = link_participant(participant, "team5-expired-session")
    {:ok, account_session} = Accounts.authenticate_session(result.raw_token)
    connected_token = ParticipantToken.sign_account_session(account_session)

    account_session
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, _reason} = ParticipantToken.verify(connected_token)
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
        scopes: ["openid"]
      })

    result
  end

  defp sign_in_existing(subject) do
    {:ok, _attempt, state, _nonce} = Accounts.start_oauth("SIGN_IN_EXISTING", nil)
    {:ok, attempt} = Accounts.consume_oauth(state)

    {:ok, result} =
      Accounts.complete_oauth(attempt, %{
        subject: subject,
        refresh_token: nil,
        access_token: "ephemeral",
        scopes: ["openid"]
      })

    result
  end

  defp account_participant_token(raw_token) do
    {:ok, account_session} = Accounts.authenticate_session(raw_token)
    ParticipantToken.sign_account_session(account_session)
  end
end
