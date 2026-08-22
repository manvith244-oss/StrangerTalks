defmodule StrangertalksNewWeb.ParticipantControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Participant
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken

  require Phoenix.ChannelTest

  defmodule FailingParticipants do
    def create_participant(_attrs), do: {:error, :forced_failure}
  end

  test "POST /api/participants creates one participant and returns only its id and token", %{
    conn: conn
  } do
    supplied_id = Ecto.UUID.generate()

    conn = post(conn, ~p"/api/participants", %{participant_id: supplied_id})

    assert %{"participant_id" => participant_id, "token" => token} = json_response(conn, 201)
    assert Map.keys(json_response(conn, 201)) |> Enum.sort() == ["participant_id", "token"]
    assert {:ok, ^participant_id} = Ecto.UUID.cast(participant_id)
    refute participant_id == supplied_id
    assert Repo.aggregate(Participant, :count, :participant_id) == 1

    assert {:ok, ^participant_id} =
             Phoenix.Token.verify(
               StrangertalksNewWeb.Endpoint,
               ParticipantToken.salt(),
               token,
               max_age: ParticipantToken.max_age()
             )

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(StrangertalksNewWeb.UserSocket, %{},
               connect_info: %{auth_token: token}
             )

    assert socket.assigns.participant_id == participant_id
  end

  test "a participant creation failure returns a structured error and no token", %{conn: conn} do
    previous_context = Application.get_env(:strangertalks_new, :participants_context)
    Application.put_env(:strangertalks_new, :participants_context, FailingParticipants)

    on_exit(fn ->
      if previous_context do
        Application.put_env(:strangertalks_new, :participants_context, previous_context)
      else
        Application.delete_env(:strangertalks_new, :participants_context)
      end
    end)

    conn = post(conn, ~p"/api/participants", %{})

    assert %{"error" => %{"reason" => "participant_creation_failed"}} =
             json_response(conn, 422)

    refute get_resp_header(conn, "content-type") == []
    refute Map.has_key?(json_response(conn, 422), "token")
    assert Repo.aggregate(Participant, :count, :participant_id) == 0
  end
end
