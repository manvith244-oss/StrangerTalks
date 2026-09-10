defmodule StrangertalksNewWeb.LivingThreadController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.LivingThreads
  alias StrangertalksNewWeb.ParticipantToken

  def show(conn, _params) do
    with {:ok, participant_id} <- authenticate(conn),
         {:ok, experience} <- LivingThreads.experience_for(participant_id) do
      json(conn, wire_experience(experience))
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def start(conn, %{"body" => body}) do
    with {:ok, participant_id} <- authenticate(conn),
         {:ok, thread} <- LivingThreads.start_thread(participant_id, body) do
      conn
      |> put_status(:created)
      |> json(%{
        thread_id: thread.thread_id,
        status: thread.status,
        continuation_deadline_at: thread.continuation_deadline_at,
        resolves_at: thread.resolves_at
      })
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def start(conn, _params), do: error_response(conn, :invalid_body)

  def continue(conn, %{"body" => body}) do
    with {:ok, participant_id} <- authenticate(conn),
         {:ok, thread} <- LivingThreads.continue_next(participant_id, body) do
      json(conn, %{
        thread_id: thread.thread_id,
        status: thread.status,
        resolves_at: thread.resolves_at,
        time_remaining_at_continuation_seconds: thread.time_remaining_at_continuation_seconds
      })
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def continue(conn, _params), do: error_response(conn, :invalid_body)

  def debrief(conn, %{"answer" => answer} = params) do
    reason = Map.get(params, "reason")

    with {:ok, participant_id} <- authenticate(conn),
         {:ok, :recorded} <-
           LivingThreads.record_known_person_debrief(participant_id, answer, reason) do
      json(conn, %{status: "recorded"})
    else
      {:error, error} -> error_response(conn, error)
    end
  end

  def debrief(conn, _params), do: error_response(conn, :invalid_debrief)

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token when byte_size(token) > 0 <- String.trim(token),
         {:ok, participant_id} <- ParticipantToken.verify(token) do
      {:ok, participant_id}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp wire_experience(experience) do
    experience
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key, wire_value(value))
    end)
  end

  defp wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_value(value), do: value

  defp error_response(conn, reason) do
    {status, public_reason} =
      case reason do
        :invalid_token -> {:unauthorized, "invalid_token"}
        :wrong_role -> {:forbidden, "wrong_role"}
        :invalid_body -> {:unprocessable_entity, "invalid_body"}
        :invalid_thread_input -> {:unprocessable_entity, "invalid_body"}
        :invalid_continuation_input -> {:unprocessable_entity, "invalid_body"}
        :thread_already_exists -> {:conflict, "thread_already_exists"}
        :carrier_already_used -> {:conflict, "carrier_already_used"}
        :no_waiting_thread -> {:conflict, "no_waiting_thread"}
        :thread_not_found -> {:not_found, "thread_not_found"}
        :thread_not_resolved -> {:conflict, "thread_not_resolved"}
        :invalid_debrief -> {:unprocessable_entity, "invalid_debrief"}
        :invalid_participant -> {:unauthorized, "invalid_token"}
        _ -> {:unprocessable_entity, "pilot_request_failed"}
      end

    conn
    |> put_status(status)
    |> json(%{error: public_reason})
  end
end
