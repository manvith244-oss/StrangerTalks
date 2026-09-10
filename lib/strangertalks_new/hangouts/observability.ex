defmodule StrangertalksNew.Hangouts.Observability do
  @moduledoc false

  import Ecto.Query

  alias StrangertalksNew.Hangouts.{HangoutMessage, HangoutRoom}
  alias StrangertalksNew.{Repo, Telemetry}

  def emit(event, measurements \\ %{}, metadata \\ %{}) when is_atom(event) do
    Telemetry.execute([:hangout, event], measurements, metadata)
  end

  def emit_room(room_id, event, measurements \\ %{}) when is_binary(room_id) do
    case Repo.get(HangoutRoom, room_id) do
      %HangoutRoom{} = room -> emit(event, measurements, metadata(room))
      nil -> :ok
    end
  end

  def metadata(%HangoutRoom{} = room) do
    %{
      experiment_arm: room.experiment_arm,
      room_status: room.status
    }
  end

  def duration_ms(%DateTime{} = later, %DateTime{} = earlier) do
    max(DateTime.diff(later, earlier, :millisecond), 0)
  end

  def duration_ms(_, _), do: 0

  def first_response_after_current_content?(%HangoutRoom{
        experiment_arm: :GROUP_WITH_CONTENT,
        current_content_started_at: %DateTime{} = started_at,
        room_id: room_id
      }) do
    Repo.aggregate(
      from(m in HangoutMessage,
        where: m.room_id == ^room_id and m.created_at >= ^started_at
      ),
      :count,
      :message_id
    ) == 1
  end

  def first_response_after_current_content?(_room), do: false

  def room_end_measurements(%HangoutRoom{} = room) do
    distinct_participant_count =
      Repo.one(
        from m in HangoutMessage,
          where: m.room_id == ^room.room_id,
          select: count(m.membership_id, :distinct)
      ) || 0

    %{
      count: 1,
      message_count: room.message_sequence,
      content_sequence: room.content_sequence,
      distinct_participant_count: distinct_participant_count,
      duration_ms: duration_ms(room.ended_at, room.activated_at)
    }
  end
end
