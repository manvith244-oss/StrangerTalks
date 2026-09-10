defmodule StrangertalksNewWeb.LivingThreadControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.LivingThreads.ExperimentAssignment
  alias StrangertalksNew.{Participants, Repo}
  alias StrangertalksNewWeb.ParticipantToken

  test "pilot API requires a signed participant token", %{conn: conn} do
    assert %{"error" => "invalid_token"} =
             conn
             |> get("/api/living-thread")
             |> json_response(401)
  end

  test "consequence participant can create one load-bearing seed and inspect its state", %{
    conn: conn
  } do
    participant = participant!()
    assign!(participant, :CONSEQUENCE_A)
    token = ParticipantToken.sign(participant.participant_id)

    created =
      conn
      |> auth(token)
      |> post("/api/living-thread/start", %{"body" => "Leave the last light on."})
      |> json_response(201)

    assert created["status"] == "WAITING_FOR_B"
    assert is_binary(created["thread_id"])
    refute Map.has_key?(created, "starter_participant_id")

    state =
      recycle(conn)
      |> auth(token)
      |> get("/api/living-thread")
      |> json_response(200)

    assert state["role"] == "CONSEQUENCE_A"
    assert state["status"] == "WAITING_FOR_B"
    assert state["your_contribution"] == "Leave the last light on."
    refute Map.has_key?(state, "continuation")
  end

  test "wrong pilot role cannot mutate consequence state", %{conn: conn} do
    participant = participant!()
    assign!(participant, :SPECTATOR_A)
    token = ParticipantToken.sign(participant.participant_id)

    assert %{"error" => "wrong_role"} =
             conn
             |> auth(token)
             |> post("/api/living-thread/start", %{"body" => "not allowed"})
             |> json_response(403)
  end

  test "carrier endpoint never accepts participant identity from request body", %{conn: conn} do
    a = participant!()
    b = participant!()
    attacker = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(b, :CARRIER_B)
    assign!(attacker, :CARRIER_B)

    a_token = ParticipantToken.sign(a.participant_id)
    b_token = ParticipantToken.sign(b.participant_id)

    assert _created =
             conn
             |> auth(a_token)
             |> post("/api/living-thread/start", %{"body" => "seed"})
             |> json_response(201)

    continued =
      recycle(conn)
      |> auth(b_token)
      |> post("/api/living-thread/continue", %{
        "body" => "carried by authenticated B",
        "participant_id" => attacker.participant_id
      })
      |> json_response(200)

    assert continued["status"] == "CONTINUED"
    refute Map.has_key?(continued, "carrier_participant_id")
    refute Map.has_key?(continued, "starter_participant_id")
  end

  test "pilot page is isolated and directly reachable", %{conn: conn} do
    body = conn |> get("/living-thread") |> html_response(200)

    assert body =~ "Something is unfolding"
    assert body =~ "/assets/living_thread_pilot.mjs"
    refute body =~ "Consequence Thread"
    refute body =~ "causal pocket"
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp assign!(participant, role) do
    %ExperimentAssignment{}
    |> ExperimentAssignment.changeset(
      %{role: role, assigned_at: DateTime.utc_now()},
      participant.participant_id
    )
    |> Repo.insert!()
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
