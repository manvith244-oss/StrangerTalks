defmodule StrangertalksNew.Wt07BackupSemanticSchemaVerifierTest do
  use ExUnit.Case, async: false

  @workflow_path ".github/workflows/postgres-r2-backup.yml"
  @helper_path "ops/postgres_semantic_schema_compare.sh"

  setup_all do
    for command <- ~w(bash psql pg_dump createdb dropdb) do
      assert System.find_executable(command),
             "#{command} must be available for WT-07 disposable PostgreSQL proof"
    end

    :ok
  end

  test "semantic helper passes bash syntax validation" do
    {output, status} = System.cmd("bash", ["-n", @helper_path], stderr_to_stdout: true)
    assert status == 0, "bash -n failed: #{output}"
  end

  test "equivalent CHECK outer-array cast and element-cast forms compare equal" do
    assert_semantic_match(
      schema_sql(check_cast: :outer, index_cast: :element),
      schema_sql(check_cast: :element, index_cast: :element)
    )
  end

  test "equivalent partial-index outer-array cast and element-cast forms compare equal" do
    assert_semantic_match(
      schema_sql(check_cast: :element, index_cast: :outer),
      schema_sql(check_cast: :element, index_cast: :element)
    )
  end

  test "raw schema text may differ while semantic comparison passes" do
    source_sql = schema_sql(check_cast: :outer, index_cast: :outer)
    target_sql = schema_sql(check_cast: :element, index_cast: :element)

    refute source_sql == target_sql
    assert_semantic_match(source_sql, target_sql)
  end

  test "changing MEDIA_ORIGIN fails semantic comparison" do
    assert_semantic_mismatch(
      schema_sql(),
      schema_sql(media_values: ["NO_MEDIA", "OTHER_ORIGIN"])
    )
  end

  test "removing ACTIVE from the partial-index predicate fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(status_values: ["DISCONNECTED"]))
  end

  test "removing DISCONNECTED from the partial-index predicate fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(status_values: ["ACTIVE"]))
  end

  test "changing index uniqueness fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(unique: false))
  end

  test "changing the indexed key fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(index_key: "room_id"))
  end

  test "changing real CHECK predicate semantics fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(semantic_check: "value >= 0"))
  end

  test "removing a constraint fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(include_media_constraint: false))
  end

  test "removing an index fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(include_index: false))
  end

  test "adding an unexpected contract-relevant object fails semantic comparison" do
    assert_semantic_mismatch(schema_sql(), schema_sql(extra_object: true))
  end

  test "workflow keeps raw diff diagnostic while semantic helper owns schema verdict" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "PHASE2_RAW_SCHEMA_DIFF_BEGIN"
    assert workflow =~ "phase2_raw_schema_text_match=true"
    assert workflow =~ "phase2_raw_schema_text_match=false"
    assert workflow =~ "phase2_raw_schema_difference_is_diagnostic=true"
    assert workflow =~ "bash ops/postgres_semantic_schema_compare.sh"
    assert workflow =~ "phase2_semantic_schema_match=true"

    assert workflow =~ ~s(diff -u "$SOURCE_TABLES" "$scratch_tables")
    assert workflow =~ ~s(diff -u "$SOURCE_COUNTS" "$scratch_counts")
    assert workflow =~ "PHASE2_RESTORE_PROOF=PASS"

    assert workflow =~ "workflow_call:"
    assert workflow =~ "schedule:"
    refute workflow =~ "workflow_dispatch:"
    assert workflow =~ "permissions:\n  contents: read"
    assert workflow =~ "PGSSLMODE=verify-full"
    assert workflow =~ "PGSSLROOTCERT"
  end

  test "verifier contains no known-value or known-object special cases" do
    helper = File.read!(@helper_path)

    refute helper =~ "NO_MEDIA"
    refute helper =~ "MEDIA_ORIGIN"
    refute helper =~ "ACTIVE"
    refute helper =~ "DISCONNECTED"
    refute helper =~ "reports_media_origin_check"
    refute helper =~ "hangout_memberships_one_active_room_per_participant_index"
  end

  defp assert_semantic_match(source_sql, target_sql) do
    with_disposable_pair(source_sql, target_sql, fn source_url, target_url ->
      {output, status} = run_helper(source_url, target_url)
      assert status == 0, "expected semantic match, got exit #{status}:\n#{output}"
      assert output =~ "semantic_schema_match=true"
    end)
  end

  defp assert_semantic_mismatch(source_sql, target_sql) do
    with_disposable_pair(source_sql, target_sql, fn source_url, target_url ->
      {output, status} = run_helper(source_url, target_url)
      assert status != 0, "expected semantic mismatch, verifier passed:\n#{output}"
      assert output =~ "semantic_schema_match=false"
    end)
  end

  defp with_disposable_pair(source_sql, target_sql, fun) do
    suffix = System.unique_integer([:positive, :monotonic])
    source_db = "wt07_src_#{suffix}"
    target_db = "wt07_dst_#{suffix}"

    create_database!(source_db)
    create_database!(target_db)

    source_url = database_url(source_db)
    target_url = database_url(target_db)

    try do
      execute_sql!(source_url, source_sql)
      execute_sql!(target_url, target_sql)
      fun.(source_url, target_url)
    after
      drop_database!(source_db)
      drop_database!(target_db)
    end
  end

  defp run_helper(source_url, target_url) do
    System.cmd(
      "bash",
      [@helper_path, source_url, target_url, "public"],
      stderr_to_stdout: true
    )
  end

  defp create_database!(database) do
    {output, status} =
      System.cmd(
        "createdb",
        ["-h", "127.0.0.1", "-U", database_user(), database],
        env: [{"PGPASSWORD", database_password()}],
        stderr_to_stdout: true
      )

    assert status == 0, "createdb #{database} failed: #{output}"
  end

  defp drop_database!(database) do
    System.cmd(
      "dropdb",
      ["--if-exists", "-h", "127.0.0.1", "-U", database_user(), database],
      env: [{"PGPASSWORD", database_password()}],
      stderr_to_stdout: true
    )
  end

  defp execute_sql!(database_url, sql) do
    {output, status} =
      System.cmd(
        "psql",
        [database_url, "-X", "-v", "ON_ERROR_STOP=1", "-c", sql],
        stderr_to_stdout: true
      )

    assert status == 0, "fixture SQL failed: #{output}"
  end

  defp database_url(database) do
    "postgresql://#{database_user()}:#{database_password()}@127.0.0.1:5432/#{database}"
  end

  defp database_user, do: System.get_env("STRANGERTALKS_LOCAL_DB_USER", "strangertalks_local")

  defp database_password,
    do: System.get_env("STRANGERTALKS_LOCAL_DB_PASSWORD", "strangertalks_test")

  defp schema_sql(opts \\ []) do
    check_cast = Keyword.get(opts, :check_cast, :element)
    index_cast = Keyword.get(opts, :index_cast, :element)
    media_values = Keyword.get(opts, :media_values, ["NO_MEDIA", "MEDIA_ORIGIN"])
    status_values = Keyword.get(opts, :status_values, ["ACTIVE", "DISCONNECTED"])
    unique = Keyword.get(opts, :unique, true)
    index_key = Keyword.get(opts, :index_key, "participant_id")
    semantic_check = Keyword.get(opts, :semantic_check, "value > 0")
    include_media_constraint = Keyword.get(opts, :include_media_constraint, true)
    include_index = Keyword.get(opts, :include_index, true)
    extra_object = Keyword.get(opts, :extra_object, false)

    media_constraint =
      if include_media_constraint do
        ",\n  CONSTRAINT reports_media_origin_check CHECK ((media_origin IS NULL) OR ((media_origin)::text = ANY (#{array_expr(media_values, check_cast)})))"
      else
        ""
      end

    index =
      if include_index do
        "CREATE #{if(unique, do: "UNIQUE ", else: "")}INDEX hangout_memberships_one_active_room_per_participant_index ON public.hangout_memberships USING btree (#{index_key}) WHERE ((status)::text = ANY (#{array_expr(status_values, index_cast)}));"
      else
        ""
      end

    extra =
      if extra_object do
        "CREATE INDEX semantic_probe_unexpected_index ON public.semantic_probe USING btree (label);"
      else
        ""
      end

    """
    CREATE TABLE public.reports (
      id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      media_origin character varying(255)#{media_constraint}
    );

    CREATE TABLE public.hangout_memberships (
      id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      participant_id bigint NOT NULL,
      room_id bigint NOT NULL,
      status character varying(255) NOT NULL
    );

    #{index}

    CREATE TABLE public.semantic_probe (
      value integer NOT NULL,
      label text DEFAULT 'stable'::text,
      CONSTRAINT semantic_probe_check CHECK (#{semantic_check})
    );

    #{extra}
    """
  end

  defp array_expr(values, :outer) do
    values = Enum.map_join(values, ", ", &"'#{&1}'::character varying")
    "(ARRAY[#{values}])::text[]"
  end

  defp array_expr(values, :element) do
    values = Enum.map_join(values, ", ", &"('#{&1}'::character varying)::text")
    "ARRAY[#{values}]"
  end
end
