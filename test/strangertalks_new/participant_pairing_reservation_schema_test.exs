defmodule StrangertalksNew.ParticipantPairingReservationSchemaTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias StrangertalksNew.{Matches, Participant, Repo}

  setup do
    StrangertalksNew.PairingTestIsolation.install!()
  end

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
    unboxed(fn ->
      {participant_a, _participant_b, _participant_c, match_1, match_2} = two_matches()
      acquired_at = DateTime.utc_now()

      insert_reservation!(match_1.match_id, participant_a.participant_id, acquired_at)

      assert {:error, %Postgrex.Error{postgres: postgres}} =
               raw_insert_reservation(
                 match_2.match_id,
                 participant_a.participant_id,
                 acquired_at
               )

      assert postgres.code == :unique_violation
      assert postgres.pg_code == "23505"
      assert postgres.constraint == "participant_pairing_reservations_active_participant_index"

      IO.puts(
        "SCHEMA-01 PASS duplicate-active sqlstate=#{postgres.pg_code} constraint=#{postgres.constraint}"
      )
    end)
  end

  test "primary key rejects duplicate match and participant pair" do
    unboxed(fn ->
      {participant_a, _participant_b, _participant_c, match_1, _match_2} = two_matches()
      acquired_at = DateTime.utc_now()

      insert_reservation!(match_1.match_id, participant_a.participant_id, acquired_at)

      assert {:error, %Postgrex.Error{postgres: postgres}} =
               raw_insert_reservation(
                 match_1.match_id,
                 participant_a.participant_id,
                 acquired_at,
                 acquired_at
               )

      assert postgres.code == :unique_violation
      assert postgres.pg_code == "23505"
      assert postgres.constraint == "participant_pairing_reservations_pkey"

      IO.puts(
        "SCHEMA-02 PASS duplicate-pk sqlstate=#{postgres.pg_code} constraint=#{postgres.constraint}"
      )
    end)
  end

  test "released history coexists with one active row for a participant" do
    unboxed(fn ->
      {participant_a, _participant_b, _participant_c, match_1, match_2} = two_matches()
      acquired_at = DateTime.utc_now()
      released_at = DateTime.add(acquired_at, 1, :second)

      insert_reservation!(
        match_1.match_id,
        participant_a.participant_id,
        acquired_at,
        released_at
      )

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
    end)
  end

  test "temporal check rejects release before acquisition" do
    unboxed(fn ->
      {participant_a, _participant_b, _participant_c, match_1, _match_2} = two_matches()
      acquired_at = DateTime.utc_now()
      released_at = DateTime.add(acquired_at, -1, :second)

      assert {:error, %Postgrex.Error{postgres: postgres}} =
               raw_insert_reservation(
                 match_1.match_id,
                 participant_a.participant_id,
                 acquired_at,
                 released_at
               )

      assert postgres.code == :check_violation
      assert postgres.pg_code == "23514"

      assert postgres.constraint ==
               "participant_pairing_reservations_released_after_acquired_check"

      IO.puts(
        "SCHEMA-04 PASS temporal-check sqlstate=#{postgres.pg_code} constraint=#{postgres.constraint}"
      )
    end)
  end

  test "both reservation foreign keys reject nonexistent parents" do
    unboxed(fn ->
      {participant_a, _participant_b, _participant_c, match_1, _match_2} = two_matches()
      acquired_at = DateTime.utc_now()
      missing_match_id = Ecto.UUID.generate()
      missing_participant_id = Ecto.UUID.generate()

      assert {:error, %Postgrex.Error{postgres: match_fk}} =
               raw_insert_reservation(
                 missing_match_id,
                 participant_a.participant_id,
                 acquired_at
               )

      assert match_fk.code == :foreign_key_violation
      assert match_fk.pg_code == "23503"
      assert match_fk.constraint == "participant_pairing_reservations_match_id_fkey"

      assert {:error, %Postgrex.Error{postgres: participant_fk}} =
               raw_insert_reservation(
                 match_1.match_id,
                 missing_participant_id,
                 acquired_at
               )

      assert participant_fk.code == :foreign_key_violation
      assert participant_fk.pg_code == "23503"

      assert participant_fk.constraint ==
               "participant_pairing_reservations_participant_id_fkey"

      IO.puts(
        "SCHEMA-05 PASS foreign-keys match_sqlstate=#{match_fk.pg_code} match_constraint=#{match_fk.constraint} participant_sqlstate=#{participant_fk.pg_code} participant_constraint=#{participant_fk.constraint}"
      )
    end)
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(Repo, fun)
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
    Repo.insert!(%Reservation{
      match_id: match_id,
      participant_id: participant_id,
      acquired_at: acquired_at,
      released_at: released_at
    })
  end

  defp raw_insert_reservation(match_id, participant_id, acquired_at, released_at \\ nil) do
    Repo.query(
      "INSERT INTO participant_pairing_reservations (match_id, participant_id, acquired_at, released_at) VALUES ($1, $2, $3, $4)",
      [
        dump_uuid!(match_id),
        dump_uuid!(participant_id),
        DateTime.to_naive(acquired_at),
        released_at && DateTime.to_naive(released_at)
      ]
    )
  end

  defp dump_uuid!(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)
    dumped
  end
end
