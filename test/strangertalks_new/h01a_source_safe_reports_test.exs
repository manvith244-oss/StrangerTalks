defmodule StrangertalksNew.H01aSourceSafeReportsTest do
  use StrangertalksNew.DataCase, async: false
  alias StrangertalksNew.{Conversations, Matches, Messages, Participants, Repo, Report, Reports}

  @valid_time DateTime.from_naive!(~N[2026-07-03 14:41:44.000000], "Etc/UTC")

  setup do
    {:ok, participant_a} =
      Participants.create_participant(%{
        created_at: @valid_time
      })

    {:ok, participant_b} =
      Participants.create_participant(%{
        created_at: @valid_time
      })

    {:ok, match} =
      Matches.create_match(%{
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :SOMETHING_REAL,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: @valid_time,
        queue_entry_time: @valid_time,
        match_found_time: @valid_time,
        compatibility_score: "0.9500",
        opportunity_score: "0.8500",
        scarcity_adjustment: "0.0000",
        conversation_temperature: "0.5000",
        mutual_participation_score: "0.9000",
        conversation_health_score: "0.9200",
        match_quality_score: "0.9400",
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
        learning_processed: false
      })

    {:ok, conversation} =
      Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
        created_at: @valid_time,
        door_type: :SOMETHING_REAL,
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        participation_balance_score: "0.0000",
        message_exchange_rate: 0.0,
        conversation_depth_score: "0.0000",
        conversation_temperature: "0.5000",
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        bridge_effectiveness_score: "0.0000",
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        conversation_success_score: "0.0000",
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        safety_score: "0.0000",
        learning_processed: false,
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.conversation_id,
        sender_id: participant_b.participant_id,
        content: "Abusive Content",
        created_at: @valid_time,
        expected_sequence_id: 1
      })

    valid_attrs = %{
      created_at: @valid_time,
      updated_at: @valid_time,
      reporting_participant_id: participant_a.participant_id,
      reported_participant_id: participant_b.participant_id,
      conversation_id: conversation.conversation_id,
      reported_message_id: message.message_id,
      report_category: :HARASSMENT,
      report_status: :SUBMITTED,
      reporter_context: "Targeted language used in session."
    }

    {:ok,
     valid_attrs: valid_attrs,
     participant_a: participant_a,
     participant_b: participant_b,
     conversation: conversation,
     message: message}
  end

  describe "RED 1 — EXPLICIT SOURCE IDENTITY" do
    test "valid current shared report has source_kind == :CONVERSATION", %{valid_attrs: attrs} do
      assert {:ok, %Report{} = report} = Reports.create_report(attrs)
      assert Map.get(report, :source_kind) == :CONVERSATION
    end
  end

  describe "RED 2 — DB SOURCE CONTRACT" do
    test "inspect PostgreSQL metadata for public.reports source_kind and constraints" do
      # Assert source_kind column exists
      column_query = """
      SELECT data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'reports' AND column_name = 'source_kind'
      """

      assert [[data_type, is_nullable, column_default]] = Repo.query!(column_query).rows
      assert data_type in ["text", "character varying"]
      assert is_nullable == "NO"
      assert column_default =~ "CONVERSATION"

      # Assert named source-domain constraint exists
      domain_constraint_query = """
      SELECT pg_get_constraintdef(c.oid)
      FROM pg_constraint c
      JOIN pg_class t ON c.conrelid = t.oid
      JOIN pg_namespace n ON t.relnamespace = n.oid
      WHERE n.nspname = 'public' AND t.relname = 'reports' AND c.conname = 'reports_source_kind_check'
      """

      assert [[domain_def]] = Repo.query!(domain_constraint_query).rows
      assert domain_def =~ "CONVERSATION"
      assert domain_def =~ "HANGOUT"

      # Assert named H-01A source-authority gate exists
      gate_constraint_query = """
      SELECT pg_get_constraintdef(c.oid)
      FROM pg_constraint c
      JOIN pg_class t ON c.conrelid = t.oid
      JOIN pg_namespace n ON t.relnamespace = n.oid
      WHERE n.nspname = 'public' AND t.relname = 'reports' AND c.conname = 'reports_source_authority_check'
      """

      assert [[gate_def]] = Repo.query!(gate_constraint_query).rows
      assert gate_def =~ "CONVERSATION"
    end
  end

  describe "RED 3 — LEGACY INSERT SHAPE" do
    test "insert omitting source_kind stores CONVERSATION", %{valid_attrs: attrs} do
      # Attribute map strictly omits :source_kind
      legacy_attrs = Map.delete(attrs, :source_kind)
      assert {:ok, %Report{} = report} = Reports.create_report(legacy_attrs)

      stored_source =
        Repo.query!(
          "SELECT source_kind FROM public.reports WHERE report_id = $1",
          [Ecto.UUID.dump!(report.report_id)]
        ).rows
        |> hd()
        |> hd()

      assert stored_source == "CONVERSATION"
      assert Map.get(report, :source_kind) == :CONVERSATION
    end
  end

  describe "RED 4 — NULL SOURCE REJECTION" do
    test "database rejects row with source_kind = NULL", %{
      participant_a: participant_a,
      participant_b: participant_b,
      conversation: conversation
    } do
      assert_raise Postgrex.Error, ~r/null value in column "source_kind"|violates not-null constraint/, fn ->
        Repo.query!(
          """
          INSERT INTO public.reports (
            report_id, created_at, updated_at, reporting_participant_id,
            reported_participant_id, conversation_id, report_category, report_status, source_kind
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULL)
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            DateTime.utc_now(),
            DateTime.utc_now(),
            Ecto.UUID.dump!(participant_a.participant_id),
            Ecto.UUID.dump!(participant_b.participant_id),
            Ecto.UUID.dump!(conversation.conversation_id),
            "HARASSMENT",
            "SUBMITTED"
          ]
        )
      end
    end
  end

  describe "RED 5 — SHARED HANGOUT SOURCE REJECTION" do
    test "database rejects shared row with source_kind = 'HANGOUT' via authority constraint", %{
      participant_a: participant_a,
      participant_b: participant_b,
      conversation: conversation
    } do
      assert_raise Postgrex.Error, ~r/reports_source_authority_check/, fn ->
        Repo.query!(
          """
          INSERT INTO public.reports (
            report_id, created_at, updated_at, reporting_participant_id,
            reported_participant_id, conversation_id, report_category, report_status, source_kind
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'HANGOUT')
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            DateTime.utc_now(),
            DateTime.utc_now(),
            Ecto.UUID.dump!(participant_a.participant_id),
            Ecto.UUID.dump!(participant_b.participant_id),
            Ecto.UUID.dump!(conversation.conversation_id),
            "HARASSMENT",
            "SUBMITTED"
          ]
        )
      end
    end
  end

  describe "RED 6 — CALLER CANNOT SELECT HANGOUT" do
    test "caller attrs containing source_kind: :HANGOUT cannot persist a shared HANGOUT row", %{
      valid_attrs: attrs
    } do
      # Even if caller supplies source_kind: :HANGOUT, system/DB authority prevents persisting HANGOUT
      caller_attrs = Map.put(attrs, :source_kind, :HANGOUT)
      result = Reports.create_report(caller_attrs)

      case result do
        {:ok, report} ->
          # If it succeeded, it must have ignored caller source_kind and persisted CONVERSATION
          assert Map.get(report, :source_kind) == :CONVERSATION

          stored_source =
            Repo.query!(
              "SELECT source_kind FROM public.reports WHERE report_id = $1",
              [Ecto.UUID.dump!(report.report_id)]
            ).rows
            |> hd()
            |> hd()

          assert stored_source == "CONVERSATION"

        {:error, _changeset} ->
          :ok
      end

      # In all cases, zero rows in public.reports have source_kind = 'HANGOUT'
      [[hangout_count]] =
        Repo.query!("SELECT count(*) FROM public.reports WHERE source_kind = 'HANGOUT'").rows

      assert hangout_count == 0
    end
  end

  describe "RED 7 — CONVERSATION STRUCTURE REMAINS STRICT" do
    test "rejects missing reporting participant", %{valid_attrs: attrs} do
      invalid = Map.delete(attrs, :reporting_participant_id)
      assert {:error, changeset} = Reports.create_report(invalid)
      assert "can't be blank" in errors_on(changeset).reporting_participant_id
    end

    test "rejects missing reported participant", %{valid_attrs: attrs} do
      invalid = Map.delete(attrs, :reported_participant_id)
      assert {:error, changeset} = Reports.create_report(invalid)
      assert "can't be blank" in errors_on(changeset).reported_participant_id
    end

    test "rejects missing or invalid conversation authority", %{valid_attrs: attrs} do
      invalid_blank = Map.delete(attrs, :conversation_id)
      assert {:error, changeset} = Reports.create_report(invalid_blank)
      assert "can't be blank" in errors_on(changeset).conversation_id

      invalid_fk = Map.put(attrs, :conversation_id, Ecto.UUID.generate())
      assert {:error, changeset_fk} = Reports.create_report(invalid_fk)
      assert "does not exist" in errors_on(changeset_fk).conversation_id
    end

    test "rejects self-reporting", %{valid_attrs: attrs, participant_a: participant_a} do
      invalid = Map.put(attrs, :reported_participant_id, participant_a.participant_id)
      assert {:error, changeset} = Reports.create_report(invalid)
      assert "cannot report yourself" in errors_on(changeset).reporting_participant_id
    end

    test "rejects invalid category semantics", %{valid_attrs: attrs} do
      invalid = Map.put(attrs, :report_category, :INVALID_CATEGORY)
      assert {:error, changeset} = Reports.create_report(invalid)
      assert "is invalid" in errors_on(changeset).report_category
    end
  end

  describe "RED 8 — CATEGORY SEPARATION" do
    test "shared report creation rejects Hangout-only categories", %{
      valid_attrs: attrs,
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b
    } do
      hangout_only_categories = [:HATE, :PERSONAL_INFORMATION, :OTHER]

      for cat <- hangout_only_categories do
        # Ecto schema rejection
        invalid_attrs = Map.put(attrs, :report_category, cat)
        assert {:error, changeset} = Reports.create_report(invalid_attrs)
        assert "is invalid" in errors_on(changeset).report_category

        # submit_conversation_report context rejection
        cat_str = Atom.to_string(cat)
        assert {:error, :invalid_report_category} =
                 Reports.submit_conversation_report(
                   conversation.conversation_id,
                   participant_a.participant_id,
                   cat_str,
                   "evidence text"
                 )

        # Direct SQL constraint rejection
        assert_raise Postgrex.Error, ~r/report_category_check/, fn ->
          Repo.query!(
            """
            INSERT INTO public.reports (
              report_id, created_at, updated_at, reporting_participant_id,
              reported_participant_id, conversation_id, report_category, report_status
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            """,
            [
              Ecto.UUID.dump!(Ecto.UUID.generate()),
              DateTime.utc_now(),
              DateTime.utc_now(),
              Ecto.UUID.dump!(participant_a.participant_id),
              Ecto.UUID.dump!(participant_b.participant_id),
              Ecto.UUID.dump!(conversation.conversation_id),
              cat_str,
              "SUBMITTED"
            ]
          )
        end
      end
    end
  end
end
