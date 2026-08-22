defmodule StrangertalksNew.MatchingTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.Matching

  @valid_attrs %{
    created_at: DateTime.from_naive!(~N[2026-07-01 12:00:00.000000], "Etc/UTC"),
    door_type: :JUST_TALK,
    match_status: :CREATED,
    match_strategy: :COMPATIBILITY,
    participant_a_id: "00000000-0000-0000-0000-000000000001",
    participant_b_id: "00000000-0000-0000-0000-000000000002",
    # ✅ fixed
    compatibility_score: Decimal.new("0.9500"),
    # ✅ fixed
    opportunity_score: Decimal.new("0.8000"),
    # ✅ fixed
    scarcity_adjustment: Decimal.new("0.1000"),
    # ✅ fixed
    conversation_temperature: Decimal.new("0.5000"),
    # ✅ fixed
    mutual_participation_score: Decimal.new("0.7500"),
    # ✅ fixed
    conversation_health_score: Decimal.new("0.9000"),
    # ✅ fixed
    match_quality_score: Decimal.new("0.8800"),
    queue_entry_time: DateTime.from_naive!(~N[2026-07-01 11:58:00.000000], "Etc/UTC"),
    match_found_time: DateTime.from_naive!(~N[2026-07-01 12:00:00.000000], "Etc/UTC"),
    queue_duration_seconds: 120,
    conversation_duration_seconds: 0,
    conversation_started: false,
    conversation_completed: false,
    memory_created: false,
    relationship_created: false,
    reconnected_later: false,
    report_generated: false,
    block_generated: false,
    safety_review_required: false,
    learning_processed: false
  }

  test "changeset with valid attributes is valid" do
    changeset = Matching.changeset(%Matching{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset is invalid when required fields are missing" do
    changeset = Matching.changeset(%Matching{}, %{})
    refute changeset.valid?
    assert keyword_has_error?(changeset.errors, :participant_a_door_type, "can't be blank")
    assert keyword_has_error?(changeset.errors, :participant_b_door_type, "can't be blank")
  end

  test "changeset is invalid with unlisted enum value" do
    invalid_attrs = Map.put(@valid_attrs, :door_type, :INVALID_ENUM_VALUE)
    changeset = Matching.changeset(%Matching{}, invalid_attrs)
    refute changeset.valid?
    assert keyword_has_error?(changeset.errors, :door_type, "is invalid")
  end

  test "changeset accepts nullable future/ephemeral system fields as nil" do
    nullable_attrs =
      Map.merge(@valid_attrs, %{
        queue_id: nil,
        atmosphere_id: nil,
        icebreaker_id: nil,
        transition_experience_id: nil,
        failure_reason: nil,
        conversation_start_time: nil,
        match_end_time: nil
      })

    changeset = Matching.changeset(%Matching{}, nullable_attrs)
    assert changeset.valid?
  end

  defp keyword_has_error?(errors, field, expected_message) do
    Enum.any?(errors, fn {f, {msg, _}} -> f == field and msg == expected_message end)
  end
end
