defmodule StrangertalksNewWeb.ReflectionController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Reflections
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.{ParticipantToken, ReflectionJSON}

  def index(conn, _params) do
    with {:ok, participant_id} <- authenticate(conn) do
      reflections = Reflections.list_reflections(participant_id)
      json(conn, ReflectionJSON.index(%{reflections: reflections}))
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  def create_grant(conn, params) do
    with {:ok, participant_id} <- authenticate(conn),
         conversation_id when is_binary(conversation_id) <-
           params["source_conversation_id"] || params["conversation_id"],
         client_message_id when is_binary(client_message_id) <-
           params["source_client_message_id"] || params["client_message_id"],
         expected_revision when is_integer(expected_revision) <-
           params["expected_source_revision"] || params["expected_revision"],
         start_grapheme when is_integer(start_grapheme) and start_grapheme >= 0 <-
           params["selection_start_grapheme"] || params["start_grapheme"],
         end_grapheme when is_integer(end_grapheme) and end_grapheme > start_grapheme <-
           params["selection_end_grapheme"] || params["end_grapheme"] do
      grant_params = %{
        source_conversation_id: conversation_id,
        source_client_message_id: client_message_id,
        expected_source_revision: expected_revision,
        selection_start_grapheme: start_grapheme,
        selection_end_grapheme: end_grapheme
      }

      case ConversationServer.open_composer_grant(conversation_id, participant_id, grant_params) do
        {:ok, grant_info} ->
          conn
          |> put_status(:created)
          |> json(grant_info)

        {:error, :stale} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: %{reason: "stale_source"}})

        {:error, :target_absent} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{reason: "source_absent"}})

        {:error, :invalid_request} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: %{reason: "invalid_request"}})

        {:error, :conversation_inactive} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: %{reason: "conversation_inactive"}})

        {:error, _reason} ->
          case Reflections.open_composer_grant(participant_id, grant_params) do
            {:ok, %{grant: grant, raw_secret: raw_secret}} ->
              conn
              |> put_status(:created)
              |> json(%{
                grant_id: grant.grant_id,
                raw_secret: raw_secret,
                state: grant.state
              })

            _ ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: %{reason: "invalid_grant_request"}})
          end
      end
    else
      {:error, :unauthorized} ->
        unauthorized(conn)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{reason: "invalid_request"}})
    end
  end

  def create(conn, params) do
    with {:ok, participant_id} <- authenticate(conn) do
      grant_id = params["grant_id"]
      conv_id = params["source_conversation_id"] || params["conversation_id"]

      cond do
        is_binary(grant_id) and is_binary(conv_id) ->
          # Active conversation save with grant
          case ConversationServer.save_reflection_with_source(conv_id, participant_id, params) do
            {:ok, {:applied, reflection}} ->
              conn
              |> put_status(:created)
              |> json(ReflectionJSON.show(%{status: "applied", reflection: reflection}))

            {:ok, {:already_canonical, reflection}} ->
              conn
              |> put_status(:ok)
              |> json(ReflectionJSON.show(%{status: "already_canonical", reflection: reflection}))

            {:error, :stale} ->
              conn
              |> put_status(:conflict)
              |> json(%{error: %{reason: "stale_source"}})

            {:error, :conflict} ->
              conn
              |> put_status(:conflict)
              |> json(%{error: %{reason: "create_conflict"}})

            {:error, :source_mismatch} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: %{reason: "source_mismatch"}})

            {:error, :conversation_inactive} ->
              # Conversation ended, attempt post-terminal grant consumption if eligible
              handle_post_terminal_fallback(conn, participant_id, params)

            {:error, reason} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: %{reason: to_string(reason)}})
          end

        is_binary(grant_id) ->
          # Post-terminal grant save
          handle_post_terminal_fallback(conn, participant_id, params)

        true ->
          # Reflection-only save (no source)
          case Reflections.create_reflection(participant_id, params) do
            {:ok, {:applied, reflection}} ->
              conn
              |> put_status(:created)
              |> json(ReflectionJSON.show(%{status: "applied", reflection: reflection}))

            {:ok, {:already_canonical, reflection}} ->
              conn
              |> put_status(:ok)
              |> json(ReflectionJSON.show(%{status: "already_canonical", reflection: reflection}))

            {:error, :conflict} ->
              conn
              |> put_status(:conflict)
              |> json(%{error: %{reason: "create_conflict"}})

            {:error, reason} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: %{reason: to_string(reason)}})
          end
      end
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  def update(conn, %{"id" => reflection_id} = params) do
    with {:ok, participant_id} <- authenticate(conn),
         expected_revision when is_integer(expected_revision) <- params["expected_revision"],
         note_text when is_binary(note_text) <- params["own_reflection_text"] do
      case Reflections.update_reflection(
             reflection_id,
             participant_id,
             expected_revision,
             note_text
           ) do
        {:ok, updated} ->
          json(conn, ReflectionJSON.show(%{reflection: updated}))

        {:error, :stale} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: %{reason: "stale_revision"}})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{reason: "not_found"}})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: %{reason: to_string(reason)}})
      end
    else
      {:error, :unauthorized} ->
        unauthorized(conn)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{reason: "invalid_request"}})
    end
  end

  def remove_excerpt(conn, %{"id" => reflection_id} = params) do
    with {:ok, participant_id} <- authenticate(conn),
         expected_revision when is_integer(expected_revision) <- params["expected_revision"] do
      case Reflections.remove_excerpt(reflection_id, participant_id, expected_revision) do
        {:ok, updated} ->
          json(conn, ReflectionJSON.show(%{reflection: updated}))

        {:error, :stale} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: %{reason: "stale_revision"}})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{reason: "not_found"}})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: %{reason: to_string(reason)}})
      end
    else
      {:error, :unauthorized} ->
        unauthorized(conn)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{reason: "invalid_request"}})
    end
  end

  def delete(conn, %{"id" => reflection_id} = params) do
    with {:ok, participant_id} <- authenticate(conn) do
      expected_revision = params["expected_revision"]

      case Reflections.delete_reflection(reflection_id, participant_id, expected_revision) do
        {:ok, :deleted} ->
          send_resp(conn, :no_content, "")

        {:error, :stale} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: %{reason: "stale_revision"}})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{reason: "not_found"}})
      end
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  def undo(conn, %{"id" => reflection_id}) do
    with {:ok, participant_id} <- authenticate(conn) do
      case Reflections.undo_create(reflection_id, participant_id) do
        {:ok, :undone} ->
          json(conn, %{status: "undone"})

        {:error, :undo_expired} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{reason: "undo_expired"}})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{reason: "not_found"}})
      end
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  # --- Helpers ---

  defp handle_post_terminal_fallback(conn, participant_id, params) do
    grant_id = params["grant_id"]
    grant_secret = params["grant_secret"]
    op_id = params["create_operation_id"]
    note_text = params["own_reflection_text"]
    candidate_excerpt = params["source_excerpt"]

    if not is_binary(grant_id) or not is_binary(grant_secret) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: %{reason: "invalid_grant_parameters"}})
    else
      case Reflections.consume_post_terminal_grant(
             grant_id,
             participant_id,
             grant_secret,
             op_id,
             note_text,
             candidate_excerpt
           ) do
        {:ok, {:applied, reflection}} ->
          conn
          |> put_status(:created)
          |> json(ReflectionJSON.show(%{status: "applied", reflection: reflection}))

        {:ok, {:already_canonical, reflection}} ->
          conn
          |> put_status(:ok)
          |> json(ReflectionJSON.show(%{status: "already_canonical", reflection: reflection}))

        {:error, :grant_expired} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{reason: "grant_expired"}})

        {:error, :source_mismatch} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{reason: "source_mismatch"}})

        {:error, :invalid_grant_secret} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: %{reason: "invalid_grant_secret"}})

        {:error, :grant_consumed} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: %{reason: "grant_consumed"}})

        {:error, :grant_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{reason: "grant_not_found"}})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: %{reason: to_string(reason)}})
      end
    end
  end

  defp authenticate(conn) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          String.trim(token)

        _ ->
          case get_req_header(conn, "x-participant-token") do
            [token] -> String.trim(token)
            _ -> nil
          end
      end

    case token do
      nil ->
        {:error, :unauthorized}

      tok ->
        case ParticipantToken.verify(tok) do
          {:ok, participant_id} -> {:ok, participant_id}
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{reason: "unauthorized"}})
  end
end
