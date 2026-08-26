defmodule StrangertalksNewWeb.Team5ParticipantChannelTest do
  use StrangertalksNewWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias StrangertalksNew.Accounts
  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.{ParticipantToken, UserSocket}

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

  test "single-device logout disconnects only the revoked account-session socket", %{conn: conn} do
    participant = participant()
    first = link_participant(participant, "team5-socket-isolation")
    second = sign_in_existing("team5-socket-isolation")
    first_token = account_participant_token(first.raw_token)
    second_token = account_participant_token(second.raw_token)

    assert {:ok, first_socket} =
             connect(UserSocket, %{}, connect_info: %{auth_token: first_token})

    assert {:ok, second_socket} =
             connect(UserSocket, %{}, connect_info: %{auth_token: second_token})

    first_socket_id = UserSocket.id(first_socket)
    second_socket_id = UserSocket.id(second_socket)

    refute first_socket_id == second_socket_id

    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, first_socket_id)
    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, second_socket_id)

    conn = put_req_cookie(conn, "strangertalks_account", first.raw_token)
    session_body = conn |> get(~p"/api/account/session") |> json_response(200)

    logout =
      conn
      |> recycle()
      |> put_req_header("x-strangertalks-csrf", session_body["csrf_token"])
      |> delete(~p"/api/account/session")

    assert response(logout, 204)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^first_socket_id,
      event: "disconnect"
    }

    refute_receive %Phoenix.Socket.Broadcast{
                     topic: ^second_socket_id,
                     event: "disconnect"
                   },
                   100

    assert {:error, _reason} = ParticipantToken.verify(first_token)
    assert {:ok, participant.participant_id} == ParticipantToken.verify(second_token)
    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: first_token})

    assert {:ok, reconnected_second} =
             connect(UserSocket, %{}, connect_info: %{auth_token: second_token})

    assert UserSocket.id(reconnected_second) == second_socket_id
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
