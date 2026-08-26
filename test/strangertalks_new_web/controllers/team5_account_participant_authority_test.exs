defmodule StrangertalksNewWeb.Team5AccountParticipantAuthorityTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Accounts
  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.ParticipantToken

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
end
