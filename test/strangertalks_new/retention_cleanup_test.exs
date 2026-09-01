defmodule StrangertalksNew.RetentionCleanupTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.RetentionCleanup

  @now ~U[2026-08-26 12:00:00.000000Z]

  test "29-day safety media remains" do
    created_at = DateTime.add(@now, -29 * 86_400, :second)
    assert RetentionCleanup.safety_media_disposition(created_at, false, @now) == :retain
  end

  test "30-day eligible safety media expires" do
    created_at = DateTime.add(@now, -30 * 86_400, :second)
    assert RetentionCleanup.safety_media_disposition(created_at, false, @now) == :delete
  end

  test "active human review explicitly extends safety media after day 30" do
    created_at = DateTime.add(@now, -45 * 86_400, :second)
    assert RetentionCleanup.safety_media_disposition(created_at, true, @now) == :retain
  end

  test "active review can never extend safety media beyond the 60-day hard maximum" do
    created_at = DateTime.add(@now, -60 * 86_400, :second)
    assert RetentionCleanup.safety_media_disposition(created_at, true, @now) == :delete
  end

  test "active/recoverable Conversation statuses are never terminal-retention eligible" do
    old = DateTime.add(@now, -365 * 86_400, :second)

    for status <- [:PENDING, :ACTIVE, :PAUSED] do
      refute RetentionCleanup.terminal_conversation_expired?(status, old, @now)
    end
  end

  test "terminal Conversation becomes retention eligible at the 30-day boundary" do
    at_boundary = DateTime.add(@now, -30 * 86_400, :second)
    before_boundary = DateTime.add(@now, -(30 * 86_400 - 1), :second)

    assert RetentionCleanup.terminal_conversation_expired?(:ENDED, at_boundary, @now)
    refute RetentionCleanup.terminal_conversation_expired?(:ENDED, before_boundary, @now)
  end

  test "terminal Match becomes retention eligible at the 30-day boundary" do
    at_boundary = DateTime.add(@now, -30 * 86_400, :second)

    assert RetentionCleanup.terminal_match_expired?(:ENDED, at_boundary, @now)
    assert RetentionCleanup.terminal_match_expired?(:FAILED, at_boundary, @now)
    assert RetentionCleanup.terminal_match_expired?(:EXPIRED, at_boundary, @now)
    refute RetentionCleanup.terminal_match_expired?(:ACTIVE, at_boundary, @now)
  end

  test "operational records become physically eligible after the approved 24-hour grace" do
    at_boundary = DateTime.add(@now, -24 * 3_600, :second)
    before_boundary = DateTime.add(@now, -(24 * 3_600 - 1), :second)

    assert RetentionCleanup.operational_record_expired?(at_boundary, @now)
    refute RetentionCleanup.operational_record_expired?(before_boundary, @now)
  end

  test "deleted Memory becomes hard-purge eligible after seven days" do
    at_boundary = DateTime.add(@now, -7 * 86_400, :second)
    assert RetentionCleanup.deleted_memory_expired?(at_boundary, @now)
    refute RetentionCleanup.deleted_memory_expired?(nil, @now)
  end

  test "analytics older than the 90-day rolling window is eligible" do
    at_boundary = DateTime.add(@now, -90 * 86_400, :second)
    assert RetentionCleanup.analytics_expired?(at_boundary, @now)
  end

  test "cleanup executed twice is safe for an already-empty task" do
    task = {:empty, fn -> {:ok, 0} end}
    assert %{empty: {:ok, 0}} = RetentionCleanup.run_tasks([task])
    assert %{empty: {:ok, 0}} = RetentionCleanup.run_tasks([task])
  end

  test "one category failure does not prevent an independent category from completing" do
    tasks = [
      {:broken, fn -> raise "forced retention category failure" end},
      {:healthy, fn -> {:ok, 3} end}
    ]

    result = RetentionCleanup.run_tasks(tasks)

    assert {:error, {:exception, %RuntimeError{message: "forced retention category failure"}}} =
             result.broken

    assert result.healthy == {:ok, 3}
  end
end
