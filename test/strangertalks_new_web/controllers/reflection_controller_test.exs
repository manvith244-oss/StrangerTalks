defmodule StrangertalksNewWeb.ReflectionControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Participants
  alias StrangertalksNew.Reflections
  alias StrangertalksNewWeb.ParticipantToken

  setup %{conn: conn} do
    {:ok, participant} = Participants.create_participant(%{})
    {:ok, peer} = Participants.create_participant(%{})
    token = ParticipantToken.sign(participant.participant_id)
    peer_token = ParticipantToken.sign(peer.participant_id)

    authed_conn = put_req_header(conn, "authorization", "Bearer " <> token)
    peer_conn = put_req_header(conn, "authorization", "Bearer " <> peer_token)

    {:ok,
     conn: conn,
     authed_conn: authed_conn,
     peer_conn: peer_conn,
     participant: participant,
     peer: peer}
  end

  describe "authentication & authorization" do
    test "returns 401 unauthorized without bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/reflections")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/reflections" do
    test "lists only reflections owned by current authenticated participant", %{
      authed_conn: authed_conn,
      peer_conn: peer_conn,
      participant: p,
      peer: peer
    } do
      {:ok, _} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Participant reflection 1"
        })

      {:ok, _} =
        Reflections.create_reflection(peer.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Peer reflection"
        })

      conn = get(authed_conn, ~p"/api/reflections")
      resp = json_response(conn, 200)

      assert length(resp["reflections"]) == 1
      assert hd(resp["reflections"])["own_reflection_text"] == "Participant reflection 1"

      peer_resp = json_response(get(peer_conn, ~p"/api/reflections"), 200)
      assert length(peer_resp["reflections"]) == 1
      assert hd(peer_resp["reflections"])["own_reflection_text"] == "Peer reflection"
    end
  end

  describe "POST /api/reflections" do
    test "creates a new reflection and returns 201", %{authed_conn: authed_conn} do
      op_id = Ecto.UUID.generate()

      payload = %{
        "create_operation_id" => op_id,
        "own_reflection_text" => "My beautiful reflection",
        "source_excerpt" => "Meaningful quote"
      }

      conn = post(authed_conn, ~p"/api/reflections", payload)
      resp = json_response(conn, 201)

      assert resp["reflection"]["own_reflection_text"] == "My beautiful reflection"
      assert resp["reflection"]["source_excerpt"] == "Meaningful quote"
      assert resp["reflection"]["revision"] == 1
      assert is_binary(resp["reflection"]["reflection_id"])

      # Idempotent retry returns 200
      retry_conn = post(authed_conn, ~p"/api/reflections", payload)
      retry_resp = json_response(retry_conn, 200)
      assert retry_resp["reflection"]["reflection_id"] == resp["reflection"]["reflection_id"]
    end

    test "rejects invalid note with 400", %{authed_conn: authed_conn} do
      conn =
        post(authed_conn, ~p"/api/reflections", %{
          "create_operation_id" => Ecto.UUID.generate(),
          "own_reflection_text" => ""
        })

      assert json_response(conn, 400)["error"]["reason"] == "blank_note"
    end
  end

  describe "POST /api/reflections/grants" do
    test "creates an open composer grant and returns raw secret", %{authed_conn: authed_conn} do
      payload = %{
        "source_conversation_id" => Ecto.UUID.generate(),
        "source_client_message_id" => "msg-123",
        "source_epoch_id" => Ecto.UUID.generate(),
        "selection_start_grapheme" => 0,
        "selection_end_grapheme" => 15,
        "expected_source_revision" => 0
      }

      conn = post(authed_conn, ~p"/api/reflections/grants", payload)
      resp = json_response(conn, 201)

      assert is_binary(resp["grant_id"])
      assert is_binary(resp["raw_secret"])
      assert resp["state"] == "OPEN"
    end
  end

  describe "PUT /api/reflections/:id" do
    test "updates note with matching revision CAS", %{
      authed_conn: authed_conn,
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Original note"
        })

      # Stale revision fails with 409
      stale_conn =
        put(authed_conn, ~p"/api/reflections/#{ref.reflection_id}", %{
          "expected_revision" => 99,
          "own_reflection_text" => "Stale edit"
        })

      assert json_response(stale_conn, 409)["error"]["reason"] == "stale_revision"

      # Valid update succeeds
      conn =
        put(authed_conn, ~p"/api/reflections/#{ref.reflection_id}", %{
          "expected_revision" => 1,
          "own_reflection_text" => "Updated note"
        })

      resp = json_response(conn, 200)
      assert resp["reflection"]["own_reflection_text"] == "Updated note"
      assert resp["reflection"]["revision"] == 2
    end
  end

  describe "POST /api/reflections/:id/remove-excerpt" do
    test "removes excerpt and increments revision", %{
      authed_conn: authed_conn,
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Note with excerpt",
          source_excerpt: "Some excerpt"
        })

      conn =
        post(authed_conn, ~p"/api/reflections/#{ref.reflection_id}/remove-excerpt", %{
          "expected_revision" => 1
        })

      resp = json_response(conn, 200)
      assert is_nil(resp["reflection"]["source_excerpt"])
      assert resp["reflection"]["revision"] == 2
    end
  end

  describe "DELETE /api/reflections/:id" do
    test "deletes reflection", %{
      authed_conn: authed_conn,
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Note to delete"
        })

      conn = delete(authed_conn, ~p"/api/reflections/#{ref.reflection_id}")
      assert response(conn, 204) == ""

      assert is_nil(Reflections.get_reflection(ref.reflection_id, p.participant_id))
    end
  end

  describe "POST /api/reflections/:id/undo" do
    test "hard-deletes reflection within 10-second undo window", %{
      authed_conn: authed_conn,
      participant: p
    } do
      {:ok, {:applied, ref}} =
        Reflections.create_reflection(p.participant_id, %{
          create_operation_id: Ecto.UUID.generate(),
          own_reflection_text: "Newly created note to undo"
        })

      conn = post(authed_conn, ~p"/api/reflections/#{ref.reflection_id}/undo")
      assert json_response(conn, 200)["status"] == "undone"

      assert is_nil(Reflections.get_reflection(ref.reflection_id, p.participant_id))
    end
  end
end
