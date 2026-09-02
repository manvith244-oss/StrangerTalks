defmodule StrangertalksNew.ParticipantActivityLockTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.ParticipantActivityLock

  test "opposite participant order serializes one overlapping critical section" do
    parent = self()
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    first =
      Task.async(fn ->
        ParticipantActivityLock.with_participants([a, b], fn ->
          send(parent, :first_entered)

          receive do
            :release_first -> :first_done
          end
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        send(parent, :second_attempting)

        ParticipantActivityLock.with_participants([b, a], fn ->
          :second_done
        end)
      end)

    assert_receive :second_attempting
    assert Task.yield(second, 0) == nil
    send(first.pid, :release_first)
    assert Task.await(first) == :first_done
    assert Task.await(second) == :second_done
  end

  test "duplicate and equivalent UUID representations normalize to one participant lock" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    assert :entered_once =
             ParticipantActivityLock.with_participants(
               [String.upcase(a), a, b, String.upcase(b)],
               fn -> :entered_once end
             )
  end

  test "nested acquisition by the same owner is reentrant" do
    participant_id = Ecto.UUID.generate()

    assert :nested =
             ParticipantActivityLock.with_participants([participant_id], fn ->
               ParticipantActivityLock.with_participants([participant_id], fn -> :nested end)
             end)
  end
end
