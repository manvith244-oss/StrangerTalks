defmodule StrangertalksNew.ParticipantPairingReservationSchemaTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{Matches, Participant, Repo}

  defmodule Reservation do
    use Ecto.Schema

    @primary_key false
    schema "participant_pairing_reservations" do
      field :match_id, :binary_id, primary_key: true
      field :participant_id, :binary_id, primary_key: true
      field :acquired_at, :utc_datetime_usec
      field :released_at, :utc_datetime_usec
    end
  end

  test "duplicate active participant is rejected" do
    {participant_a, _participant_b, _participant_c, match_1, match_2} = two_matches()
    acquired_at = NaiveDateTime.utc_now()

    insert_reservation!(match_1.match_id, participant_a.participant_id, acquired_at)

    error =
      assert_raise Postgrex.Error, fn ->
        insert_reservation!(match_2.match_id, participant_a.participant_id, acquired_at)
      end

    assert error.postgres.code == :unique_violation
    assert error.postgres.pg_code == "23505"
    assert error.postgres.constraint == "participant_pairing_reservations_active_participant_index"

    IO.puts(
      "SCHEMA-01 PASS duplicate-active sqlstate=#{error.postgres.pg_code} constraint=#{error.postgres.constraint}"
    )
  end

  test "primary key rejects duplicate match and participant pair" do
    {participant_a, _participant_b, _participant_c, match_1, _match_2} = two_matches()
    acquired_at = NaiveDateTime.utc_now()

    insert_reservation!(match_1.match_id, participant_a.participant_id, acquired_at)

    error =
      assert_raise Postgrex.Error, fn ->
        insert_reservation!(
          match_1.match_id,
          participant_a.participant_id,
          acquired_at,
          acquired_at
        )
      end

    assert error.postgres.code == :unique_violation
    assert error.postgres.pg_code == "23505"
    assert error.postgres.constraint == "participant_pairing_reservations_pkey"

    IO.puts(
      "SCHEMA-02 PASS duplicate-pk sqlstate=#{error.postgres.pg_code} constraint=#{error.postgres.constraint}"
    )
  end

  test "released history coexists with one active row for a participant" do
    {participant_a, _participant_b, _participant_c, match_1, match_2} = two_matches()
    acquired_at = NaiveDateTime.utc_now()
    released_at = NaiveDateTime.add(acquired_at, 1, :second)

    insert_reservation!(match_1.match_id, participant_a.participant_id, acquired_at, released_at)
    insert_reservation!(match_2.match_id, participant_a.participant_id, released_at)

    rows =
      Reservation
      |> where([reservation], reservation.participant_id == ^participant_a.participant_id)
      |> Repo.all()

    history_count = Enum.count(rows, & &1.released_at)
    active_count = Enum.count(rows, &is_nil(&1.released_at))

    assert history_count == 1
    assert active_count == 1

    IO.puts(
      "SCHEMA-03 PASS released-history history_rows=#{history_count} active_rows=#{active_count}"
    )
  end

  test "temporal check rejects release before acquisition" do
    {participant_a, _participant_b, _participant_c, match_1, _match_2} = two_matches()
    acquired_at = NaiveDateTime.utc_now()
    released_at = NaiveDateTime.add(acquired_at, -1, :second)

    error =
      assert_raise Postgrex.Error, fn ->
        insert_reservation!(
          match_1.match_id,
          participant_a.participant_id,
          acquired_at,
          released_at
        )
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.pg_code == "23514"

    assert error.postgres.constraint ==
             "participant_pairing_reservations_released_after_acquired_check"

    IO.puts(
      "SCHEMA-04 PASS temporal-check sqlstate=#{error.postgres.pg_code} constraint=#{error.postgres.constraint}"
    )
  end

  test "both reservation foreign keys reject nonexistent parents" do
    {participant_a, _participant_b, _participant_c, match_1, _match_2} = two_matches()
    acquired_at = NaiveDateTime.utc_now()
    missing_match_id = Ecto.UUID.generate()
    missing_participant_id = Ecto.UUID.generate()

    Repo.query!("SAVEPOINT reservation_fk_match")

    assert {:error, %Postgrex.Error{postgres: match_fk}} =
             Repo.query(
               "INSERT INTO participant_pairing_reservations (match_id, participant_id, acquired_at) VALUES ($1, $2, $3)",
               [dump_uuid!(missing_match_id), dump_uuid!(participant_a.participant_id), acquired_at]
             )

    assert match_fk.code == :foreign_key_violation
    assert match_fk.pg_code == "23503"
    assert match_fk.constraint == "participant_pairing_reservations_match_id_fkey"
    Repo.query!("ROLLBACK TO SAVEPOINT reservation_fk_match")
    Repo.query!("RELEASE SAVEPOINT reservation_fk_match")

    Repo.query!("SAVEPOINT reservation_fk_participant")

    assert {:error, %Postgrex.Error{postgres: participant_fk}} =
             Repo.query(
               "INSERT INTO participant_pairing_reservations (match_id, participant_id, acquired_at) VALUES ($1, $2, $3)",
               [dump_uuid!(match_1.match_id), dump_uuid!(missing_participant_id), acquired_at]
             )

    assert participant_fk.code == :foreign_key_violation
    assert participant_fk.pg_code == "23503"
    assert participant_fk.constraint == "participant_pairing_reservations_participant_id_fkey"
    Repo.query!("ROLLBACK TO SAVEPOINT reservation_fk_participant")
    Repo.query!("RELEASE SAVEPOINT reservation_fk_participant")

    IO.puts(
      "SCHEMA-05 PASS foreign-keys match_sqlstate=#{match_fk.pg_code} match_constraint=#{match_fk.constraint} participant_sqlstate=#{participant_fk.pg_code} participant_constraint=#{participant_fk.constraint}"
    )
  end

  defp two_matches do
    now = DateTime.utc_now()
    participant_a = participant!(now)
    participant_b = participant!(now)
    participant_c = participant!(now)
    match_1 = match!(participant_a, participant_b, now)
    match_2 = match!(participant_a, participant_c, now)
    {participant_a, participant_b, participant_c, match_1, match_2}
  end

  defp participant!(now) do
    Repo.insert!(%Participant{last_active_at: now, created_at: now})
  end

  defp match!(participant_a, participant_b, now) do
    attrs = %{
      created_at: now,
      door_type: :JUST_TALK,
      conversation_language: "en",
      match_status: :CREATED,
      match_strategy: :COMPATIBILITY,
      participant_a_id: participant_a.participant_id,
      participant_b_id: participant_b.participant_id,
      compatibility_score: Decimal.new("0.5000"),
      opportunity_score: Decimal.new("0.0000"),
      scarcity_adjustment: Decimal.new("0.0000"),
      conversation_temperature: Decimal.new("0.0000"),
      mutual_participation_score: Decimal.new("0.0000"),
      conversation_health_score: Decimal.new("0.0000"),
      match_quality_score: Decimal.new("0.0000"),
      queue_entry_time: now,
      match_found_time: now,
      queue_duration_seconds: 0,
      conversation_duration_seconds: 0,
      conversation_started: false,
      conversation_completed: false,
      memory_created: false,
      relationship_created: false,
      reconnected_later: false,
      report_generated: false,
      block_generated: false,
      safety_review_required: false,
      learning_processed: false,
      learning_version: "schema-proof-v1"
    }

    {:ok, match} = Matches.create_match(attrs)
    match
  end

  defp insert_reservation!(match_id, participant_id, acquired_at, released_at \\ nil) do
    Repo.insert_all(Reservation, [
      %{
        match_id: match_id,
        participant_id: participant_id,
        acquired_at: acquired_at,
        released_at: released_at
      }
    ])
  end

  defp dump_uuid!(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)
    dumped
  end
end
