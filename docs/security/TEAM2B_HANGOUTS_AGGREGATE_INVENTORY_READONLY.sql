-- TEAM 2B SEC-001: aggregate-only historical Hangouts inventory.
-- NO INSERT, UPDATE, DELETE, DDL, message bodies, user IDs, report excerpts,
-- or extraction of individual records.
-- Execute ONLY by an authorized operator against a confirmed intended database.
-- Verify the target database and backup ownership with Team 4B first.
-- The connected Supabase project is not assumed to be the live Render DB.
-- Date: 2026-10-08; source main SHA: 5058fc5c27045c008e1f1f8d66eb3d58aba2b00e

-- 1. Status and age distribution (aggregates, UTC dates).
SELECT status,
       count(*) AS room_count,
       min(created_at) AS oldest_created_at,
       max(created_at) AS newest_created_at,
       min(ended_at) FILTER (WHERE ended_at IS NOT NULL) AS earliest_end_at,
       count(*) FILTER (WHERE ended_at IS NULL) AS without_end_timestamp
FROM public.hangout_rooms
GROUP BY status
ORDER BY status;

-- 2. Ordinary message volumes by parent-room status.
SELECT r.status AS room_status,
       count(DISTINCT r.room_id) AS rooms_with_messages,
       count(m.message_id) AS messages,
       min(m.created_at) AS oldest_message_at,
       max(m.created_at) AS latest_message_at
FROM public.hangout_rooms AS r
LEFT JOIN public.hangout_messages AS m ON m.room_id = r.room_id
GROUP BY r.status
ORDER BY r.status;

-- 3. Report totals and source evidence presence by workflow state.
SELECT status,
       count(*) AS report_count,
       count(*) FILTER (WHERE evidence IS NOT NULL) AS reports_with_evidence,
       min(created_at) AS oldest_report_at,
       max(created_at) AS newest_report_at,
       count(*) FILTER (WHERE resolved_at IS NOT NULL) AS resolved_timestamp_present
FROM public.hangout_reports
GROUP BY status
ORDER BY status;

-- 4. Reported rooms are potentially endangered by ON DELETE CASCADE.
SELECT r.status AS room_status,
       count(DISTINCT r.room_id) AS rooms_with_reports,
       count(h.report_id) AS reports,
       count(*) FILTER (WHERE h.evidence IS NOT NULL) AS reports_with_evidence
FROM public.hangout_rooms r
JOIN public.hangout_reports h ON h.room_id = r.room_id
GROUP BY r.status
ORDER BY r.status;

-- 5. Age buckets for existing ordinary message rows (NO approved TTL assumed).
SELECT CASE
         WHEN m.created_at >= (now() AT TIME ZONE 'UTC') - interval '1 day' THEN '<1d'
         WHEN m.created_at >= (now() AT TIME ZONE 'UTC') - interval '7 days' THEN '1-7d'
         WHEN m.created_at >= (now() AT TIME ZONE 'UTC') - interval '30 days' THEN '7-30d'
         ELSE '>=30d'
       END AS historical_age_bucket,
       count(*) AS message_rows
FROM public.hangout_messages m
GROUP BY 1
ORDER BY 1;

-- 6. Foreign-key delete behavior proof (no row values).
SELECT tc.table_name AS child_table,
       kcu.column_name AS child_column,
       ccu.table_name AS parent_table,
       rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
JOIN information_schema.referential_constraints rc
  ON rc.constraint_name = tc.constraint_name AND rc.constraint_schema = tc.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name AND ccu.constraint_schema = tc.table_schema
WHERE tc.table_schema = 'public'
  AND tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name IN ('hangout_rooms', 'hangout_memberships', 'hangout_messages', 'hangout_reports')
ORDER BY child_table, child_column;

-- 7. Application role privileges: RLS notices are NOT reachability proof.
SELECT n.nspname || '.' || c.relname AS relation,
       c.relrowsecurity AS rls_enabled,
       has_table_privilege('anon', c.oid, 'SELECT') AS anon_can_select,
       has_table_privilege('authenticated', c.oid, 'SELECT') AS authenticated_can_select
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname IN
  ('schema_migrations', 'hangout_rooms', 'hangout_memberships',
   'hangout_messages', 'hangout_reports')
ORDER BY relation;

-- DO NOT add DELETE statements or infer a retention duration from this inventory.
