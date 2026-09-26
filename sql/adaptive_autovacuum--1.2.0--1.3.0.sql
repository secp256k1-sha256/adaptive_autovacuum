\echo Use "ALTER EXTENSION adaptive_autovacuum UPDATE TO '1.3.0'" to load this file. \quit

/* 1.2.0 -> 1.3.0: Debian 12/13 and EL10 packages; vacuum_activity_detail per-second keys become true deltas;
   autovacuum = off is repaired before the sweep; table settings are recommended (table_recommendations), never written;
   autovacuum_naptime is managed and worker raises need only an overdue queue longer than the pool.
   assemble.sh appends parts 02-04 with CREATE OR REPLACE, so every function and view below is rebuilt. */

ALTER TABLE adaptive_autovacuum.controller_state
    ADD COLUMN last_io_hits double precision,
    ADD COLUMN last_io_reads double precision,
    ADD COLUMN last_io_writes double precision,
    ADD COLUMN last_io_extends double precision;

/* autovacuum = off is repaired on the first check that sees it; installs still on the old 10-check default follow. */
ALTER TABLE adaptive_autovacuum.policy
    ALTER COLUMN repair_disabled_autovacuum_cycles SET DEFAULT 1;
UPDATE adaptive_autovacuum.policy
SET repair_disabled_autovacuum_cycles = 1
WHERE repair_disabled_autovacuum_cycles = 10;

/* Every table counts and the dead-tuple floor is 1% of a 100K-row table; only the old defaults are moved. */
ALTER TABLE adaptive_autovacuum.policy
    ALTER COLUMN min_table_bytes SET DEFAULT 0,
    ALTER COLUMN target_dead_tuple_min SET DEFAULT 1000;
UPDATE adaptive_autovacuum.policy SET min_table_bytes = 0 WHERE min_table_bytes = 67108864;
UPDATE adaptive_autovacuum.policy SET target_dead_tuple_min = 1000 WHERE target_dead_tuple_min = 5000;

/* Table settings are recommendations now: no DDL pacing, cooldown, cost ramp or cost budget. */
ALTER TABLE adaptive_autovacuum.policy
    DROP COLUMN change_cooldown_seconds,
    DROP COLUMN max_changes_per_cycle,
    DROP COLUMN boost_ramp_factor,
    DROP COLUMN boost_total_cost_limit_budget;
ALTER TABLE adaptive_autovacuum.policy RENAME COLUMN manage_table_costs TO recommend_table_costs;
ALTER TABLE adaptive_autovacuum.policy ALTER COLUMN recommend_table_costs SET DEFAULT true;
UPDATE adaptive_autovacuum.policy SET recommend_table_costs = true;
ALTER TABLE adaptive_autovacuum.policy RENAME COLUMN overdue_cycles_before_change TO overdue_cycles_before_recommend;
ALTER TABLE adaptive_autovacuum.policy RENAME COLUMN healthy_cycles_before_restore TO healthy_cycles_before_revert;

/* Same definition as in the 1.3.0 install script (01_schema.sql). */
CREATE FUNCTION adaptive_autovacuum._reloptions_sql(relation_name text, options jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    WITH opt AS (
        SELECT o.key, o.value
        FROM jsonb_each_text(COALESCE(options, '{}'::jsonb)) AS o(key, value)
        WHERE o.key IN ('autovacuum_vacuum_threshold', 'autovacuum_vacuum_scale_factor',
                        'autovacuum_vacuum_max_threshold', 'autovacuum_vacuum_insert_threshold',
                        'autovacuum_vacuum_insert_scale_factor', 'autovacuum_vacuum_cost_limit',
                        'autovacuum_vacuum_cost_delay')
          AND (o.value IS NULL OR o.value ~ '^-?[0-9]+([.][0-9]+)?$')
    )
    SELECT NULLIF(concat_ws(' ',
        (SELECT format('ALTER TABLE %s SET (%s);', relation_name,
                       string_agg(format('%I = %s', key, value), ', ' ORDER BY key))
         FROM opt WHERE value IS NOT NULL HAVING count(*) > 0),
        (SELECT format('ALTER TABLE %s RESET (%s);', relation_name,
                       string_agg(format('%I', key), ', ' ORDER BY key))
         FROM opt WHERE value IS NULL HAVING count(*) > 0)), '')
$$;

COMMENT ON FUNCTION adaptive_autovacuum._reloptions_sql(text, jsonb) IS
'Builds the ALTER TABLE ... SET (...) / RESET (...) statements for a jsonb of reloptions (null value = RESET). Used by table_recommendations; run the text in the database that owns the table.';

/* Table options 1.2.0 wrote stay in place (they are tighter triggers); their restore SQL goes to the action log. */
INSERT INTO adaptive_autovacuum.decisions
    (database_oid, database_name, relid, relation_name, state, action, reason, host_metrics, proposed_reloptions, applied)
SELECT ts.database_oid, ts.database_name, ts.relation_oid, ts.relation_name, ts.state, 'legacy_table_settings',
       format('adaptive_autovacuum 1.2.0 set these table options automatically; 1.3.0 only recommends table settings and neither changes nor restores them. To restore the previous values, run in database %I: %s',
              ts.database_name,
              adaptive_autovacuum._reloptions_sql(ts.relation_name,
                  (SELECT jsonb_object_agg(k, adaptive_autovacuum._option_value(ts.original_reloptions, k))
                   FROM jsonb_object_keys(ts.managed_values) AS k))),
       '{}'::jsonb, ts.managed_values, true
FROM adaptive_autovacuum.table_state ts
WHERE ts.managed_values <> '{}'::jsonb;

/* Objects whose columns or signature change; parts 02-04 re-create them. */
DROP VIEW adaptive_autovacuum.changed_tables;
DROP VIEW adaptive_autovacuum.table_status;
DROP VIEW adaptive_autovacuum.database_status;
DROP VIEW adaptive_autovacuum.latest_global_recommendation;
DROP FUNCTION adaptive_autovacuum._reconcile_relation_options(text, text[], jsonb, jsonb, integer);
DROP FUNCTION adaptive_autovacuum._managed_values_match(text[], jsonb);
DROP FUNCTION adaptive_autovacuum.status();

ALTER TABLE adaptive_autovacuum.table_state
    DROP COLUMN original_reloptions,
    DROP COLUMN original_captured,
    DROP COLUMN managed_values,
    DROP COLUMN ownership_conflict,
    DROP COLUMN last_change_at,
    DROP COLUMN last_error,
    ADD COLUMN recommendation_status text CHECK (recommendation_status IN ('open', 'applied', 'revert')),
    ADD COLUMN recommended_reloptions jsonb,
    ADD COLUMN previous_reloptions jsonb,
    ADD COLUMN recommendation_reason text,
    ADD COLUMN recommended_at timestamptz,
    ADD COLUMN applied_at timestamptz;

ALTER TABLE adaptive_autovacuum.database_state RENAME COLUMN changes_applied TO recommended_relations;

/* 1.3.0: autovacuum_naptime is managed (ramped down while the pool is under-filled, decayed with the cost pair). */
ALTER TABLE adaptive_autovacuum.policy
    ADD COLUMN manage_naptime boolean NOT NULL DEFAULT true,
    ADD COLUMN naptime_min_seconds integer NOT NULL DEFAULT 5 CHECK (naptime_min_seconds >= 1);
ALTER TABLE adaptive_autovacuum.global_recommendations
    ADD COLUMN recommended_autovacuum_naptime_seconds integer;


/* The per-database program: run by the database worker as an anonymous block in the managed database. */
/* It needs no extension objects there: input arrives in adaptive_autovacuum.worker_input, output leaves in worker_output. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._database_program()
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN $aav_body$
DECLARE
    input jsonb := pg_catalog.current_setting('adaptive_autovacuum.worker_input')::jsonb;
    p record;
    r record;
    scan_started_at timestamptz := clock_timestamp();

    server_vnum integer := current_setting('server_version_num')::integer;
    block_size bigint := current_setting('block_size')::bigint;

    host_json jsonb;
    host_pressure boolean;
    moderate_pressure boolean;
    host_metrics_available boolean;
    host_mem_available_bytes bigint;
    xid_rate double precision;
    prev_eligible integer;
    prev_dead_overdue integer;
    prev_insert_overdue integer;
    widespread_dead boolean;
    widespread_insert boolean;

    autovacuum_enabled_global boolean;
    global_cost_limit integer;
    global_cost_delay double precision;
    freeze_max_age bigint;
    multixact_freeze_max_age bigint;
    current_vacuum_threshold double precision;
    current_vacuum_scale_factor double precision;
    current_vacuum_max_threshold double precision;
    current_insert_threshold double precision;
    current_insert_scale_factor double precision;

    table_count integer := 0;
    scanned_relation_count integer := 0;
    fleet_max_target bigint := 0;
    total_debt_tuples bigint := 0;
    db_max_xid_age bigint := 0;
    db_max_mxid_age bigint := 0;
    dead_overdue_count integer := 0;
    overdue_scale_factors double precision[] := '{}';
    overdue_thresholds integer[] := '{}';
    insert_overdue_count integer := 0;
    overdue_insert_scale_factors double precision[] := '{}';
    overdue_insert_thresholds integer[] := '{}';
    local_median_scale double precision;
    local_median_thresh double precision;
    local_median_ins_scale double precision;
    local_median_ins_thresh double precision;
    overdue_relation_count integer := 0;
    emergency_relation_count integer := 0;
    critical_seen boolean := false;
    analyze_budget_ms integer;
    analyze_started_at timestamptz;
    analyze_count integer := 0;

    vacuum_trigger double precision;
    insert_trigger double precision;
    backlog_ratio double precision;
    insert_ratio double precision;
    pressure_ratio double precision;
    xid_ratio double precision;
    mxid_ratio double precision;
    horizon_age bigint;
    horizon_kind text;
    horizon_detail text;
    xid_horizon_blocked boolean;
    stall_xid_age bigint;
    stall_mxid_age bigint;
    av_wraparound_running boolean;
    av_elapsed_seconds double precision;
    seconds_until_readonly double precision;
    cur_vacuum_progress text;
    vacuum_stalled_cycles integer;
    emergency_due boolean;
    emergency_takeover boolean;
    emergency_gate jsonb;
    relation_state text;
    reason text;
    overdue_cycles integer;
    healthy_cycles integer;

    /* Previous table_state row (before-image in r.prev_*, mutable copy here). */
    pv_state text;
    pv_consecutive_overdue integer;
    pv_consecutive_healthy integer;
    pv_rec_status text;
    pv_recommended jsonb;
    pv_previous jsonb;
    pv_reason text;
    pv_recommended_at timestamptz;
    pv_applied_at timestamptz;
    pv_last_vacuum_pid integer;
    pv_last_vacuum_progress text;
    pv_vacuum_stalled_cycles integer;
    pv_last_action text;

    effective_target_ratio double precision;
    effective_target_min bigint;
    effective_target_max bigint;
    effective_scale_min double precision;
    effective_scale_max double precision;
    target_dead_tuples bigint;
    desired_threshold integer;
    desired_scale_factor double precision;
    desired_max_threshold integer;
    target_inserts bigint;
    desired_insert_threshold integer;
    desired_insert_scale double precision;
    desired_values jsonb;
    trigger_keys jsonb;
    insert_keys jsonb;
    cost_keys jsonb;
    keys_match boolean;
    rec_parts text[];
    recommend_now boolean;
    relation_json jsonb;

    /* Recommendation lifecycle of this relation (open -> applied -> revert), as decided this cycle. */
    new_rec_status text;
    new_recommended jsonb;
    new_previous jsonb;
    new_reason text;
    new_recommended_at timestamptz;
    new_applied_at timestamptz;
    recommended_count integer := 0;

    cost_boost_count integer := 0;
    wants_cost_boost boolean;
    has_existing_cost_boost boolean;
    tier_cost_limit integer;
    tier_cost_delay double precision;
    eff_cost_limit integer;
    eff_cost_delay double precision;
    applied boolean;
    action_name text;
    action_error text;
    state_needed boolean;
    emergency_work_mem_mb integer;

    out_state jsonb := '[]'::jsonb;
    out_state_delete jsonb := '[]'::jsonb;
    out_decisions jsonb := '[]'::jsonb;
    out_emergency jsonb := '[]'::jsonb;
    extension_installed boolean;
BEGIN
    SELECT * INTO p
    FROM jsonb_to_record(input -> 'policy') AS x(
        enabled boolean, dry_run boolean, manage_global_settings boolean,
        min_table_bytes bigint, excluded_schemas text[],
        target_dead_tuple_ratio double precision, target_dead_tuple_min bigint, target_dead_tuple_max bigint,
        target_insert_ratio double precision, target_insert_min bigint, target_insert_max bigint,
        threshold_floor integer, min_scale_factor double precision, max_scale_factor double precision,
        backlog_elevated_ratio double precision, backlog_urgent_ratio double precision, backlog_critical_ratio double precision,
        overdue_cycles_before_recommend integer, healthy_cycles_before_revert integer,
        lock_timeout_ms integer,
        analyze_missing_stats boolean, analyze_missing_stats_budget_ms integer,
        recommend_table_costs boolean, max_boosted_relations integer,
        elevated_cost_limit integer, urgent_cost_limit integer, critical_cost_limit integer,
        elevated_cost_delay_ms double precision, urgent_cost_delay_ms double precision, critical_cost_delay_ms double precision,
        xid_warning_ratio double precision, mxid_warning_ratio double precision,
        emergency_xid_age bigint, emergency_mxid_age bigint, emergency_stall_multiplier double precision,
        emergency_takeover_min_runtime_seconds integer, emergency_takeover_stall_samples integer,
        high_load_per_cpu double precision, low_memory_percent double precision, high_wal_mbps double precision,
        work_mem_available_fraction double precision,
        emergency_vacuum_enabled boolean, emergency_work_mem_min_mb integer, emergency_work_mem_max_mb integer,
        emergency_cost_limit integer, emergency_cost_delay_ms integer, emergency_lock_timeout_ms integer);

    extension_installed := EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = 'adaptive_autovacuum');

    host_json := input -> 'host';
    host_pressure := COALESCE((host_json ->> 'pressure')::boolean, false);
    moderate_pressure := COALESCE((host_json ->> 'moderate_pressure')::boolean, false);
    host_metrics_available := COALESCE((host_json ->> 'memory_metrics_available')::boolean, false);
    host_mem_available_bytes := COALESCE((host_json ->> 'mem_available_bytes')::bigint, 0);
    xid_rate := (input -> 'cluster' ->> 'xid_rate')::double precision;
    /* Same rule as the cluster baseline detector: 3 relations and a quarter of the fleet overdue in the last scan. */
    prev_eligible := COALESCE((input -> 'cluster' ->> 'prev_eligible')::integer, 0);
    prev_dead_overdue := COALESCE((input -> 'cluster' ->> 'prev_dead_overdue')::integer, 0);
    prev_insert_overdue := COALESCE((input -> 'cluster' ->> 'prev_insert_overdue')::integer, 0);
    widespread_dead := prev_dead_overdue >= 3 AND prev_dead_overdue * 4 >= prev_eligible;
    widespread_insert := prev_insert_overdue >= 3 AND prev_insert_overdue * 4 >= prev_eligible;
    /* Cost-boost recommendations standing in the other databases share the slot limit. */
    cost_boost_count := COALESCE((input -> 'cluster' ->> 'boosted_relations_elsewhere')::integer, 0);

    SELECT setting::boolean INTO autovacuum_enabled_global
    FROM pg_settings WHERE name = 'autovacuum';
    SELECT setting::bigint INTO freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    SELECT setting::bigint INTO multixact_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_multixact_freeze_max_age';
    SELECT setting::double precision INTO current_vacuum_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold';
    SELECT setting::double precision INTO current_vacuum_scale_factor
    FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor';
    SELECT setting::double precision INTO current_vacuum_max_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_max_threshold';
    SELECT setting::double precision INTO current_insert_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_threshold';
    SELECT setting::double precision INTO current_insert_scale_factor
    FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_scale_factor';
    /* The pair a table without its own cost reloptions vacuums under (-1 = the manual-vacuum setting). */
    SELECT CASE WHEN a.setting::integer < 0 THEN v.setting::integer ELSE a.setting::integer END
    INTO global_cost_limit
    FROM pg_settings a, pg_settings v
    WHERE a.name = 'autovacuum_vacuum_cost_limit' AND v.name = 'vacuum_cost_limit';
    SELECT CASE WHEN a.setting::double precision < 0 THEN v.setting::double precision ELSE a.setting::double precision END
    INTO global_cost_delay
    FROM pg_settings a, pg_settings v
    WHERE a.name = 'autovacuum_vacuum_cost_delay' AND v.name = 'vacuum_cost_delay';

    /* Oldest cleanup-horizon blocker visible from this database, fetched once per cycle. */
    SELECT b.blocker_age, b.blocker_kind, b.blocker_detail
    INTO horizon_age, horizon_kind, horizon_detail
    FROM (
        SELECT GREATEST(age(a.backend_xmin), age(a.backend_xid))::bigint AS blocker_age,
               'backend'::text AS blocker_kind,
               format('pid %s, user %s, application %s, state %s, xact_start %s',
                      a.pid, a.usename, COALESCE(a.application_name, ''),
                      a.state, a.xact_start) AS blocker_detail
        FROM pg_catalog.pg_stat_activity a
        WHERE (a.datname = pg_catalog.current_database() OR a.datname IS NULL)
          AND (a.backend_xmin IS NOT NULL OR a.backend_xid IS NOT NULL)
        UNION ALL
        SELECT age(px.transaction)::bigint,
               'prepared_transaction',
               format('gid %L, prepared %s, owner %s', px.gid, px.prepared, px.owner)
        FROM pg_catalog.pg_prepared_xacts px
        WHERE px.database = pg_catalog.current_database()
        UNION ALL
        SELECT GREATEST(age(s.xmin), age(s.catalog_xmin))::bigint,
               'replication_slot',
               format('slot %s, type %s, active %s', s.slot_name, s.slot_type, s.active)
        FROM pg_catalog.pg_replication_slots s
        WHERE s.xmin IS NOT NULL OR s.catalog_xmin IS NOT NULL
    ) b
    WHERE b.blocker_age IS NOT NULL
    ORDER BY b.blocker_age DESC
    LIMIT 1;

    /* This database's own standing cost-boost recommendations, from the previous state rows handed in. */
    SELECT cost_boost_count + count(*)
    INTO cost_boost_count
    FROM jsonb_to_recordset(COALESCE(input -> 'table_state', '[]'::jsonb))
         AS ts(recommendation_status text, recommended_reloptions jsonb)
    WHERE ts.recommendation_status IS NOT NULL
      AND ts.recommended_reloptions ? 'autovacuum_vacuum_cost_limit';

    /* Fleet aggregates over every eligible relation; the loop below only sees the interesting ones. */
    WITH tpol AS MATERIALIZED (
        SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
               AS x(schema_name name, relation_name name, enabled boolean,
                    target_dead_tuple_ratio double precision, target_dead_tuple_min bigint,
                    target_dead_tuple_max bigint, min_scale_factor double precision,
                    max_scale_factor double precision)
    ),
    rel AS (
        SELECT c.oid, c.reltuples, c.relkind, n.nspname,
               COALESCE(tp.enabled, true) AS tp_enabled,
               tp.target_dead_tuple_ratio AS tp_ratio, tp.target_dead_tuple_min AS tp_min,
               tp.target_dead_tuple_max AS tp_max,
               GREATEST(age(c.relfrozenxid), COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
               GREATEST(mxid_age(c.relminmxid), COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
               pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples,
               pg_stat_get_dead_tuples(c.oid)::bigint AS dead_tuples,
               CASE
                   WHEN c.relpages > 0 THEN c.relpages::bigint * block_size
                   WHEN pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)
                        >= p.min_table_bytes / block_size THEN pg_total_relation_size(c.oid)
                   ELSE 0::bigint
               END AS total_bytes
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
        LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
        WHERE c.relkind IN ('r', 'm')
          AND c.relpersistence <> 't'
    )
    SELECT count(*) FILTER (WHERE rel.relkind = 'r' AND rel.nspname NOT IN ('pg_catalog', 'information_schema')),
           count(*) FILTER (WHERE rel.relkind = 'r' AND NOT (rel.nspname = ANY (p.excluded_schemas))
                                  AND rel.tp_enabled AND rel.total_bytes >= p.min_table_bytes),
           COALESCE(max(LEAST(COALESCE(rel.tp_max, p.target_dead_tuple_max),
                              GREATEST(COALESCE(rel.tp_min, p.target_dead_tuple_min),
                                       ceil(GREATEST(rel.live_tuples::double precision,
                                                     rel.reltuples::double precision, 1)
                                            * COALESCE(rel.tp_ratio, p.target_dead_tuple_ratio))::bigint)))
                    FILTER (WHERE rel.relkind = 'r' AND NOT (rel.nspname = ANY (p.excluded_schemas))
                                  AND rel.tp_enabled AND rel.total_bytes >= p.min_table_bytes), 0),
           COALESCE(sum(rel.dead_tuples + pg_stat_get_ins_since_vacuum(rel.oid)::bigint)
                    FILTER (WHERE rel.relkind = 'r' AND NOT (rel.nspname = ANY (p.excluded_schemas))
                                  AND rel.tp_enabled AND rel.total_bytes >= p.min_table_bytes), 0),
           COALESCE(max(rel.xid_age), 0),
           COALESCE(max(rel.mxid_age), 0)
    INTO table_count, scanned_relation_count, fleet_max_target, total_debt_tuples,
         db_max_xid_age, db_max_mxid_age
    FROM rel;

    FOR r IN
        WITH tpol AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
                   AS x(schema_name name, relation_name name, enabled boolean,
                        target_dead_tuple_ratio double precision, target_dead_tuple_min bigint,
                        target_dead_tuple_max bigint, min_scale_factor double precision,
                        max_scale_factor double precision)
        ),
        prev_state AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_state', '[]'::jsonb))
                   AS x(relation_oid oid, relation_name text,
                        recommendation_status text, recommended_reloptions jsonb, previous_reloptions jsonb,
                        recommendation_reason text, recommended_at timestamptz, applied_at timestamptz,
                        state text, consecutive_overdue integer, consecutive_healthy integer,
                        last_seen_at timestamptz,
                        last_vacuum_pid integer, last_vacuum_progress text,
                        vacuum_stalled_cycles integer, last_action text)
        ),
        active_vacuum AS
        (
            SELECT
                pv.relid,
                pv.pid AS vacuum_pid,
                pv.phase,
                pv.heap_blks_total,
                pv.heap_blks_scanned,
                pv.heap_blks_vacuumed,
                pv.indexes_processed,
                pv.index_vacuum_count,
                pv.max_dead_tuple_bytes,
                pv.dead_tuple_bytes,
                /* PG18+ column; NULL on PG17 via the jsonb detour. */
                ((to_jsonb(pv) ->> 'delay_time'))::double precision AS delay_time,
                clock_timestamp() - a.query_start AS vacuum_elapsed,
                a.query LIKE '%(to prevent wraparound)' AS antiwraparound,
                a.backend_type = 'autovacuum worker' AS is_autovacuum
            FROM pg_stat_progress_vacuum pv
            JOIN pg_stat_activity a ON a.pid = pv.pid
            WHERE pv.datid = (SELECT d.oid
                              FROM pg_catalog.pg_database d
                              WHERE d.datname = pg_catalog.current_database())
        ),
        cand AS
        (
        SELECT
            c.oid AS relid,
            format('%I.%I', n.nspname, c.relname) AS fqname,
            n.nspname,
            c.relname,
            c.reloptions,
            c.reltuples::double precision AS reltuples,
            sz.total_bytes,
            pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples,
            pg_stat_get_dead_tuples(c.oid)::bigint AS dead_tuples,
            /* TOAST has its own relfrozenxid; the older one drives wraparound. */
            GREATEST(age(c.relfrozenxid),
                     COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
            GREATEST(mxid_age(c.relminmxid),
                     COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
            autovacuum_enabled_global
                AND COALESCE(opt.ro_autovacuum_enabled::boolean, true)
                AS normal_autovacuum_enabled,
            CASE
                WHEN opt.ro_freeze_max_age IS NULL OR opt.ro_freeze_max_age::bigint < 0
                THEN freeze_max_age
                ELSE LEAST(freeze_max_age, opt.ro_freeze_max_age::bigint)
            END AS effective_xid_freeze_max_age,
            CASE
                WHEN opt.ro_multixact_freeze_max_age IS NULL OR opt.ro_multixact_freeze_max_age::bigint < 0
                THEN multixact_freeze_max_age
                ELSE LEAST(multixact_freeze_max_age, opt.ro_multixact_freeze_max_age::bigint)
            END AS effective_mxid_freeze_max_age,
            COALESCE(opt.ro_vacuum_threshold::double precision,
                     current_vacuum_threshold) AS vacuum_threshold,
            COALESCE(opt.ro_vacuum_scale_factor::double precision,
                     current_vacuum_scale_factor) AS vacuum_scale_factor,
            COALESCE(opt.ro_vacuum_max_threshold::double precision,
                     current_vacuum_max_threshold) AS vacuum_max_threshold,
            pg_stat_get_ins_since_vacuum(c.oid)::bigint AS inserts_since_vacuum,
            COALESCE(opt.ro_insert_threshold::double precision,
                     current_insert_threshold) AS insert_threshold,
            COALESCE(opt.ro_insert_scale_factor::double precision,
                     current_insert_scale_factor) AS insert_scale_factor,
            /* PG18 scales the insert trigger by the unfrozen page share (relallfrozen); 1.0 on PG17. */
            CASE
                WHEN c.relpages > 0
                 AND COALESCE(((to_jsonb(c) ->> 'relallfrozen'))::bigint, 0) > 0
                THEN GREATEST(0.0,
                              1.0 - LEAST(((to_jsonb(c) ->> 'relallfrozen'))::bigint,
                                          c.relpages)::double precision
                                    / c.relpages)
                ELSE 1.0
            END AS insert_pcnt_unfrozen,
            av.vacuum_pid,
            av.phase,
            av.heap_blks_total,
            av.heap_blks_scanned,
            av.heap_blks_vacuumed,
            av.indexes_processed,
            av.index_vacuum_count,
            av.max_dead_tuple_bytes,
            av.dead_tuple_bytes,
            av.delay_time,
            av.vacuum_elapsed,
            av.antiwraparound,
            av.is_autovacuum,
            tp.target_dead_tuple_ratio AS table_target_ratio,
            tp.target_dead_tuple_min AS table_target_min,
            tp.target_dead_tuple_max AS table_target_max,
            tp.min_scale_factor AS table_scale_min,
            tp.max_scale_factor AS table_scale_max,
            opt.ro_cost_limit AS cost_limit_reloption,
            opt.ro_cost_delay AS cost_delay_reloption,
            /* Previous state joined once here; NULL = never persisted. */
            rs.relation_oid IS NOT NULL AS state_exists,
            rs.relation_name AS prev_relation_name,
            rs.recommendation_status AS prev_recommendation_status,
            rs.recommended_reloptions AS prev_recommended_reloptions,
            rs.previous_reloptions AS prev_previous_reloptions,
            rs.recommendation_reason AS prev_recommendation_reason,
            rs.recommended_at AS prev_recommended_at,
            rs.applied_at AS prev_applied_at,
            rs.state AS prev_state,
            rs.consecutive_overdue AS prev_consecutive_overdue,
            rs.consecutive_healthy AS prev_consecutive_healthy,
            rs.last_seen_at AS prev_last_seen_at,
            rs.last_vacuum_pid AS prev_last_vacuum_pid,
            rs.last_vacuum_progress AS prev_last_vacuum_progress,
            rs.vacuum_stalled_cycles AS prev_vacuum_stalled_cycles,
            rs.last_action AS prev_last_action
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
        LEFT JOIN prev_state rs ON rs.relation_oid = c.oid
        CROSS JOIN LATERAL (
            /* Every reloption the policy reads, parsed in one pass per relation. */
            SELECT
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_enabled') AS ro_autovacuum_enabled,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_freeze_max_age') AS ro_freeze_max_age,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_multixact_freeze_max_age') AS ro_multixact_freeze_max_age,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_threshold') AS ro_vacuum_threshold,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_scale_factor') AS ro_vacuum_scale_factor,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_max_threshold') AS ro_vacuum_max_threshold,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_insert_threshold') AS ro_insert_threshold,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_insert_scale_factor') AS ro_insert_scale_factor,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_cost_limit') AS ro_cost_limit,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_cost_delay') AS ro_cost_delay
            FROM unnest(c.reloptions) AS o
        ) opt
        CROSS JOIN LATERAL (
            /* relpages avoids per-relation locks; exact size only for big unanalyzed relations. */
            SELECT CASE
                       WHEN c.relpages > 0 THEN c.relpages::bigint * block_size
                       WHEN pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)
                            >= p.min_table_bytes / block_size THEN pg_total_relation_size(c.oid)
                       ELSE 0::bigint
                   END AS total_bytes
        ) sz
        LEFT JOIN active_vacuum av ON av.relid = c.oid
        LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
        WHERE c.relkind = 'r'
          AND c.relpersistence <> 't'
          AND NOT (n.nspname = ANY (p.excluded_schemas))
          AND COALESCE(tp.enabled, true)
          AND sz.total_bytes >= p.min_table_bytes
        ),
        scored AS
        (
        /* The loop body's pressure formulas, computed once per relation for filter and order. */
        SELECT cand.*,
               cand.dead_tuples / GREATEST(1,
                   CASE WHEN cand.vacuum_max_threshold < 0
                        THEN cand.vacuum_threshold
                             + cand.vacuum_scale_factor * GREATEST(cand.reltuples, 0)
                        ELSE LEAST(cand.vacuum_max_threshold,
                                   cand.vacuum_threshold
                                   + cand.vacuum_scale_factor * GREATEST(cand.reltuples, 0))
                   END) AS pre_backlog_ratio,
               CASE WHEN cand.insert_threshold IS NULL OR cand.insert_threshold < 0 THEN 0
                    ELSE cand.inserts_since_vacuum / GREATEST(1,
                             cand.insert_threshold
                             + cand.insert_scale_factor * GREATEST(cand.reltuples, 0)
                               * cand.insert_pcnt_unfrozen)
               END AS pre_insert_ratio,
               cand.xid_age / NULLIF(cand.effective_xid_freeze_max_age, 0)::double precision AS pre_xid_ratio,
               cand.mxid_age / NULLIF(cand.effective_mxid_freeze_max_age, 0)::double precision AS pre_mxid_ratio
        FROM cand
        )
        /* Pre-filter: only relations that can be non-normal, carry state, or have a vacuum running. */
        SELECT *
        FROM scored
        WHERE scored.state_exists
           OR scored.vacuum_pid IS NOT NULL
           OR scored.pre_backlog_ratio >= p.backlog_elevated_ratio * 0.5
           OR scored.pre_insert_ratio >= p.backlog_elevated_ratio * 0.5
           OR scored.pre_xid_ratio >= p.xid_warning_ratio * 0.5
           OR scored.pre_mxid_ratio >= p.mxid_warning_ratio * 0.5
        ORDER BY GREATEST(COALESCE(scored.pre_xid_ratio, 0),
                          COALESCE(scored.pre_mxid_ratio, 0),
                          scored.pre_backlog_ratio,
                          scored.pre_insert_ratio) DESC
    LOOP
        /* PG17: vacuum_max_threshold is NULL, so this degrades to the uncapped formula. */
        IF r.vacuum_max_threshold < 0 THEN
            vacuum_trigger := r.vacuum_threshold
                              + r.vacuum_scale_factor * GREATEST(r.reltuples, 0);
        ELSE
            vacuum_trigger := LEAST(r.vacuum_max_threshold,
                                    r.vacuum_threshold
                                    + r.vacuum_scale_factor * GREATEST(r.reltuples, 0));
        END IF;

        vacuum_trigger := GREATEST(vacuum_trigger, 1);
        backlog_ratio := r.dead_tuples / vacuum_trigger;

        /* Negative effective insert threshold = insert vacuums disabled for this relation. */
        IF r.insert_threshold IS NULL OR r.insert_threshold < 0 THEN
            insert_trigger := NULL;
            insert_ratio := 0;
        ELSE
            insert_trigger := GREATEST(1, r.insert_threshold
                                          + r.insert_scale_factor
                                            * GREATEST(r.reltuples, 0)
                                            * r.insert_pcnt_unfrozen);
            insert_ratio := r.inserts_since_vacuum / insert_trigger;
        END IF;
        pressure_ratio := GREATEST(backlog_ratio, insert_ratio);
        xid_ratio := r.xid_age::double precision / NULLIF(r.effective_xid_freeze_max_age, 0);
        mxid_ratio := r.mxid_age::double precision / NULLIF(r.effective_mxid_freeze_max_age, 0);

        /* Emergency = built-in anti-wraparound autovacuum never started, or running with zero progress. */
        stall_xid_age := LEAST(p.emergency_xid_age,
                               ceil(p.emergency_stall_multiplier
                                    * COALESCE(NULLIF(r.effective_xid_freeze_max_age, 0),
                                               freeze_max_age))::bigint);
        stall_mxid_age := LEAST(p.emergency_mxid_age,
                                ceil(p.emergency_stall_multiplier
                                     * COALESCE(NULLIF(r.effective_mxid_freeze_max_age, 0),
                                                multixact_freeze_max_age))::bigint);

        /* Any autovacuum worker counts (the wraparound tag is not required); manual vacuums never. */
        av_wraparound_running := r.vacuum_pid IS NOT NULL
                                 AND COALESCE(r.is_autovacuum, false);
        av_elapsed_seconds := extract(epoch FROM COALESCE(r.vacuum_elapsed, interval '0'));

        seconds_until_readonly := NULL;
        IF xid_rate IS NOT NULL AND xid_rate > 0 THEN
            seconds_until_readonly :=
                GREATEST(2147483648 - 3000000 - r.xid_age, 0)::double precision / xid_rate;
        END IF;

        /* r.prev_* is the before-image for the write-on-change test; pv_* is the working copy. */
        pv_state := COALESCE(r.prev_state, 'normal');
        pv_consecutive_overdue := COALESCE(r.prev_consecutive_overdue, 0);
        pv_consecutive_healthy := COALESCE(r.prev_consecutive_healthy, 0);
        pv_rec_status := r.prev_recommendation_status;
        pv_recommended := COALESCE(r.prev_recommended_reloptions, '{}'::jsonb);
        pv_previous := r.prev_previous_reloptions;
        pv_reason := r.prev_recommendation_reason;
        pv_recommended_at := r.prev_recommended_at;
        pv_applied_at := r.prev_applied_at;
        pv_last_vacuum_pid := r.prev_last_vacuum_pid;
        pv_last_vacuum_progress := r.prev_last_vacuum_progress;
        pv_vacuum_stalled_cycles := COALESCE(r.prev_vacuum_stalled_cycles, 0);
        pv_last_action := r.prev_last_action;

        /* Progress fingerprint; unchanged across samples of the same backend = stuck. */
        IF r.vacuum_pid IS NOT NULL THEN
            cur_vacuum_progress := format('%s|%s|%s|%s|%s|%s|%s',
                                          COALESCE(r.phase, '?'),
                                          COALESCE(r.heap_blks_total, -1),
                                          COALESCE(r.heap_blks_scanned, -1),
                                          COALESCE(r.heap_blks_vacuumed, -1),
                                          COALESCE(r.indexes_processed, -1),
                                          COALESCE(r.index_vacuum_count, -1),
                                          COALESCE(r.dead_tuple_bytes, -1));
            IF pv_last_vacuum_pid IS NOT DISTINCT FROM r.vacuum_pid
               AND pv_last_vacuum_progress IS NOT DISTINCT FROM cur_vacuum_progress THEN
                vacuum_stalled_cycles := pv_vacuum_stalled_cycles + 1;
            ELSE
                vacuum_stalled_cycles := 0;
            END IF;
        ELSE
            cur_vacuum_progress := NULL;
            vacuum_stalled_cycles := 0;
        END IF;

        /* Horizon past the stall line: no vacuum can help, report the blocker instead (XID paths only). */
        xid_horizon_blocked := horizon_age IS NOT NULL
                               AND horizon_age >= stall_xid_age;

        /* Takeover needs stall-line age + minimum runtime + N frozen samples; age alone never cancels. */
        emergency_takeover := av_wraparound_running
            AND av_elapsed_seconds >= p.emergency_takeover_min_runtime_seconds
            AND vacuum_stalled_cycles >= p.emergency_takeover_stall_samples
            AND (r.mxid_age >= stall_mxid_age
                 OR (NOT xid_horizon_blocked
                     AND r.xid_age >= stall_xid_age));

        emergency_due := emergency_takeover
            OR (r.vacuum_pid IS NULL
                AND (r.mxid_age >= stall_mxid_age
                     OR (NOT xid_horizon_blocked
                         AND r.xid_age >= stall_xid_age)));

        IF emergency_due THEN
            relation_state := 'wraparound_critical';
            critical_seen := true;
            emergency_relation_count := emergency_relation_count + 1;
            IF emergency_takeover THEN
                reason := format('Anti-wraparound autovacuum (pid %s) has been running %s s on this table and has shown zero observable progress for %s consecutive checks (frozen at phase %s, heap %s/%s blocks, %s index pass(es)) while the age (%s) is past the stall line (%s, XID headroom %s s); taking over with the index-skipping profile.',
                                 r.vacuum_pid, round(av_elapsed_seconds),
                                 vacuum_stalled_cycles,
                                 COALESCE(r.phase, '?'),
                                 COALESCE(r.heap_blks_scanned, 0), COALESCE(r.heap_blks_total, 0),
                                 COALESCE(r.index_vacuum_count, 0),
                                 r.xid_age, stall_xid_age,
                                 COALESCE(round(seconds_until_readonly)::text, 'n/a'));
            ELSE
                reason := format('No anti-wraparound autovacuum has started on this table although its age (%s XIDs / %s MXIDs) is past the stall line (%s/%s = %s x freeze_max_age, capped at the absolute limit %s/%s); the built-in mechanism is not responding.',
                                 r.xid_age, r.mxid_age, stall_xid_age, stall_mxid_age,
                                 trim(trailing '.' from to_char(p.emergency_stall_multiplier, 'FM990.99')),
                                 p.emergency_xid_age, p.emergency_mxid_age);
            END IF;
        ELSIF xid_horizon_blocked AND r.xid_age >= stall_xid_age THEN
            relation_state := 'horizon_blocked';
            reason := format('XID age %s is past the stall line %s, but the cleanup horizon is held at age %s by a %s (%s); VACUUM cannot advance relfrozenxid past the horizon, so emergency escalation is suppressed until the blocker goes away.',
                             r.xid_age, stall_xid_age, horizon_age, horizon_kind, horizon_detail);
        ELSIF xid_ratio >= p.xid_warning_ratio OR mxid_ratio >= p.mxid_warning_ratio THEN
            relation_state := 'wraparound_warning';
            reason := format('XID/MXID age ratio vs freeze_max_age is elevated (xid=%s, mxid=%s); the forced autovacuum will handle this - prioritized only.', to_char(xid_ratio, 'FM990.000'), to_char(mxid_ratio, 'FM990.000'));
        ELSIF pressure_ratio >= p.backlog_critical_ratio THEN
            relation_state := 'backlog_critical';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM9990.00'));
        ELSIF pressure_ratio >= p.backlog_urgent_ratio THEN
            relation_state := 'backlog_urgent';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM9990.00'));
        ELSIF pressure_ratio >= p.backlog_elevated_ratio THEN
            relation_state := 'backlog_elevated';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM9990.00'));
        ELSE
            relation_state := 'normal';
            reason := 'Relation is within configured backlog and wraparound limits.';
        END IF;

        /* Counters saturate at the thresholds they are compared with. */
        IF relation_state = 'normal' THEN
            overdue_cycles := 0;
            healthy_cycles := LEAST(pv_consecutive_healthy + 1,
                                    p.healthy_cycles_before_revert);
        ELSE
            overdue_cycles := LEAST(pv_consecutive_overdue + 1,
                                    p.overdue_cycles_before_recommend);
            healthy_cycles := 0;
            overdue_relation_count := overdue_relation_count + 1;
        END IF;

        effective_target_ratio := COALESCE(r.table_target_ratio, p.target_dead_tuple_ratio);
        effective_target_min := COALESCE(r.table_target_min, p.target_dead_tuple_min);
        effective_target_max := COALESCE(r.table_target_max, p.target_dead_tuple_max);
        effective_scale_min := COALESCE(r.table_scale_min, p.min_scale_factor);
        effective_scale_max := COALESCE(r.table_scale_max, p.max_scale_factor);

        target_dead_tuples := LEAST(
            effective_target_max,
            GREATEST(effective_target_min,
                     ceil(GREATEST(r.live_tuples, r.reltuples, 1) * effective_target_ratio)::bigint)
        );
        desired_threshold := LEAST(
            target_dead_tuples,
            GREATEST(p.threshold_floor,
                     floor(target_dead_tuples * 0.10)::integer)
        );
        desired_scale_factor := GREATEST(
            effective_scale_min,
            LEAST(
                effective_scale_max,
                (target_dead_tuples - desired_threshold)::double precision /
                    GREATEST(r.reltuples, 1)
            )
        );
        desired_max_threshold := GREATEST(desired_threshold, target_dead_tuples)::integer;

        /* Feed the mistuned-baseline detector with this relation's desired triggers. */
        IF backlog_ratio >= p.backlog_elevated_ratio THEN
            dead_overdue_count := dead_overdue_count + 1;
            overdue_scale_factors := overdue_scale_factors || desired_scale_factor;
            overdue_thresholds := overdue_thresholds || desired_threshold;
        END IF;

        target_inserts := LEAST(
            p.target_insert_max,
            GREATEST(p.target_insert_min,
                     ceil(GREATEST(r.live_tuples, r.reltuples, 1)
                          * p.target_insert_ratio)::bigint)
        );
        desired_insert_threshold := LEAST(
            target_inserts,
            GREATEST(p.threshold_floor,
                     floor(target_inserts * 0.10)::integer)
        );
        desired_insert_scale := GREATEST(
            effective_scale_min,
            LEAST(
                effective_scale_max,
                (target_inserts - desired_insert_threshold)::double precision /
                    GREATEST(r.reltuples, 1)
            )
        );

        IF insert_ratio >= p.backlog_elevated_ratio THEN
            insert_overdue_count := insert_overdue_count + 1;
            overdue_insert_scale_factors := overdue_insert_scale_factors || desired_insert_scale;
            overdue_insert_thresholds := overdue_insert_thresholds || desired_insert_threshold;
        END IF;

        /* Trigger recommendation: backlog states with autovacuum active, and never looser than today. */
        desired_values := '{}'::jsonb;
        rec_parts := ARRAY[]::text[];
        IF relation_state LIKE 'backlog_%' AND r.normal_autovacuum_enabled THEN
            IF backlog_ratio >= p.backlog_elevated_ratio THEN
                trigger_keys := jsonb_build_object(
                    'autovacuum_vacuum_threshold', desired_threshold::text,
                    'autovacuum_vacuum_scale_factor', trim(trailing '.' from to_char(desired_scale_factor, 'FM0.999999999')));
                /* The per-table trigger ceiling exists only on PG18+. */
                IF server_vnum >= 180000 THEN
                    trigger_keys := trigger_keys || jsonb_build_object(
                        'autovacuum_vacuum_max_threshold', desired_max_threshold::text);
                END IF;
                IF widespread_dead THEN
                    rec_parts := rec_parts || format(
                        '%s of %s eligible tables were overdue on the dead-tuple side in the last scan: the cluster baseline is being corrected instead of this table''s settings.',
                        prev_dead_overdue, prev_eligible);
                ELSIF target_dead_tuples < vacuum_trigger THEN
                    desired_values := desired_values || trigger_keys;
                    rec_parts := rec_parts || format(
                        'Dead tuples %s are %sx the current trigger of %s (threshold %s + scale factor %s x %s rows%s); firing at %s dead tuples (%s%% of the table) needs threshold %s and scale factor %s%s.',
                        r.dead_tuples, to_char(backlog_ratio, 'FM9990.00'), round(vacuum_trigger)::bigint,
                        r.vacuum_threshold::bigint,
                        trim(trailing '.' from to_char(r.vacuum_scale_factor, 'FM0.9999')),
                        round(GREATEST(r.reltuples, 0))::bigint,
                        CASE WHEN r.vacuum_max_threshold >= 0
                             THEN format(', capped at %s', r.vacuum_max_threshold::bigint) ELSE '' END,
                        target_dead_tuples,
                        trim(trailing '.' from to_char(100 * effective_target_ratio, 'FM990.99')),
                        desired_threshold,
                        trim(trailing '.' from to_char(desired_scale_factor, 'FM0.999999999')),
                        CASE WHEN server_vnum >= 180000
                             THEN format(' (max threshold %s)', desired_max_threshold) ELSE '' END);
                ELSE
                    rec_parts := rec_parts || format(
                        'The current trigger (%s dead tuples) is already at or below the policy target (%s), so the table settings are left alone; the cluster cost pair and worker count carry this backlog.',
                        round(vacuum_trigger)::bigint, target_dead_tuples);
                END IF;
            END IF;

            IF insert_ratio >= p.backlog_elevated_ratio THEN
                insert_keys := jsonb_build_object(
                    'autovacuum_vacuum_insert_threshold', desired_insert_threshold::text,
                    'autovacuum_vacuum_insert_scale_factor', trim(trailing '.' from to_char(desired_insert_scale, 'FM0.999999999')));
                IF widespread_insert THEN
                    rec_parts := rec_parts || format(
                        '%s of %s eligible tables were overdue on the insert side in the last scan: the cluster baseline is being corrected instead of this table''s settings.',
                        prev_insert_overdue, prev_eligible);
                ELSIF target_inserts < insert_trigger THEN
                    desired_values := desired_values || insert_keys;
                    rec_parts := rec_parts || format(
                        'Rows inserted since the last vacuum (%s) are %sx the insert trigger of %s; firing at %s inserted rows needs insert threshold %s and insert scale factor %s.',
                        r.inserts_since_vacuum, to_char(insert_ratio, 'FM9990.00'), round(insert_trigger)::bigint,
                        target_inserts, desired_insert_threshold,
                        trim(trailing '.' from to_char(desired_insert_scale, 'FM0.999999999')));
                ELSE
                    rec_parts := rec_parts || format(
                        'The current insert trigger (%s rows) is already at or below the policy target (%s); the insert settings are left alone.',
                        round(insert_trigger)::bigint, target_inserts);
                END IF;
            END IF;
        END IF;

        /* Cost boost recommendation: severity tier, bounded slots cluster-wide, never below the effective pair. */
        has_existing_cost_boost := pv_rec_status IS NOT NULL
                                   AND pv_recommended ? 'autovacuum_vacuum_cost_limit';
        wants_cost_boost := p.recommend_table_costs
                            AND relation_state <> 'normal'
                            AND relation_state <> 'horizon_blocked'
                            AND (r.normal_autovacuum_enabled OR relation_state LIKE 'wraparound_%')
                            AND (NOT host_pressure OR relation_state = 'wraparound_critical' OR has_existing_cost_boost)
                            AND (has_existing_cost_boost
                                 OR cost_boost_count < p.max_boosted_relations);

        IF wants_cost_boost THEN
            IF relation_state IN ('wraparound_critical', 'backlog_critical') THEN
                tier_cost_limit := p.critical_cost_limit;
                tier_cost_delay := p.critical_cost_delay_ms;
            ELSIF relation_state IN ('wraparound_warning', 'backlog_urgent') THEN
                tier_cost_limit := p.urgent_cost_limit;
                tier_cost_delay := p.urgent_cost_delay_ms;
            ELSE
                tier_cost_limit := p.elevated_cost_limit;
                tier_cost_delay := p.elevated_cost_delay_ms;
            END IF;

            /* The pair this table vacuums under today: its own reloptions, else the cluster pair. */
            eff_cost_limit := CASE WHEN r.cost_limit_reloption IS NULL OR r.cost_limit_reloption::integer < 0
                                   THEN global_cost_limit ELSE r.cost_limit_reloption::integer END;
            eff_cost_delay := CASE WHEN r.cost_delay_reloption IS NULL OR r.cost_delay_reloption::double precision < 0
                                   THEN global_cost_delay ELSE r.cost_delay_reloption::double precision END;
            cost_keys := jsonb_build_object(
                'autovacuum_vacuum_cost_limit', tier_cost_limit::text,
                'autovacuum_vacuum_cost_delay', trim(trailing '.' from to_char(tier_cost_delay, 'FM0.999')));
            IF tier_cost_limit > eff_cost_limit OR tier_cost_delay < eff_cost_delay THEN
                desired_values := desired_values || cost_keys;
                IF NOT has_existing_cost_boost THEN
                    cost_boost_count := cost_boost_count + 1;
                END IF;
                rec_parts := rec_parts || format(
                    '%s tier: a table-level cost limit %s / delay %s ms lets this vacuum run ahead of the effective pair %s / %s ms (boost slot %s of %s); revert it once the table is normal again.',
                    CASE WHEN relation_state IN ('wraparound_critical', 'backlog_critical') THEN 'Critical'
                         WHEN relation_state IN ('wraparound_warning', 'backlog_urgent') THEN 'Urgent'
                         ELSE 'Elevated' END,
                    tier_cost_limit, trim(trailing '.' from to_char(tier_cost_delay, 'FM0.999')),
                    eff_cost_limit, trim(trailing '.' from to_char(eff_cost_delay, 'FM990.99')),
                    cost_boost_count, p.max_boosted_relations);
            END IF;
        END IF;

        /* Built only when a decision row can be written this cycle. */
        relation_json := NULL;
        IF relation_state <> 'normal'
           OR pv_state <> 'normal'
           OR pv_rec_status IS NOT NULL THEN
            relation_json := jsonb_build_object(
                'total_bytes', r.total_bytes,
                'live_tuples', r.live_tuples,
                'dead_tuples', r.dead_tuples,
                'vacuum_trigger', vacuum_trigger,
                'backlog_ratio', backlog_ratio,
                'inserts_since_vacuum', r.inserts_since_vacuum,
                'insert_backlog_ratio', insert_ratio,
                'xid_age', r.xid_age,
                'xid_ratio', xid_ratio,
                'mxid_age', r.mxid_age,
                'mxid_ratio', mxid_ratio,
                'effective_xid_freeze_max_age', r.effective_xid_freeze_max_age,
                'effective_mxid_freeze_max_age', r.effective_mxid_freeze_max_age,
                'normal_autovacuum_enabled', r.normal_autovacuum_enabled,
                'vacuum_pid', r.vacuum_pid,
                'vacuum_phase', r.phase,
                'vacuum_elapsed', r.vacuum_elapsed,
                'heap_blks_total', r.heap_blks_total,
                'heap_blks_scanned', r.heap_blks_scanned,
                'index_vacuum_count', r.index_vacuum_count,
                'max_dead_tuple_bytes', r.max_dead_tuple_bytes,
                'dead_tuple_bytes', r.dead_tuple_bytes,
                'delay_time_ms', r.delay_time,
                'antiwraparound', r.antiwraparound,
                'vacuum_stalled_cycles', vacuum_stalled_cycles
            );
        END IF;

        /* Recommendation lifecycle: open (SQL waits) -> applied (reloptions match) -> revert (boost no longer needed). */
        new_rec_status := NULL;
        new_recommended := NULL;
        new_previous := NULL;
        new_reason := NULL;
        new_recommended_at := NULL;
        new_applied_at := NULL;

        /* Is our last recommendation in place, key for key? */
        keys_match := false;
        IF pv_rec_status IS NOT NULL THEN
            SELECT NOT EXISTS (
                SELECT 1 FROM jsonb_each_text(pv_recommended) AS k(option_name, option_value)
                WHERE (SELECT split_part(o, '=', 2) FROM unnest(r.reloptions) AS o
                       WHERE split_part(o, '=', 1) = k.option_name LIMIT 1)::numeric
                      IS DISTINCT FROM k.option_value::numeric)
            INTO keys_match;
        END IF;

        IF keys_match THEN
            /* Applied: frozen as recommended (never re-tuned behind the operator) until the table is healthy. */
            IF relation_state <> 'normal' THEN
                new_rec_status := 'applied';
                new_recommended := pv_recommended;
                new_previous := COALESCE(pv_previous, '{}'::jsonb);
                new_reason := pv_reason;
                new_recommended_at := COALESCE(pv_recommended_at, clock_timestamp());
                new_applied_at := COALESCE(pv_applied_at, clock_timestamp());
            ELSIF pv_recommended ? 'autovacuum_vacuum_cost_limit' THEN
                /* Trigger settings stay with the operator; the cost boost is incident tuning and gets a revert. */
                IF pv_rec_status = 'revert' OR healthy_cycles >= p.healthy_cycles_before_revert THEN
                    new_rec_status := 'revert';
                    cost_keys := pv_recommended
                                 - 'autovacuum_vacuum_threshold' - 'autovacuum_vacuum_scale_factor'
                                 - 'autovacuum_vacuum_max_threshold'
                                 - 'autovacuum_vacuum_insert_threshold' - 'autovacuum_vacuum_insert_scale_factor';
                    new_recommended := cost_keys;
                    SELECT COALESCE(jsonb_object_agg(k, COALESCE(pv_previous, '{}'::jsonb) -> k), '{}'::jsonb)
                    INTO new_previous
                    FROM jsonb_object_keys(cost_keys) AS k;
                    new_reason := CASE WHEN pv_rec_status = 'revert' THEN pv_reason ELSE format(
                        'The relation has been normal for %s check(s); the table-level cost boost (%s / %s ms) recommended during the backlog is no longer needed and takes budget from other vacuums.',
                        healthy_cycles, cost_keys ->> 'autovacuum_vacuum_cost_limit',
                        cost_keys ->> 'autovacuum_vacuum_cost_delay') END;
                ELSE
                    new_rec_status := 'applied';
                    new_recommended := pv_recommended;
                    new_previous := COALESCE(pv_previous, '{}'::jsonb);
                    new_reason := pv_reason;
                END IF;
                new_recommended_at := COALESCE(pv_recommended_at, clock_timestamp());
                new_applied_at := COALESCE(pv_applied_at, clock_timestamp());
            END IF;
            /* Trigger-only settings on a healthy table are the operator's now: the row is dropped. */
        ELSE
            /* Nothing of ours in place (never recommended, still open, or changed by the operator): recommend afresh. */
            recommend_now := desired_values <> '{}'::jsonb
                             AND (overdue_cycles >= p.overdue_cycles_before_recommend OR pv_rec_status = 'open');
            IF recommend_now THEN
                SELECT NOT EXISTS (
                    SELECT 1 FROM jsonb_each_text(desired_values) AS k(option_name, option_value)
                    WHERE (SELECT split_part(o, '=', 2) FROM unnest(r.reloptions) AS o
                           WHERE split_part(o, '=', 1) = k.option_name LIMIT 1)::numeric
                          IS DISTINCT FROM k.option_value::numeric)
                INTO keys_match;
                /* Already matching with no earlier recommendation = the operator's own settings; nothing to say. */
                IF NOT keys_match THEN
                    new_rec_status := 'open';
                    new_recommended := desired_values;
                    /* What the operator has today for these keys; null = not set, so the revert is a RESET. */
                    SELECT jsonb_object_agg(k.option_name,
                               (SELECT split_part(o, '=', 2) FROM unnest(r.reloptions) AS o
                                WHERE split_part(o, '=', 1) = k.option_name LIMIT 1))
                    INTO new_previous
                    FROM jsonb_object_keys(desired_values) AS k(option_name);
                    new_reason := CASE WHEN pv_rec_status = 'open' AND pv_recommended = desired_values THEN pv_reason
                                       ELSE array_to_string(rec_parts, ' ') END;
                    new_recommended_at := CASE WHEN pv_rec_status = 'open' THEN pv_recommended_at
                                               ELSE clock_timestamp() END;
                END IF;
            END IF;
        END IF;

        IF new_rec_status = 'open' THEN
            recommended_count := recommended_count + 1;
        END IF;

        action_name := CASE new_rec_status
                           WHEN 'open' THEN 'recommend_reloptions'
                           WHEN 'applied' THEN 'recommendation_applied'
                           WHEN 'revert' THEN 'recommend_revert'
                           ELSE CASE
                               WHEN relation_state = 'horizon_blocked' THEN 'horizon_blocked'
                               WHEN relation_state LIKE 'backlog_%' AND NOT r.normal_autovacuum_enabled THEN 'autovacuum_disabled'
                               WHEN relation_state = 'normal' THEN 'recovered'
                               ELSE 'observe'
                           END
                       END;

        IF relation_state = 'normal' AND pv_state <> 'normal' THEN
            reason := format('Relation returned to normal (was %s).', pv_state)
                      || CASE WHEN new_rec_status IS NOT NULL
                              THEN ' The applied table settings stay listed in table_recommendations.'
                              ELSE '' END;
        ELSIF new_rec_status = 'revert' THEN
            reason := new_reason;
        ELSIF cardinality(rec_parts) > 0 THEN
            reason := reason || ' ' || array_to_string(rec_parts, ' ');
        END IF;

        /* Transition log: one row when the (state, action) pair changes; the recommendation itself lives in table_state. */
        IF (relation_state <> 'normal' OR pv_state <> 'normal' OR new_rec_status IS NOT NULL)
           AND (pv_state IS DISTINCT FROM relation_state OR pv_last_action IS DISTINCT FROM action_name) THEN
            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                'action', action_name, 'reason', reason, 'host_metrics', host_json,
                'relation_metrics', relation_json,
                'proposed_reloptions', COALESCE(new_recommended, NULLIF(desired_values, '{}'::jsonb)),
                'applied', false, 'error', NULL);
        END IF;

        emergency_gate := COALESCE(input -> 'emergency' -> r.relid::text, '{}'::jsonb);
        IF emergency_due
           AND p.emergency_vacuum_enabled
           AND NOT p.dry_run
           AND (r.vacuum_pid IS NULL OR emergency_takeover)
           AND NOT COALESCE((emergency_gate ->> 'active')::boolean, false)
           AND NOT COALESCE((emergency_gate ->> 'retry_blocked')::boolean, false)
           /* Hard daily cap against any remaining retry-storm shape. */
           AND COALESCE((emergency_gate ->> 'failed_24h')::integer, 0) < 8
        THEN
            emergency_work_mem_mb := CASE
                WHEN host_metrics_available THEN
                    LEAST(
                        p.emergency_work_mem_max_mb,
                        GREATEST(
                            p.emergency_work_mem_min_mb,
                            floor((host_mem_available_bytes / 1048576.0)
                                  * p.work_mem_available_fraction)::integer
                        )
                    )
                ELSE p.emergency_work_mem_min_mb
            END;

            /* Takeover: cancel the stuck autovacuum (never a manual vacuum). */
            IF emergency_takeover THEN
                PERFORM pg_catalog.pg_cancel_backend(r.vacuum_pid);
            END IF;

            out_emergency := out_emergency || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'reason', reason,
                /* Deadline first (claim order), then age in millions of XIDs. */
                'priority', 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                'work_mem_mb', emergency_work_mem_mb,
                'cost_limit', CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                                   ELSE p.emergency_cost_limit END,
                'cost_delay_ms', CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                                      ELSE p.emergency_cost_delay_ms END,
                'lock_timeout_ms', p.emergency_lock_timeout_ms,
                'is_wraparound', true,
                'deadline_seconds', seconds_until_readonly,
                'takeover', emergency_takeover);

            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                'action', CASE WHEN emergency_takeover THEN 'queue_emergency_takeover'
                               ELSE 'queue_emergency_vacuum' END,
                'reason', reason, 'host_metrics', host_json, 'relation_metrics', relation_json,
                'proposed_reloptions', NULL, 'applied', true, 'error', NULL);
        END IF;

        /* Persist only what a later cycle needs; rewrite on state change or hourly heartbeat. */
        state_needed := relation_state <> 'normal'
                        OR new_rec_status IS NOT NULL
                        OR r.vacuum_pid IS NOT NULL;

        IF NOT state_needed THEN
            IF r.state_exists THEN
                out_state_delete := out_state_delete || to_jsonb(r.relid);
            END IF;
        ELSIF NOT r.state_exists
              OR r.prev_relation_name IS DISTINCT FROM r.fqname
              OR r.prev_recommendation_status IS DISTINCT FROM new_rec_status
              OR r.prev_recommended_reloptions IS DISTINCT FROM new_recommended
              OR r.prev_previous_reloptions IS DISTINCT FROM new_previous
              OR r.prev_recommendation_reason IS DISTINCT FROM new_reason
              OR r.prev_recommended_at IS DISTINCT FROM new_recommended_at
              OR r.prev_applied_at IS DISTINCT FROM new_applied_at
              OR r.prev_state IS DISTINCT FROM relation_state
              OR r.prev_consecutive_overdue IS DISTINCT FROM overdue_cycles
              OR r.prev_consecutive_healthy IS DISTINCT FROM healthy_cycles
              OR r.prev_last_vacuum_pid IS DISTINCT FROM r.vacuum_pid
              OR r.prev_last_vacuum_progress IS DISTINCT FROM cur_vacuum_progress
              OR r.prev_vacuum_stalled_cycles IS DISTINCT FROM vacuum_stalled_cycles
              OR r.prev_last_action IS DISTINCT FROM action_name
              OR r.prev_last_seen_at < clock_timestamp() - interval '1 hour'
        THEN
            out_state := out_state || jsonb_build_object(
                'relation_oid', r.relid, 'relation_name', r.fqname,
                'recommendation_status', new_rec_status,
                'recommended_reloptions', new_recommended,
                'previous_reloptions', new_previous,
                'recommendation_reason', new_reason,
                'recommended_at', new_recommended_at,
                'applied_at', new_applied_at,
                'state', relation_state,
                'consecutive_overdue', overdue_cycles,
                'consecutive_healthy', healthy_cycles,
                'last_dead_tuples', r.dead_tuples, 'last_live_tuples', r.live_tuples,
                'last_trigger', vacuum_trigger, 'last_backlog_ratio', backlog_ratio,
                'last_inserts_since_vacuum', r.inserts_since_vacuum,
                'last_insert_backlog_ratio', insert_ratio,
                'last_xid_age', r.xid_age, 'last_mxid_age', r.mxid_age,
                'last_vacuum_pid', r.vacuum_pid, 'last_vacuum_progress', cur_vacuum_progress,
                'vacuum_stalled_cycles', vacuum_stalled_cycles,
                'last_action', action_name);
        END IF;
    END LOOP;

    /* Rows of relations that no longer exist in this database (dropped or re-created) are removed. */
    SELECT out_state_delete || COALESCE(jsonb_agg(to_jsonb(x.relation_oid)), '[]'::jsonb)
    INTO out_state_delete
    FROM jsonb_to_recordset(COALESCE(input -> 'table_state', '[]'::jsonb)) AS x(relation_oid oid)
    WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = x.relation_oid);

    /* Safety scan: relations the performance scan skipped; emergency branch only, never cancels. */
    FOR r IN
        WITH tpol AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
                   AS x(schema_name name, relation_name name, enabled boolean)
        ),
        active_vacuum AS
        (
            SELECT pv.relid, pv.pid AS vacuum_pid
            FROM pg_stat_progress_vacuum pv
            WHERE pv.datid = (SELECT d.oid
                              FROM pg_catalog.pg_database d
                              WHERE d.datname = pg_catalog.current_database())
        ),
        base AS
        (
            SELECT
                c.oid AS relid,
                format('%I.%I', n.nspname, c.relname) AS fqname,
                n.nspname,
                c.relkind,
                c.relpages,
                GREATEST(age(c.relfrozenxid),
                         COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
                GREATEST(mxid_age(c.relminmxid),
                         COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
                CASE
                    WHEN opt.ro_freeze_max_age IS NULL OR opt.ro_freeze_max_age::bigint < 0
                    THEN freeze_max_age
                    ELSE LEAST(freeze_max_age, opt.ro_freeze_max_age::bigint)
                END AS effective_xid_freeze_max_age,
                CASE
                    WHEN opt.ro_multixact_freeze_max_age IS NULL OR opt.ro_multixact_freeze_max_age::bigint < 0
                    THEN multixact_freeze_max_age
                    ELSE LEAST(multixact_freeze_max_age, opt.ro_multixact_freeze_max_age::bigint)
                END AS effective_mxid_freeze_max_age,
                av.vacuum_pid,
                COALESCE(tp.enabled, true) AS tp_enabled,
                CASE
                    WHEN c.relpages > 0 THEN c.relpages::bigint * block_size
                    WHEN pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)
                         >= p.min_table_bytes / block_size THEN pg_total_relation_size(c.oid)
                    ELSE 0::bigint
                END AS total_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
            LEFT JOIN active_vacuum av ON av.relid = c.oid
            LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
            CROSS JOIN LATERAL (
                SELECT
                    max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_freeze_max_age') AS ro_freeze_max_age,
                    max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_multixact_freeze_max_age') AS ro_multixact_freeze_max_age
                FROM unnest(c.reloptions) AS o
            ) opt
            WHERE c.relkind IN ('r', 'm')
              AND c.relpersistence <> 't'
              AND n.nspname <> 'pg_toast'
        )
        SELECT base.*
        FROM base
        /* only relations the performance scan above did NOT evaluate */
        WHERE NOT (base.relkind = 'r'
                   AND NOT (base.nspname = ANY (p.excluded_schemas))
                   AND base.tp_enabled
                   AND base.total_bytes >= p.min_table_bytes)
          /* age already past this relation's stall line */
          AND (base.xid_age >= LEAST(p.emergency_xid_age,
                                     ceil(p.emergency_stall_multiplier * base.effective_xid_freeze_max_age)::bigint)
               OR base.mxid_age >= LEAST(p.emergency_mxid_age,
                                         ceil(p.emergency_stall_multiplier * base.effective_mxid_freeze_max_age)::bigint))
    LOOP
        stall_xid_age := LEAST(p.emergency_xid_age,
                               ceil(p.emergency_stall_multiplier
                                    * COALESCE(NULLIF(r.effective_xid_freeze_max_age, 0),
                                               freeze_max_age))::bigint);
        stall_mxid_age := LEAST(p.emergency_mxid_age,
                                ceil(p.emergency_stall_multiplier
                                     * COALESCE(NULLIF(r.effective_mxid_freeze_max_age, 0),
                                                multixact_freeze_max_age))::bigint);

        xid_horizon_blocked := horizon_age IS NOT NULL
                               AND horizon_age >= stall_xid_age;

        /* No per-relation progress state here, so never take over a running vacuum. */
        emergency_due := r.vacuum_pid IS NULL
            AND (r.mxid_age >= stall_mxid_age
                 OR (NOT xid_horizon_blocked
                     AND r.xid_age >= stall_xid_age));

        IF NOT emergency_due THEN
            IF xid_horizon_blocked AND r.xid_age >= stall_xid_age THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname,
                    'state', 'horizon_blocked', 'action', 'horizon_blocked',
                    'reason', format('Safety scan: XID age %s is past the stall line %s, but the cleanup horizon is held at age %s by a %s (%s); emergency escalation is suppressed until the blocker goes away.',
                                     r.xid_age, stall_xid_age, horizon_age, horizon_kind, horizon_detail),
                    'host_metrics', host_json,
                    'relation_metrics', jsonb_build_object('xid_age', r.xid_age, 'mxid_age', r.mxid_age, 'safety_scan', true),
                    'proposed_reloptions', NULL, 'applied', false, 'error', NULL);
            END IF;
            CONTINUE;
        END IF;

        reason := format('Safety scan: no autovacuum is running although XID age %s / MXID age %s is past the stall line (%s / %s); the relation was invisible to the performance scan (size/schema/table-policy filters).',
                         r.xid_age, r.mxid_age, stall_xid_age, stall_mxid_age);
        critical_seen := true;
        emergency_relation_count := emergency_relation_count + 1;

        IF p.dry_run OR NOT p.emergency_vacuum_enabled THEN
            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname,
                'state', 'wraparound_critical', 'action', 'propose_emergency_vacuum',
                'reason', reason, 'host_metrics', host_json,
                'relation_metrics', jsonb_build_object('xid_age', r.xid_age, 'mxid_age', r.mxid_age, 'safety_scan', true),
                'proposed_reloptions', NULL, 'applied', false, 'error', NULL);
            CONTINUE;
        END IF;

        emergency_gate := COALESCE(input -> 'emergency' -> r.relid::text, '{}'::jsonb);
        IF NOT COALESCE((emergency_gate ->> 'active')::boolean, false)
           AND NOT COALESCE((emergency_gate ->> 'retry_blocked')::boolean, false)
           AND COALESCE((emergency_gate ->> 'failed_24h')::integer, 0) < 8
        THEN
            emergency_work_mem_mb := CASE
                WHEN host_metrics_available THEN
                    LEAST(
                        p.emergency_work_mem_max_mb,
                        GREATEST(
                            p.emergency_work_mem_min_mb,
                            floor((host_mem_available_bytes / 1048576.0)
                                  * p.work_mem_available_fraction)::integer
                        )
                    )
                ELSE p.emergency_work_mem_min_mb
            END;

            out_emergency := out_emergency || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'reason', reason,
                'priority', 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                'work_mem_mb', emergency_work_mem_mb,
                'cost_limit', CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                                   ELSE p.emergency_cost_limit END,
                'cost_delay_ms', CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                                      ELSE p.emergency_cost_delay_ms END,
                'lock_timeout_ms', p.emergency_lock_timeout_ms,
                'is_wraparound', true,
                'deadline_seconds', CASE WHEN xid_rate IS NOT NULL AND xid_rate > 0
                                         THEN GREATEST(2147483648 - 3000000 - r.xid_age, 0)::double precision / xid_rate
                                    END,
                'takeover', false);

            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname,
                'state', 'wraparound_critical', 'action', 'queue_emergency_vacuum',
                'reason', reason, 'host_metrics', host_json,
                'relation_metrics', jsonb_build_object('xid_age', r.xid_age, 'mxid_age', r.mxid_age, 'safety_scan', true),
                'proposed_reloptions', NULL, 'applied', true, 'error', NULL);
        END IF;
    END LOOP;

    /* Local medians of the desired trigger settings (the global controller weights them by count). */
    IF dead_overdue_count > 0 THEN
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_scale
        FROM unnest(overdue_scale_factors) AS v;
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_thresh
        FROM unnest(overdue_thresholds) AS v;
    END IF;
    IF insert_overdue_count > 0 THEN
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_ins_scale
        FROM unnest(overdue_insert_scale_factors) AS v;
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_ins_thresh
        FROM unnest(overdue_insert_thresholds) AS v;
    END IF;

    /* Never-analyzed tables: largest first within a time budget; graduated under host pressure. */
    analyze_budget_ms := CASE WHEN host_pressure THEN 0
                              WHEN moderate_pressure THEN p.analyze_missing_stats_budget_ms / 4
                              ELSE p.analyze_missing_stats_budget_ms END;
    analyze_started_at := clock_timestamp();
    IF p.analyze_missing_stats AND analyze_budget_ms > 0 THEN
        FOR r IN
            WITH tpol AS MATERIALIZED (
                SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
                       AS x(schema_name name, relation_name name, enabled boolean)
            ),
            proposed AS (
                SELECT (v #>> '{}')::oid AS relid
                FROM jsonb_array_elements(COALESCE(input -> 'proposed_analyze', '[]'::jsonb)) AS v
            )
            SELECT c.oid AS relid,
                   format('%I.%I', n.nspname, c.relname) AS fqname,
                   pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
            WHERE c.relkind = 'r'
              AND c.relpersistence <> 't'
              AND NOT (n.nspname = ANY (p.excluded_schemas))
              AND COALESCE(tp.enabled, true)
              AND pg_stat_get_live_tuples(c.oid) > 0
              AND pg_stat_get_last_analyze_time(c.oid) IS NULL
              AND pg_stat_get_last_autoanalyze_time(c.oid) IS NULL
              /* Dry run proposes each table once; the transition log must not repeat per check. */
              AND (NOT p.dry_run
                   OR NOT EXISTS (SELECT 1 FROM proposed pr WHERE pr.relid = c.oid))
            ORDER BY pg_stat_get_live_tuples(c.oid) DESC
        LOOP
            /* Budget is checked between statements; a running ANALYZE is never interrupted. */
            EXIT WHEN analyze_count > 0
                      AND extract(epoch FROM clock_timestamp() - analyze_started_at) * 1000
                          >= analyze_budget_ms;
            analyze_count := analyze_count + 1;
            applied := false;
            action_error := NULL;
            action_name := CASE WHEN p.dry_run THEN 'propose_analyze' ELSE 'analyze' END;
            reason := format('Table has %s live rows but has never been analyzed (manually or by autoanalyze); the planner is working from default estimates.',
                             r.live_tuples);

            IF NOT p.dry_run THEN
                BEGIN
                    PERFORM set_config('lock_timeout', p.lock_timeout_ms::text || 'ms', true);
                    EXECUTE format('ANALYZE %s', r.fqname);
                    applied := true;
                EXCEPTION
                    WHEN OTHERS THEN
                        GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
                END;
            END IF;

            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname,
                'state', 'statistics_missing', 'action', action_name, 'reason', reason,
                'host_metrics', host_json,
                'relation_metrics', jsonb_build_object('live_tuples', r.live_tuples),
                'proposed_reloptions', NULL, 'applied', applied, 'error', action_error);
        END LOOP;
    END IF;

    PERFORM pg_catalog.set_config('adaptive_autovacuum.worker_output', jsonb_build_object(
        'ok', true,
        'extension_installed', extension_installed,
        'summary', jsonb_build_object(
            'table_count', table_count,
            'eligible', scanned_relation_count,
            'overdue', overdue_relation_count,
            'dead_overdue', dead_overdue_count,
            'insert_overdue', insert_overdue_count,
            'fleet_max_target', fleet_max_target,
            'median_scale', local_median_scale,
            'median_thresh', local_median_thresh,
            'median_ins_scale', local_median_ins_scale,
            'median_ins_thresh', local_median_ins_thresh,
            'debt_tuples', total_debt_tuples,
            'emergency_relations', emergency_relation_count,
            'critical_seen', critical_seen,
            'max_xid_age', db_max_xid_age,
            'max_mxid_age', db_max_mxid_age,
            'recommended', recommended_count,
            'analyzed', analyze_count,
            'scan_seconds', extract(epoch FROM clock_timestamp() - scan_started_at)),
        'table_state', out_state,
        'table_state_delete', out_state_delete,
        'decisions', out_decisions,
        'emergency_requests', out_emergency)::text, false);
END
$aav_body$;

COMMENT ON FUNCTION adaptive_autovacuum._database_program() IS
'Body of the anonymous PL/pgSQL block the database worker runs inside each managed database. It reads adaptive_autovacuum.worker_input (policy, previous table state, gates) and leaves its result in adaptive_autovacuum.worker_output; it uses no extension objects, so managed databases need no CREATE EXTENSION. It never changes table settings: it recommends them (table_recommendations); its only DDL is ANALYZE for never-analyzed tables.';

/* ---------- control plane: functions the controller process calls in the control database ---------- */

/* Sweep bookkeeping: a new generation starts; returns its number. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._begin_generation()
RETURNS bigint
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    UPDATE adaptive_autovacuum.controller_state
    SET cluster_generation = cluster_generation + 1,
        last_sweep_started_at = clock_timestamp()
    WHERE only_row
    RETURNING cluster_generation
$$;

/* Discovery: every connectable non-template database, policy include/exclude applied; oldest first. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._discover_databases()
RETURNS TABLE (database_oid oid, database_name name, excluded boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    inc text[];
    exc text[];
BEGIN
    SELECT p.included_databases, p.excluded_databases INTO inc, exc
    FROM adaptive_autovacuum.policy p WHERE p.singleton;

    /* Dropped databases take their state with them. */
    DELETE FROM adaptive_autovacuum.table_state ts
    WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database d WHERE d.oid = ts.database_oid);
    DELETE FROM adaptive_autovacuum.database_state ds
    WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database d WHERE d.oid = ds.database_oid);

    RETURN QUERY
    WITH found AS (
        SELECT d.oid, d.datname,
               ((inc IS NOT NULL AND NOT (d.datname LIKE ANY (inc)))
                OR d.datname LIKE ANY (COALESCE(exc, ARRAY[]::text[]))) AS is_excluded,
               GREATEST(age(d.datfrozenxid), mxid_age(d.datminmxid)) AS dat_age
        FROM pg_catalog.pg_database d
        WHERE d.datallowconn
          AND NOT d.datistemplate
    ),
    upsert AS (
        INSERT INTO adaptive_autovacuum.database_state AS ds
            (database_oid, database_name, status)
        SELECT f.oid, f.datname, CASE WHEN f.is_excluded THEN 'excluded' ELSE 'pending' END
        FROM found f
        ON CONFLICT ON CONSTRAINT database_state_pkey DO UPDATE
        SET database_name = EXCLUDED.database_name,
            last_seen_at = clock_timestamp(),
            status = CASE WHEN EXCLUDED.status = 'excluded' THEN 'excluded'
                          WHEN ds.status = 'excluded' THEN 'pending'
                          ELSE ds.status END
        RETURNING ds.database_oid
    )
    SELECT f.oid, f.datname, f.is_excluded
    FROM found f
    ORDER BY f.dat_age DESC, f.oid;
END
$$;

/* Everything one database worker needs, as one JSON document; also stamps the scan start. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._worker_input(
    dboid oid,
    dbname name,
    generation bigint,
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    p adaptive_autovacuum.policy%ROWTYPE;
    cs adaptive_autovacuum.controller_state%ROWTYPE;
    host_memory_percent double precision;
    host_load_per_cpu double precision;
    host_metrics_available boolean;
    host_pressure boolean;
    moderate_pressure boolean;
    host_json jsonb;
    doc jsonb;
BEGIN
    SELECT * INTO p FROM adaptive_autovacuum.policy WHERE singleton;
    SELECT * INTO cs FROM adaptive_autovacuum.controller_state WHERE only_row;

    host_metrics_available := COALESCE(host_mem_total_bytes, 0) > 0
                              AND COALESCE(host_mem_available_bytes, -1) >= 0;
    host_cpu_count := GREATEST(COALESCE(host_cpu_count, 1), 1);
    host_load1 := GREATEST(COALESCE(host_load1, 0), 0);
    host_mem_available_bytes := GREATEST(COALESCE(host_mem_available_bytes, 0), 0);
    host_mem_total_bytes := GREATEST(COALESCE(host_mem_total_bytes, 0), 0);
    host_memory_percent := CASE WHEN host_mem_total_bytes > 0
                                THEN 100.0 * host_mem_available_bytes / host_mem_total_bytes
                                ELSE 100.0 END;
    host_load_per_cpu := host_load1 / host_cpu_count;

    /* CPU and memory pressure are fresh; the WAL-rate flag comes from the previous sweep's sample. */
    host_pressure := host_memory_percent < p.low_memory_percent
                     OR host_load_per_cpu > p.high_load_per_cpu
                     OR cs.storage_pressure;
    moderate_pressure := host_load_per_cpu > p.high_load_per_cpu / 2
                         OR host_memory_percent < 2 * p.low_memory_percent
                         OR (p.high_wal_mbps > 0 AND cs.wal_rate_mbps IS NOT NULL
                             AND cs.wal_rate_mbps >= p.high_wal_mbps / 2);

    host_json := jsonb_build_object(
        'load1', host_load1,
        'cpu_count', host_cpu_count,
        'load_per_cpu', host_load_per_cpu,
        'mem_available_bytes', host_mem_available_bytes,
        'mem_total_bytes', host_mem_total_bytes,
        'mem_available_percent', host_memory_percent,
        'memory_metrics_available', host_metrics_available,
        'wal_rate_mbps', cs.wal_rate_mbps,
        'storage_pressure', cs.storage_pressure,
        'pressure', host_pressure,
        'moderate_pressure', moderate_pressure);

    UPDATE adaptive_autovacuum.database_state
    SET last_scan_started_at = clock_timestamp(),
        last_seen_at = clock_timestamp()
    WHERE database_oid = dboid;

    doc := jsonb_build_object(
        'generation', generation,
        'database_oid', dboid,
        'database_name', dbname,
        'policy', to_jsonb(p) - 'singleton' - 'updated_at' - 'updated_by',
        'host', host_json,
        'cluster', jsonb_build_object(
            'xid_rate', cs.xid_rate,
            /* Previous scan of this database: a widely overdue fleet means the baseline is wrong, not the tables. */
            'prev_eligible', (SELECT ds.eligible_relations FROM adaptive_autovacuum.database_state ds WHERE ds.database_oid = dboid),
            'prev_dead_overdue', (SELECT ds.dead_overdue FROM adaptive_autovacuum.database_state ds WHERE ds.database_oid = dboid),
            'prev_insert_overdue', (SELECT ds.insert_overdue FROM adaptive_autovacuum.database_state ds WHERE ds.database_oid = dboid),
            /* Cost-boost recommendations standing in the other databases share the slot limit. */
            'boosted_relations_elsewhere',
                (SELECT count(*) FROM adaptive_autovacuum.table_state ts
                 WHERE ts.database_oid <> dboid
                   AND ts.recommendation_status IS NOT NULL
                   AND ts.recommended_reloptions ? 'autovacuum_vacuum_cost_limit')),
        'table_policy',
            (SELECT COALESCE(jsonb_agg(to_jsonb(tp) - 'database_name' - 'note' - 'updated_at' - 'updated_by'), '[]'::jsonb)
             FROM adaptive_autovacuum.table_policy tp
             WHERE tp.database_name = dbname),
        'table_state',
            (SELECT COALESCE(jsonb_agg(to_jsonb(ts) - 'database_oid' - 'database_name'), '[]'::jsonb)
             FROM adaptive_autovacuum.table_state ts
             WHERE ts.database_oid = dboid),
        'emergency',
            (SELECT COALESCE(jsonb_object_agg(g.relid::text, g.gate), '{}'::jsonb)
             FROM (SELECT q.relid,
                          jsonb_build_object(
                              'active', bool_or(q.status IN ('pending', 'running')),
                              'retry_blocked', bool_or(q.status = 'failed' AND q.next_retry_at > clock_timestamp()),
                              'failed_24h', count(*) FILTER (WHERE q.status = 'failed'
                                                               AND q.finished_at > clock_timestamp() - interval '24 hours')) AS gate
                   FROM adaptive_autovacuum.emergency_queue q
                   WHERE q.database_oid = dboid
                   GROUP BY q.relid) g),
        'proposed_analyze',
            (SELECT COALESCE(jsonb_agg(DISTINCT d.relid), '[]'::jsonb)
             FROM adaptive_autovacuum.decisions d
             WHERE d.database_oid = dboid AND d.action = 'propose_analyze'));

    RETURN doc::text;
END
$$;

/* A worker that crashed, timed out or reported an error: the database keeps its old summary, marked failed. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._record_database_failure(
    dboid oid, dbname name, generation bigint, error_text text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    INSERT INTO adaptive_autovacuum.database_state AS ds
        (database_oid, database_name, status, last_error, last_seen_at)
    VALUES (dboid, dbname, 'failed', error_text, clock_timestamp())
    ON CONFLICT ON CONSTRAINT database_state_pkey DO UPDATE
    SET status = 'failed',
        last_error = EXCLUDED.last_error,
        last_seen_at = clock_timestamp()
$$;

/* Persist one worker's result centrally: table state, decisions, emergency requests, database summary. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._absorb_database_result(
    dboid oid,
    dbname name,
    generation bigint,
    doc jsonb)
RETURNS TABLE (
    ok boolean,
    eligible integer,
    overdue integer,
    emergency_relations integer,
    extension_installed boolean,
    emergency_pending boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    s jsonb;
    prev_debt bigint;
    prev_velocity double precision;
    prev_completed_at timestamptz;
    interval_seconds double precision;
    velocity double precision;
    debt bigint;
    n_emergency integer;
    n_overdue integer;
BEGIN
    IF NOT COALESCE((doc ->> 'ok')::boolean, false) THEN
        PERFORM adaptive_autovacuum._record_database_failure(
            dboid, dbname, generation, COALESCE(doc ->> 'error', 'worker returned no result'));
        RETURN QUERY SELECT false, 0, 0, 0, false, false;
        RETURN;
    END IF;

    s := doc -> 'summary';

    DELETE FROM adaptive_autovacuum.table_state ts
    WHERE ts.database_oid = dboid
      AND ts.relation_oid IN (SELECT (v #>> '{}')::oid
                              FROM jsonb_array_elements(COALESCE(doc -> 'table_state_delete', '[]'::jsonb)) AS v);

    INSERT INTO adaptive_autovacuum.table_state AS target
        (database_oid, relation_oid, database_name, relation_name,
         recommendation_status, recommended_reloptions, previous_reloptions, recommendation_reason,
         recommended_at, applied_at,
         state, consecutive_overdue, consecutive_healthy, last_seen_at,
         last_dead_tuples, last_live_tuples, last_trigger, last_backlog_ratio,
         last_inserts_since_vacuum, last_insert_backlog_ratio, last_xid_age, last_mxid_age,
         last_vacuum_pid, last_vacuum_progress, vacuum_stalled_cycles, last_action)
    SELECT dboid, x.relation_oid, dbname, x.relation_name,
           x.recommendation_status, x.recommended_reloptions, x.previous_reloptions, x.recommendation_reason,
           x.recommended_at, x.applied_at,
           COALESCE(x.state, 'normal'), COALESCE(x.consecutive_overdue, 0),
           COALESCE(x.consecutive_healthy, 0), clock_timestamp(),
           x.last_dead_tuples, x.last_live_tuples, x.last_trigger, x.last_backlog_ratio,
           x.last_inserts_since_vacuum, x.last_insert_backlog_ratio, x.last_xid_age, x.last_mxid_age,
           x.last_vacuum_pid, x.last_vacuum_progress, COALESCE(x.vacuum_stalled_cycles, 0),
           x.last_action
    FROM jsonb_to_recordset(COALESCE(doc -> 'table_state', '[]'::jsonb)) AS x(
        relation_oid oid, relation_name text, recommendation_status text, recommended_reloptions jsonb,
        previous_reloptions jsonb, recommendation_reason text, recommended_at timestamptz, applied_at timestamptz,
        state text, consecutive_overdue integer, consecutive_healthy integer, last_dead_tuples bigint,
        last_live_tuples bigint, last_trigger double precision, last_backlog_ratio double precision,
        last_inserts_since_vacuum bigint, last_insert_backlog_ratio double precision,
        last_xid_age bigint, last_mxid_age bigint, last_vacuum_pid integer,
        last_vacuum_progress text, vacuum_stalled_cycles integer, last_action text)
    ON CONFLICT (database_oid, relation_oid) DO UPDATE
    SET database_name = EXCLUDED.database_name,
        relation_name = EXCLUDED.relation_name,
        recommendation_status = EXCLUDED.recommendation_status,
        recommended_reloptions = EXCLUDED.recommended_reloptions,
        previous_reloptions = EXCLUDED.previous_reloptions,
        recommendation_reason = EXCLUDED.recommendation_reason,
        recommended_at = EXCLUDED.recommended_at,
        applied_at = EXCLUDED.applied_at,
        state = EXCLUDED.state,
        consecutive_overdue = EXCLUDED.consecutive_overdue,
        consecutive_healthy = EXCLUDED.consecutive_healthy,
        last_seen_at = EXCLUDED.last_seen_at,
        last_dead_tuples = EXCLUDED.last_dead_tuples,
        last_live_tuples = EXCLUDED.last_live_tuples,
        last_trigger = EXCLUDED.last_trigger,
        last_backlog_ratio = EXCLUDED.last_backlog_ratio,
        last_inserts_since_vacuum = EXCLUDED.last_inserts_since_vacuum,
        last_insert_backlog_ratio = EXCLUDED.last_insert_backlog_ratio,
        last_xid_age = EXCLUDED.last_xid_age,
        last_mxid_age = EXCLUDED.last_mxid_age,
        last_vacuum_pid = EXCLUDED.last_vacuum_pid,
        last_vacuum_progress = EXCLUDED.last_vacuum_progress,
        vacuum_stalled_cycles = EXCLUDED.vacuum_stalled_cycles,
        last_action = EXCLUDED.last_action;

    INSERT INTO adaptive_autovacuum.decisions
        (generation, database_oid, database_name, relid, relation_name, state, action, reason,
         host_metrics, relation_metrics, proposed_reloptions, applied, error)
    SELECT generation, dboid, dbname, x.relid, x.relation_name, x.state, x.action, x.reason,
           COALESCE(x.host_metrics, '{}'::jsonb), x.relation_metrics, x.proposed_reloptions,
           COALESCE(x.applied, false), x.error
    FROM jsonb_to_recordset(COALESCE(doc -> 'decisions', '[]'::jsonb)) AS x(
        relid oid, relation_name text, state text, action text, reason text,
        host_metrics jsonb, relation_metrics jsonb, proposed_reloptions jsonb,
        applied boolean, error text);

    INSERT INTO adaptive_autovacuum.emergency_queue
        (database_oid, database_name, relid, relation_name, reason, priority, work_mem_mb,
         cost_limit, cost_delay_ms, lock_timeout_ms, is_wraparound, deadline_seconds)
    SELECT dboid, dbname, x.relid, x.relation_name, x.reason, x.priority, x.work_mem_mb,
           x.cost_limit, x.cost_delay_ms, x.lock_timeout_ms, COALESCE(x.is_wraparound, true),
           x.deadline_seconds
    FROM jsonb_to_recordset(COALESCE(doc -> 'emergency_requests', '[]'::jsonb)) AS x(
        relid oid, relation_name text, reason text, priority integer, work_mem_mb integer,
        cost_limit integer, cost_delay_ms integer, lock_timeout_ms integer,
        is_wraparound boolean, deadline_seconds double precision)
    ON CONFLICT (database_oid, relid) WHERE status IN ('pending', 'running') DO NOTHING;

    /* Debt velocity: tuples/s since this database's previous scan, halved into the previous EMA. */
    SELECT ds.debt_tuples, ds.debt_velocity, ds.last_scan_completed_at
    INTO prev_debt, prev_velocity, prev_completed_at
    FROM adaptive_autovacuum.database_state ds
    WHERE ds.database_oid = dboid;
    debt := COALESCE((s ->> 'debt_tuples')::bigint, 0);
    velocity := NULL;
    IF prev_completed_at IS NOT NULL
       AND clock_timestamp() > prev_completed_at + interval '1 second'
       AND prev_debt IS NOT NULL THEN
        interval_seconds := extract(epoch FROM clock_timestamp() - prev_completed_at);
        velocity := (debt - prev_debt)::double precision / interval_seconds;
        IF prev_velocity IS NOT NULL THEN
            velocity := 0.5 * velocity + 0.5 * prev_velocity;
        END IF;
    END IF;

    n_emergency := COALESCE((s ->> 'emergency_relations')::integer, 0);
    n_overdue := COALESCE((s ->> 'overdue')::integer, 0);

    INSERT INTO adaptive_autovacuum.database_state AS ds
        (database_oid, database_name, last_seen_at, last_scan_completed_at, scan_generation,
         scan_seconds, status, last_error, extension_installed, table_count, eligible_relations,
         overdue_relations, dead_overdue, insert_overdue, emergency_relations, fleet_max_target,
         median_scale, median_thresh, median_ins_scale, median_ins_thresh, debt_tuples,
         debt_velocity, max_xid_age, max_mxid_age, recommended_relations, analyzed_relations)
    VALUES
        (dboid, dbname, clock_timestamp(), clock_timestamp(), generation,
         (s ->> 'scan_seconds')::double precision,
         CASE WHEN n_emergency > 0 THEN 'emergency'
              WHEN n_overdue > 0 THEN 'backlog'
              ELSE 'healthy' END,
         NULL, COALESCE((doc ->> 'extension_installed')::boolean, false),
         (s ->> 'table_count')::integer, (s ->> 'eligible')::integer,
         n_overdue, (s ->> 'dead_overdue')::integer, (s ->> 'insert_overdue')::integer,
         n_emergency, (s ->> 'fleet_max_target')::bigint,
         (s ->> 'median_scale')::double precision, (s ->> 'median_thresh')::double precision,
         (s ->> 'median_ins_scale')::double precision, (s ->> 'median_ins_thresh')::double precision,
         debt, velocity, (s ->> 'max_xid_age')::bigint, (s ->> 'max_mxid_age')::bigint,
         (s ->> 'recommended')::integer, (s ->> 'analyzed')::integer)
    ON CONFLICT ON CONSTRAINT database_state_pkey DO UPDATE
    SET database_name = EXCLUDED.database_name,
        last_seen_at = EXCLUDED.last_seen_at,
        last_scan_completed_at = EXCLUDED.last_scan_completed_at,
        scan_generation = EXCLUDED.scan_generation,
        scan_seconds = EXCLUDED.scan_seconds,
        status = EXCLUDED.status,
        last_error = NULL,
        extension_installed = EXCLUDED.extension_installed,
        table_count = EXCLUDED.table_count,
        eligible_relations = EXCLUDED.eligible_relations,
        overdue_relations = EXCLUDED.overdue_relations,
        dead_overdue = EXCLUDED.dead_overdue,
        insert_overdue = EXCLUDED.insert_overdue,
        emergency_relations = EXCLUDED.emergency_relations,
        fleet_max_target = EXCLUDED.fleet_max_target,
        median_scale = EXCLUDED.median_scale,
        median_thresh = EXCLUDED.median_thresh,
        median_ins_scale = EXCLUDED.median_ins_scale,
        median_ins_thresh = EXCLUDED.median_ins_thresh,
        debt_tuples = EXCLUDED.debt_tuples,
        debt_velocity = EXCLUDED.debt_velocity,
        max_xid_age = EXCLUDED.max_xid_age,
        max_mxid_age = EXCLUDED.max_mxid_age,
        recommended_relations = EXCLUDED.recommended_relations,
        analyzed_relations = EXCLUDED.analyzed_relations;

    RETURN QUERY
    SELECT true, (s ->> 'eligible')::integer, n_overdue, n_emergency,
           COALESCE((doc ->> 'extension_installed')::boolean, false),
           EXISTS (SELECT 1 FROM adaptive_autovacuum.emergency_queue q
                   WHERE q.status = 'pending' AND q.next_retry_at <= clock_timestamp());
END
$$;

/* autovacuum = off is queued for repair before anything else in the sweep; returns true when a row waits. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._repair_disabled_autovacuum()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    p adaptive_autovacuum.policy%ROWTYPE;
    cs adaptive_autovacuum.controller_state%ROWTYPE;
BEGIN
    IF current_setting('autovacuum')::boolean THEN
        RETURN false;
    END IF;
    SELECT * INTO p FROM adaptive_autovacuum.policy WHERE singleton;
    SELECT * INTO cs FROM adaptive_autovacuum.controller_state WHERE only_row;
    IF p.singleton IS NULL OR NOT p.enabled OR NOT p.manage_global_settings OR p.dry_run
       OR NOT p.repair_disabled_autovacuum THEN
        RETURN false;
    END IF;
    /* The counter is advanced by the global step; the first check acts when the policy says 1. */
    IF cs.autovacuum_off_cycles + 1 < p.repair_disabled_autovacuum_cycles THEN
        RETURN false;
    END IF;
    /* A repair applied moments ago is still propagating through the postmaster's reload: not a second row. */
    IF EXISTS (SELECT 1 FROM adaptive_autovacuum.global_apply_queue q
               WHERE q.guc_name = 'autovacuum' AND q.status = 'applied'
                 AND q.applied_at > clock_timestamp() - interval '30 seconds') THEN
        RETURN false;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM adaptive_autovacuum.global_apply_queue q
                   WHERE q.guc_name = 'autovacuum' AND q.status = 'pending') THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue (generation, guc_name, desired_value, reason)
        VALUES (cs.cluster_generation, 'autovacuum', 'on',
                'autovacuum is off: repaired before the sweep (policy.repair_disabled_autovacuum); the extension never turns it off.');
    END IF;
    RETURN true;
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum._repair_disabled_autovacuum() IS
'Called by the controller at the start of every sweep and after every configuration reload: when autovacuum is off and the policy allows the repair, queues autovacuum = on so the controller applies it immediately, before any database is scanned.';

/* Recover requests whose worker is gone (controller restart, crash); PID-reuse guarded. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._recover_stale_emergencies()
RETURNS integer
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    WITH recovered AS (
        UPDATE adaptive_autovacuum.emergency_queue q
        SET status = 'failed',
            finished_at = clock_timestamp(),
            next_retry_at = clock_timestamp() + interval '5 minutes',
            last_error = 'Recovered stale running request: worker PID is no longer active.'
        WHERE q.status = 'running'
          AND (q.worker_pid IS NULL
               OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stat_activity a
                              WHERE a.pid = q.worker_pid
                                AND a.backend_start <= q.started_at))
        RETURNING 1)
    SELECT count(*)::integer FROM recovered
$$;

/* Claim the most urgent pending request cluster-wide: shortest deadline first, then age. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._claim_emergency_request()
RETURNS TABLE (
    id bigint, database_oid oid, database_name name, relid oid, relation_name text,
    work_mem_mb integer, cost_limit integer, cost_delay_ms integer,
    lock_timeout_ms integer, is_wraparound boolean)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    WITH candidate AS (
        SELECT q.id
        FROM adaptive_autovacuum.emergency_queue q
        WHERE q.status = 'pending'
          AND q.next_retry_at <= clock_timestamp()
          AND EXISTS (SELECT 1 FROM pg_catalog.pg_database d
                      WHERE d.oid = q.database_oid AND d.datallowconn)
        ORDER BY q.deadline_seconds ASC NULLS LAST, q.priority DESC, q.requested_at
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    UPDATE adaptive_autovacuum.emergency_queue q
    SET status = 'running',
        started_at = clock_timestamp(),
        worker_pid = NULL,
        attempts = attempts + 1
    FROM candidate
    WHERE q.id = candidate.id
    RETURNING q.id, q.database_oid, q.database_name, q.relid, q.relation_name,
              q.work_mem_mb, q.cost_limit, q.cost_delay_ms, q.lock_timeout_ms, q.is_wraparound
$$;

CREATE OR REPLACE FUNCTION adaptive_autovacuum._set_emergency_worker_pid(request_id bigint, pid integer)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    UPDATE adaptive_autovacuum.emergency_queue
    SET worker_pid = pid
    WHERE id = request_id
$$;

/* Completion or failure; the Nth recent failure of a relation waits N x 5 min (cap 2 h). */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._finish_emergency_request(
    request_id bigint, new_status text, error_text text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    UPDATE adaptive_autovacuum.emergency_queue q
    SET status = new_status,
        finished_at = clock_timestamp(),
        last_error = error_text,
        next_retry_at = CASE WHEN new_status = 'failed'
                             THEN clock_timestamp()
                                  + LEAST(24, 1 + (SELECT count(*)
                                                   FROM adaptive_autovacuum.emergency_queue f
                                                   WHERE f.database_oid = q.database_oid
                                                     AND f.relid = q.relid
                                                     AND f.id <> q.id
                                                     AND f.status = 'failed'
                                                     AND f.finished_at > clock_timestamp() - interval '24 hours'))
                                    * interval '5 minutes'
                             ELSE q.next_retry_at END
    WHERE q.id = request_id
$$;

/* The one global controller step, run once per completed sweep in the control database. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._global_controller(
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint,
    generation bigint,
    evidence_complete boolean,
    cluster_xid8 bigint DEFAULT NULL,
    extra_summary jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    p adaptive_autovacuum.policy%ROWTYPE;

    server_vnum integer := current_setting('server_version_num')::integer;
    block_size bigint := current_setting('block_size')::bigint;

    host_memory_percent double precision;
    host_load_per_cpu double precision;
    host_metrics_available boolean;
    cur_host_pressure boolean;
    cur_storage_pressure boolean;
    cur_moderate_pressure boolean;
    host_json jsonb;

    autovacuum_enabled_global boolean;
    freeze_max_age bigint;
    current_global_cost_limit integer;
    current_global_cost_delay double precision;
    current_autovacuum_work_mem_kb integer;
    current_autovacuum_workers integer;
    current_vacuum_threshold double precision;
    current_vacuum_scale_factor double precision;
    current_vacuum_max_threshold double precision;
    current_insert_threshold double precision;
    current_insert_scale_factor double precision;
    autovacuum_worker_slots_cfg integer;
    av_workers_running integer := 0;
    recommended_workers integer;
    recommended_scale double precision;
    recommended_thresh integer;
    recommended_max_thresh integer;
    recommended_ins_scale double precision;
    recommended_ins_thresh integer;
    recommended_an_scale double precision;
    recommended_an_thresh integer;
    current_analyze_scale double precision;
    current_analyze_threshold double precision;

    cluster_db_count integer := 0;
    cl_eligible integer;
    cl_overdue integer;
    cl_dead_overdue integer;
    cl_insert_overdue integer;
    cl_w_scale double precision;
    cl_w_thresh double precision;
    cl_w_ins_scale double precision;
    cl_w_ins_thresh double precision;
    cl_fleet_max bigint;
    cl_debt_tuples bigint;
    cl_debt_velocity double precision;
    cl_velocity_known boolean;
    critical_seen boolean := false;
    backlog_growth double precision;
    backlog_trend text := 'unknown';
    free_cycles integer := 0;
    av_off_cycles integer := 0;
    baseline_json jsonb;
    baseline_cost_limit integer;
    baseline_cost_delay double precision;
    last_applied_cost_limit text;
    last_applied_cost_delay text;
    workers_saturated boolean;
    worker_queue_pressure boolean;
    worker_blocked_by_host boolean;
    worker_mem_cap integer;
    current_naptime integer;
    recommended_naptime integer;
    baseline_naptime integer;
    last_applied_naptime text;
    naptime_lower boolean;

    cur_xid8 bigint;
    prev_xid8 bigint;
    prev_sample_at timestamptz;
    sample_interval double precision;
    cur_xid_rate double precision;
    cur_wal_bytes bigint;
    prev_wal_bytes bigint;
    cur_wal_rate_mbps double precision;
    page_hit_cost double precision;
    page_miss_cost double precision;
    page_dirty_cost double precision;
    io_hits double precision;
    io_reads double precision;
    io_writes double precision;
    io_extends double precision;
    cur_activity_units double precision;
    prev_activity_units double precision;
    prev_io_hits double precision;
    prev_io_reads double precision;
    prev_io_writes double precision;
    prev_io_extends double precision;
    cur_activity_rate double precision;
    activity_detail jsonb;
    raise_at timestamptz;
    raise_limit integer;
    raise_delay double precision;
    rate_before_raise double precision;
    raise_applied_at timestamptz;
    cost_raise boolean := false;
    capped_limit integer;
    drain_seconds double precision;
    backlog_under_control boolean := false;
    globals_applied_here boolean;
    sweep_started_at timestamptz;
    prev_sweep_seconds double precision;
    sweep_seconds double precision;

    long_vacuum_count integer := 0;
    delay_bound_count integer := 0;
    repeated_index_cycle_count integer := 0;

    recommended_cost_limit integer;
    recommended_cost_delay double precision;
    recommended_work_mem_kb integer;
    current_buffer_usage_limit_kb integer;
    recommended_buffer_usage_limit_kb integer;
    buffer_ring_cap_kb bigint;
    shared_buffers_kb bigint;
    recommendation_reason text;
BEGIN
    SELECT * INTO p FROM adaptive_autovacuum.policy WHERE singleton;
    IF NOT FOUND OR NOT p.enabled THEN
        RETURN;
    END IF;

    host_metrics_available := COALESCE(host_mem_total_bytes, 0) > 0
                              AND COALESCE(host_mem_available_bytes, -1) >= 0;
    host_cpu_count := GREATEST(COALESCE(host_cpu_count, 1), 1);
    host_load1 := GREATEST(COALESCE(host_load1, 0), 0);
    host_mem_available_bytes := GREATEST(COALESCE(host_mem_available_bytes, 0), 0);
    host_mem_total_bytes := GREATEST(COALESCE(host_mem_total_bytes, 0), 0);
    host_memory_percent := CASE WHEN host_mem_total_bytes > 0
                                THEN 100.0 * host_mem_available_bytes / host_mem_total_bytes
                                ELSE 100.0 END;
    host_load_per_cpu := host_load1 / host_cpu_count;

    /* Cluster-wide counters since the previous sweep; the XID counter is read without assigning one. */
    cur_xid8 := COALESCE(cluster_xid8,
                         pg_catalog.pg_snapshot_xmax(pg_catalog.pg_current_snapshot())::text::bigint);
    SELECT w.wal_bytes::bigint INTO cur_wal_bytes FROM pg_catalog.pg_stat_wal w;
    SELECT setting::double precision INTO page_hit_cost FROM pg_settings WHERE name = 'vacuum_cost_page_hit';
    SELECT setting::double precision INTO page_miss_cost FROM pg_settings WHERE name = 'vacuum_cost_page_miss';
    SELECT setting::double precision INTO page_dirty_cost FROM pg_settings WHERE name = 'vacuum_cost_page_dirty';
    /* Autovacuum-worker page operations weighted by the vacuum cost model: the activity the budget throttles. */
    SELECT COALESCE(sum(io.hits), 0), COALESCE(sum(io.reads), 0),
           COALESCE(sum(io.writes), 0), COALESCE(sum(io.extends), 0)
    INTO io_hits, io_reads, io_writes, io_extends
    FROM pg_catalog.pg_stat_io io
    WHERE io.backend_type = 'autovacuum worker' AND io.object = 'relation';
    cur_activity_units := io_hits * page_hit_cost + io_reads * page_miss_cost
                          + (io_writes + io_extends) * page_dirty_cost;

    SELECT cs.last_xid8, cs.last_sample_at, cs.last_wal_bytes,
           cs.backlog_free_cycles, cs.autovacuum_off_cycles, cs.baseline_settings,
           cs.last_vacuum_activity_units, cs.last_cost_raise_at, cs.last_raise_cost_limit,
           cs.last_raise_cost_delay, cs.activity_before_raise,
           cs.last_sweep_started_at, cs.observed_sweep_seconds,
           cs.last_io_hits, cs.last_io_reads, cs.last_io_writes, cs.last_io_extends
    INTO prev_xid8, prev_sample_at, prev_wal_bytes,
         free_cycles, av_off_cycles, baseline_json,
         prev_activity_units, raise_at, raise_limit,
         raise_delay, rate_before_raise,
         sweep_started_at, prev_sweep_seconds,
         prev_io_hits, prev_io_reads, prev_io_writes, prev_io_extends
    FROM adaptive_autovacuum.controller_state cs;

    cur_xid_rate := NULL;
    cur_wal_rate_mbps := NULL;
    cur_activity_rate := NULL;
    activity_detail := NULL;
    sample_interval := NULL;
    IF prev_sample_at IS NOT NULL
       AND clock_timestamp() > prev_sample_at + interval '1 second' THEN
        sample_interval := extract(epoch FROM clock_timestamp() - prev_sample_at);
        IF prev_xid8 IS NOT NULL AND cur_xid8 > prev_xid8 THEN
            cur_xid_rate := (cur_xid8 - prev_xid8)::double precision / sample_interval;
        END IF;
        IF prev_wal_bytes IS NOT NULL AND cur_wal_bytes >= prev_wal_bytes THEN
            cur_wal_rate_mbps := (cur_wal_bytes - prev_wal_bytes) / 1048576.0 / sample_interval;
        END IF;
        IF prev_activity_units IS NOT NULL AND cur_activity_units >= prev_activity_units THEN
            cur_activity_rate := (cur_activity_units - prev_activity_units) / sample_interval;
            /* Counter deltas over the interval; the first sweep after an upgrade has no previous counters and reports 0. */
            activity_detail := jsonb_build_object(
                'hits_per_sec', (io_hits - COALESCE(prev_io_hits, io_hits)) / sample_interval,
                'reads_per_sec', (io_reads - COALESCE(prev_io_reads, io_reads)) / sample_interval,
                'writes_per_sec', (io_writes - COALESCE(prev_io_writes, io_writes)) / sample_interval,
                'extends_per_sec', (io_extends - COALESCE(prev_io_extends, io_extends)) / sample_interval,
                'unit', 'pg_stat_io counter deltas divided by the sample interval; see cost weights',
                'weights', jsonb_build_object('hit', page_hit_cost, 'miss', page_miss_cost, 'dirty', page_dirty_cost));
        END IF;
    END IF;

    /* Sweep duration EMA drives the freshness window of database_status. */
    sweep_seconds := CASE WHEN sweep_started_at IS NOT NULL
                          THEN extract(epoch FROM clock_timestamp() - sweep_started_at) END;
    IF sweep_seconds IS NOT NULL AND prev_sweep_seconds IS NOT NULL THEN
        sweep_seconds := 0.5 * sweep_seconds + 0.5 * prev_sweep_seconds;
    END IF;

    SELECT setting::boolean INTO autovacuum_enabled_global FROM pg_settings WHERE name = 'autovacuum';
    av_off_cycles := CASE WHEN autovacuum_enabled_global THEN 0
                          ELSE LEAST(av_off_cycles + 1, p.repair_disabled_autovacuum_cycles) END;

    /* Storage guardrail: WAL rate above high_wal_mbps is treated as host pressure. */
    cur_storage_pressure := p.high_wal_mbps > 0
                        AND cur_wal_rate_mbps IS NOT NULL
                        AND cur_wal_rate_mbps >= p.high_wal_mbps;
    cur_host_pressure := host_memory_percent < p.low_memory_percent
                     OR host_load_per_cpu > p.high_load_per_cpu
                     OR cur_storage_pressure;
    cur_moderate_pressure := host_load_per_cpu > p.high_load_per_cpu / 2
                         OR host_memory_percent < 2 * p.low_memory_percent
                         OR (p.high_wal_mbps > 0 AND cur_wal_rate_mbps IS NOT NULL
                             AND cur_wal_rate_mbps >= p.high_wal_mbps / 2);

    host_json := jsonb_build_object(
        'load1', host_load1,
        'cpu_count', host_cpu_count,
        'load_per_cpu', host_load_per_cpu,
        'mem_available_bytes', host_mem_available_bytes,
        'mem_total_bytes', host_mem_total_bytes,
        'mem_available_percent', host_memory_percent,
        'memory_metrics_available', host_metrics_available,
        'cur_wal_rate_mbps', cur_wal_rate_mbps,
        'cur_storage_pressure', cur_storage_pressure,
        'pressure', cur_host_pressure);

    SELECT setting::bigint INTO freeze_max_age FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    SELECT setting::integer INTO current_global_cost_limit FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_limit';
    IF current_global_cost_limit < 0 THEN
        SELECT setting::integer INTO current_global_cost_limit FROM pg_settings WHERE name = 'vacuum_cost_limit';
    END IF;
    SELECT setting::double precision INTO current_global_cost_delay FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay';
    SELECT setting::integer INTO current_autovacuum_work_mem_kb FROM pg_settings WHERE name = 'autovacuum_work_mem';
    SELECT GREATEST(setting::integer, 1) INTO current_autovacuum_workers FROM pg_settings WHERE name = 'autovacuum_max_workers';
    SELECT setting::integer INTO current_naptime FROM pg_settings WHERE name = 'autovacuum_naptime';
    recommended_naptime := current_naptime;
    SELECT setting::double precision INTO current_vacuum_threshold FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold';
    SELECT setting::double precision INTO current_vacuum_scale_factor FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor';
    SELECT setting::double precision INTO current_vacuum_max_threshold FROM pg_settings WHERE name = 'autovacuum_vacuum_max_threshold';
    SELECT setting::double precision INTO current_insert_threshold FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_threshold';
    SELECT setting::double precision INTO current_insert_scale_factor FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_scale_factor';
    SELECT setting::integer INTO autovacuum_worker_slots_cfg FROM pg_settings WHERE name = 'autovacuum_worker_slots';
    SELECT setting::integer INTO current_buffer_usage_limit_kb FROM pg_settings WHERE name = 'vacuum_buffer_usage_limit';
    SELECT s.setting::bigint * block_size / 1024 INTO shared_buffers_kb FROM pg_settings s WHERE s.name = 'shared_buffers';
    SELECT setting::double precision INTO current_analyze_scale FROM pg_settings WHERE name = 'autovacuum_analyze_scale_factor';
    SELECT setting::double precision INTO current_analyze_threshold FROM pg_settings WHERE name = 'autovacuum_analyze_threshold';

    /* Cluster-wide vacuum progress: every autovacuum worker in every database. */
    SELECT
        count(*) FILTER (
            WHERE clock_timestamp() - a.query_start >= make_interval(secs => p.long_vacuum_seconds)),
        count(*) FILTER (
            WHERE clock_timestamp() - a.query_start >= make_interval(secs => p.long_vacuum_seconds)
              /* delay_time is PG18+; the jsonb detour keeps PG17 parsing (filter never true there). */
              AND ((to_jsonb(pv) ->> 'delay_time'))::double precision >=
                  extract(epoch FROM clock_timestamp() - a.query_start) * 1000.0 * p.high_delay_fraction),
        count(*) FILTER (WHERE pv.index_vacuum_count > 1)
    INTO long_vacuum_count, delay_bound_count, repeated_index_cycle_count
    FROM pg_stat_progress_vacuum pv
    JOIN pg_stat_activity a ON a.pid = pv.pid
    WHERE a.backend_type = 'autovacuum worker';
    long_vacuum_count := COALESCE(long_vacuum_count, 0);
    delay_bound_count := COALESCE(delay_bound_count, 0);
    repeated_index_cycle_count := COALESCE(repeated_index_cycle_count, 0);

    SELECT count(*) INTO av_workers_running
    FROM pg_stat_activity WHERE backend_type = 'autovacuum worker';

    /* Cluster evidence: the summaries of every database scanned in this generation. */
    SELECT count(*),
           COALESCE(sum(ds.eligible_relations), 0),
           COALESCE(sum(ds.overdue_relations), 0),
           COALESCE(sum(ds.dead_overdue), 0),
           COALESCE(sum(ds.insert_overdue), 0),
           COALESCE(sum(ds.median_scale * ds.dead_overdue), 0),
           COALESCE(sum(ds.median_thresh * ds.dead_overdue), 0),
           COALESCE(sum(ds.median_ins_scale * ds.insert_overdue), 0),
           COALESCE(sum(ds.median_ins_thresh * ds.insert_overdue), 0),
           COALESCE(max(ds.fleet_max_target), 0),
           COALESCE(sum(ds.debt_tuples), 0),
           COALESCE(sum(ds.debt_velocity), 0),
           bool_or(ds.debt_velocity IS NOT NULL),
           COALESCE(bool_or(ds.emergency_relations > 0), false)
    INTO cluster_db_count, cl_eligible, cl_overdue, cl_dead_overdue, cl_insert_overdue,
         cl_w_scale, cl_w_thresh, cl_w_ins_scale, cl_w_ins_thresh, cl_fleet_max,
         cl_debt_tuples, cl_debt_velocity, cl_velocity_known, critical_seen
    FROM adaptive_autovacuum.database_state ds
    WHERE ds.scan_generation = generation;

    /* Diagnostic/test hook: an extra pre-aggregated summary is folded in as more databases. */
    IF extra_summary IS NOT NULL THEN
        cluster_db_count := cluster_db_count + COALESCE((extra_summary ->> 'db_count')::integer, 0);
        cl_eligible := cl_eligible + COALESCE((extra_summary ->> 'eligible')::integer, 0);
        cl_overdue := cl_overdue + COALESCE((extra_summary ->> 'overdue')::integer, 0);
        cl_dead_overdue := cl_dead_overdue + COALESCE((extra_summary ->> 'dead_overdue')::integer, 0);
        cl_insert_overdue := cl_insert_overdue + COALESCE((extra_summary ->> 'insert_overdue')::integer, 0);
        cl_w_scale := cl_w_scale + COALESCE((extra_summary ->> 'w_scale_sum')::double precision, 0);
        cl_w_thresh := cl_w_thresh + COALESCE((extra_summary ->> 'w_thresh_sum')::double precision, 0);
        cl_w_ins_scale := cl_w_ins_scale + COALESCE((extra_summary ->> 'w_ins_scale_sum')::double precision, 0);
        cl_w_ins_thresh := cl_w_ins_thresh + COALESCE((extra_summary ->> 'w_ins_thresh_sum')::double precision, 0);
        cl_fleet_max := GREATEST(cl_fleet_max, COALESCE((extra_summary ->> 'fleet_max_target')::bigint, 0));
        cl_debt_tuples := cl_debt_tuples + COALESCE((extra_summary ->> 'debt_tuples')::bigint, 0);
        cl_debt_velocity := cl_debt_velocity + COALESCE((extra_summary ->> 'debt_velocity')::double precision, 0);
        critical_seen := critical_seen OR COALESCE((extra_summary ->> 'critical_seen')::boolean, false);
    END IF;
    cl_velocity_known := COALESCE(cl_velocity_known, false);

    IF NOT autovacuum_enabled_global THEN
        recommended_cost_limit := current_global_cost_limit;
        recommended_cost_delay := current_global_cost_delay;
        recommendation_reason := 'Autovacuum is disabled globally; enable it before applying adaptive throughput recommendations. Core wraparound protection still remains active.';
        IF NOT p.repair_disabled_autovacuum THEN
            recommendation_reason := recommendation_reason
                || ' Automatic repair is off (repair_disabled_autovacuum = false).';
        ELSIF av_off_cycles >= p.repair_disabled_autovacuum_cycles THEN
            recommendation_reason := recommendation_reason || format(
                ' autovacuum has been off for %s consecutive checks: re-enabling it'
                || ' (repair_disabled_autovacuum).', av_off_cycles);
        ELSE
            recommendation_reason := recommendation_reason || format(
                ' autovacuum has been off for %s of the %s consecutive checks required'
                || ' before automatic repair.', av_off_cycles,
                p.repair_disabled_autovacuum_cycles);
        END IF;
    ELSIF cur_host_pressure THEN
        recommended_cost_limit := GREATEST(200, floor(current_global_cost_limit * 0.75)::integer);
        recommended_cost_delay := LEAST(p.recommendation_delay_max_ms,
                                        GREATEST(current_global_cost_delay, 2.0) * 1.5);
        recommendation_reason := CASE
            WHEN cur_storage_pressure THEN format(
                'WAL generation rate (%s MB/s) exceeds high_wal_mbps (%s); reduce vacuum I/O aggression.',
                trim(trailing '.' from to_char(cur_wal_rate_mbps, 'FM999999990.9999')),
                trim(trailing '.' from to_char(p.high_wal_mbps, 'FM999999990.9999')))
            ELSE 'Host pressure is high; reduce vacuum I/O aggression.'
        END;
    ELSIF delay_bound_count > 0 THEN
        recommended_cost_limit := LEAST(p.recommendation_cost_limit_max,
                                        GREATEST(200, current_global_cost_limit * 2));
        /* Halve toward the policy floor; an operator delay already below it is respected. */
        recommended_cost_delay := GREATEST(
            LEAST(p.recommendation_delay_min_ms, GREATEST(current_global_cost_delay, 0)),
            GREATEST(current_global_cost_delay, 0) / 2.0);
        cost_raise := true;
        recommendation_reason := 'Long-running vacuums are spending a material fraction of time in cost delay.';
    ELSE
        recommended_cost_limit := current_global_cost_limit;
        recommended_cost_delay := current_global_cost_delay;
        recommendation_reason := 'No cluster-level cost change is currently justified.';
    END IF;

    IF current_autovacuum_work_mem_kb < 0 THEN
        SELECT setting::integer INTO current_autovacuum_work_mem_kb
        FROM pg_settings WHERE name = 'maintenance_work_mem';
    END IF;

    IF NOT host_metrics_available THEN
        recommended_work_mem_kb := current_autovacuum_work_mem_kb;
    ELSE
        recommended_work_mem_kb := LEAST(
            p.recommendation_work_mem_max_mb * 1024,
            GREATEST(
                65536,
                floor((host_mem_available_bytes / 1024.0)
                      * p.work_mem_available_fraction
                      / current_autovacuum_workers)::integer));

        IF cur_host_pressure THEN
            recommended_work_mem_kb := LEAST(current_autovacuum_work_mem_kb, recommended_work_mem_kb);
        ELSIF repeated_index_cycle_count = 0 THEN
            /* No memory-pressure evidence: raise opportunistically only while workers run; never lower. */
            IF av_workers_running > 0 THEN
                recommended_work_mem_kb := GREATEST(current_autovacuum_work_mem_kb, recommended_work_mem_kb);
            ELSE
                recommended_work_mem_kb := current_autovacuum_work_mem_kb;
            END IF;
        END IF;
    END IF;

    /* Debt trend: growth per sample interval relative to the cluster debt, with a deadband. */
    backlog_growth := NULL;
    backlog_trend := 'unknown';
    IF sample_interval IS NOT NULL AND cl_velocity_known THEN
        backlog_growth := cl_debt_velocity * sample_interval / GREATEST(cl_debt_tuples, 1)::double precision;
        backlog_trend := CASE WHEN backlog_growth > p.backlog_trend_deadband THEN 'growing'
                              WHEN backlog_growth < -p.backlog_trend_deadband THEN 'shrinking'
                              ELSE 'flat' END;
    END IF;
    /* Shrinking is only "under control" if the debt is projected to clear within the target. */
    drain_seconds := CASE WHEN cl_debt_velocity < 0 THEN cl_debt_tuples / -cl_debt_velocity END;
    backlog_under_control := backlog_trend = 'shrinking'
                             AND drain_seconds <= p.max_backlog_drain_seconds;

    /* Baseline = operator value: refreshed when the live value is not the one last applied here. */
    SELECT q.desired_value INTO last_applied_cost_limit
    FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.guc_name = 'autovacuum_vacuum_cost_limit' AND q.status = 'applied'
    ORDER BY q.applied_at DESC LIMIT 1;
    SELECT q.desired_value INTO last_applied_cost_delay
    FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.guc_name = 'autovacuum_vacuum_cost_delay' AND q.status = 'applied'
    ORDER BY q.applied_at DESC LIMIT 1;
    baseline_json := COALESCE(baseline_json, '{}'::jsonb);
    IF last_applied_cost_limit IS NULL
       OR last_applied_cost_limit::numeric IS DISTINCT FROM current_global_cost_limit::numeric
       OR NOT baseline_json ? 'autovacuum_vacuum_cost_limit' THEN
        baseline_json := baseline_json
                         || jsonb_build_object('autovacuum_vacuum_cost_limit', current_global_cost_limit);
    END IF;
    IF last_applied_cost_delay IS NULL
       OR last_applied_cost_delay::numeric IS DISTINCT FROM current_global_cost_delay::numeric
       OR NOT baseline_json ? 'autovacuum_vacuum_cost_delay' THEN
        baseline_json := baseline_json
                         || jsonb_build_object('autovacuum_vacuum_cost_delay', current_global_cost_delay);
    END IF;
    SELECT q.desired_value INTO last_applied_naptime
    FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.guc_name = 'autovacuum_naptime' AND q.status = 'applied'
    ORDER BY q.applied_at DESC LIMIT 1;
    IF last_applied_naptime IS NULL
       OR last_applied_naptime::numeric IS DISTINCT FROM current_naptime::numeric
       OR NOT baseline_json ? 'autovacuum_naptime' THEN
        baseline_json := baseline_json || jsonb_build_object('autovacuum_naptime', current_naptime);
    END IF;
    baseline_cost_limit := (baseline_json ->> 'autovacuum_vacuum_cost_limit')::integer;
    baseline_cost_delay := (baseline_json ->> 'autovacuum_vacuum_cost_delay')::double precision;
    baseline_naptime := (baseline_json ->> 'autovacuum_naptime')::integer;

    /* Closed loop: growing/flat/unknown raises, shrinking holds, no backlog decays to baseline. */
    free_cycles := CASE WHEN cl_overdue = 0
                        THEN LEAST(free_cycles + 1, p.recovery_cycles_before_decay)
                        ELSE 0 END;
    IF NOT cur_host_pressure AND cl_overdue > 0
       AND recommendation_reason = 'No cluster-level cost change is currently justified.'
    THEN
        IF backlog_under_control THEN
            recommendation_reason := format(
                '%s overdue relations, but cluster maintenance debt is shrinking'
                || ' (%s%% per check, clear in about %s s): holding the current cost settings.',
                cl_overdue, to_char(-100.0 * backlog_growth, 'FM9990.0'), round(drain_seconds));
        ELSE
            cost_raise := true;
            recommended_cost_limit := LEAST(p.recommendation_cost_limit_max,
                                            GREATEST(200, current_global_cost_limit * 2));
            /* Same floored walk-down as the delay-bound branch above. */
            recommended_cost_delay := GREATEST(
                LEAST(p.recommendation_delay_min_ms, GREATEST(current_global_cost_delay, 0)),
                GREATEST(current_global_cost_delay, 0) / 2.0);
            recommendation_reason := format(
                '%s overdue relations were found without host pressure; cluster maintenance'
                || ' debt is %s%s%s.',
                cl_overdue, backlog_trend,
                CASE WHEN backlog_growth IS NOT NULL
                     THEN format(' (%s%% per check)', to_char(100.0 * backlog_growth, 'FMS9990.0'))
                     ELSE '' END,
                CASE WHEN backlog_trend = 'shrinking'
                     THEN format(' but would take about %s s to clear (max_backlog_drain_seconds = %s)',
                                 round(drain_seconds), p.max_backlog_drain_seconds)
                     ELSE '' END);
        END IF;
    ELSIF cl_overdue = 0 AND NOT cur_host_pressure AND autovacuum_enabled_global
          AND free_cycles >= p.recovery_cycles_before_decay
          AND recommendation_reason = 'No cluster-level cost change is currently justified.'
          AND (current_global_cost_limit <> baseline_cost_limit
               OR current_global_cost_delay <> baseline_cost_delay
               OR current_naptime <> baseline_naptime) THEN
        IF current_global_cost_limit > baseline_cost_limit THEN
            recommended_cost_limit := GREATEST(baseline_cost_limit, current_global_cost_limit / 2);
        ELSIF current_global_cost_limit < baseline_cost_limit THEN
            recommended_cost_limit := LEAST(baseline_cost_limit, current_global_cost_limit * 2);
        END IF;
        IF current_global_cost_delay < baseline_cost_delay THEN
            recommended_cost_delay := LEAST(baseline_cost_delay,
                                            GREATEST(current_global_cost_delay * 2, 0.5));
        ELSIF current_global_cost_delay > baseline_cost_delay THEN
            recommended_cost_delay := GREATEST(baseline_cost_delay, current_global_cost_delay / 2);
        END IF;
        /* The launcher interval walks back up the same way it came down. */
        IF p.manage_naptime AND current_naptime < baseline_naptime THEN
            recommended_naptime := LEAST(baseline_naptime, current_naptime * 2);
        END IF;
        free_cycles := 0;
        recommendation_reason := format(
            'No overdue relations for %s consecutive checks: stepping the cost settings back'
            || ' toward the pre-incident baseline (cost_limit %s, cost_delay %s ms, autovacuum_naptime %s s).',
            p.recovery_cycles_before_decay, baseline_cost_limit,
            trim(trailing '.' from to_char(baseline_cost_delay, 'FM999990.99')), baseline_naptime);
    END IF;

    /* A raise must first prove itself: the previous applied raise has to show more activity. */
    IF cost_raise AND raise_at IS NOT NULL
       AND raise_limit = current_global_cost_limit
       AND abs(raise_delay - current_global_cost_delay) < 0.001 THEN
        /* The interval counts as post-raise when the raise was applied within its first tenth. */
        SELECT max(q.applied_at) INTO raise_applied_at
        FROM adaptive_autovacuum.global_apply_queue q
        WHERE ((q.guc_name = 'autovacuum_vacuum_cost_limit'
                AND q.desired_value = raise_limit::text)
               OR (q.guc_name = 'autovacuum_vacuum_cost_delay'
                   AND q.desired_value::double precision = raise_delay))
          AND q.status = 'applied'
          AND q.requested_at >= raise_at - interval '1 second';
        IF prev_sample_at IS NULL OR cur_activity_rate IS NULL OR raise_applied_at IS NULL
           OR raise_applied_at > prev_sample_at + sample_interval * interval '0.1 second' THEN
            recommended_cost_limit := current_global_cost_limit;
            recommended_cost_delay := current_global_cost_delay;
            recommendation_reason := recommendation_reason || format(
                ' The last cost raise (to %s / %s ms) has not yet been observed over a full'
                || ' check interval: holding.',
                raise_limit, trim(trailing '.' from to_char(raise_delay, 'FM999990.99')));
        ELSIF cur_activity_rate <= rate_before_raise
                                 * (1 + p.cost_raise_min_activity_gain_percent / 100.0) THEN
            recommended_cost_limit := current_global_cost_limit;
            recommended_cost_delay := current_global_cost_delay;
            recommendation_reason := recommendation_reason || format(
                ' The last cost raise (to %s / %s ms) did not produce a meaningful increase in'
                || ' autovacuum activity (%s -> %s cost units/s, less than %s%% more): the extra'
                || ' budget is not being used yet, so another raise would not help; holding.'
                || ' Possible causes include storage limits, lock waits, vacuum phase changes,'
                || ' worker turnover or sampling timing.',
                raise_limit, trim(trailing '.' from to_char(raise_delay, 'FM999990.99')),
                round(rate_before_raise::numeric), round(cur_activity_rate::numeric),
                p.cost_raise_min_activity_gain_percent);
        END IF;
    END IF;
    /* Page-rate cap: keep the delay (it smooths I/O), take only the limit raise that fits. */
    IF cost_raise AND p.recommendation_max_vacuum_mbps > 0
       AND (recommended_cost_limit > current_global_cost_limit
            OR recommended_cost_delay < current_global_cost_delay)
       AND adaptive_autovacuum.vacuum_cost_ceiling_mbps(recommended_cost_limit,
                                                        recommended_cost_delay,
                                                        page_hit_cost, block_size)
           > p.recommendation_max_vacuum_mbps THEN
        capped_limit := CASE
            WHEN current_global_cost_delay > 0
            THEN floor(p.recommendation_max_vacuum_mbps * 1048576.0 * page_hit_cost
                       * current_global_cost_delay / 1000.0 / block_size)::integer
            ELSE current_global_cost_limit END;
        recommended_cost_delay := current_global_cost_delay;
        recommended_cost_limit := LEAST(recommended_cost_limit,
                                        GREATEST(capped_limit, current_global_cost_limit));
        recommendation_reason := recommendation_reason || format(
            ' Throughput cap %s MB/s (recommendation_max_vacuum_mbps, theoretical page-hit rate): %s.',
            p.recommendation_max_vacuum_mbps,
            CASE WHEN recommended_cost_limit > current_global_cost_limit
                 THEN format('the delay stays at %s ms and cost_limit goes to %s (%s MB/s)',
                             trim(trailing '.' from to_char(current_global_cost_delay, 'FM999990.99')),
                             recommended_cost_limit,
                             round(adaptive_autovacuum.vacuum_cost_ceiling_mbps(
                                       recommended_cost_limit, recommended_cost_delay,
                                       page_hit_cost, block_size)::numeric))
                 ELSE format('the current %s / %s ms (%s MB/s) is held',
                             current_global_cost_limit,
                             trim(trailing '.' from to_char(current_global_cost_delay, 'FM999990.99')),
                             round(adaptive_autovacuum.vacuum_cost_ceiling_mbps(
                                       current_global_cost_limit, current_global_cost_delay,
                                       page_hit_cost, block_size)::numeric))
            END);
    END IF;

    /* Workers: busy pool or an overdue queue longer than the pool, with non-shrinking debt. */
    workers_saturated := av_workers_running >= current_autovacuum_workers;
    /* One pg_stat_activity sample misses saturation; an overdue queue beyond the pool is the same evidence. */
    worker_queue_pressure := cl_overdue >= current_autovacuum_workers + 2;
    /* Workers share one cost budget, so CPU load alone does not block them; memory and storage pressure do. */
    worker_blocked_by_host := (host_memory_percent < p.low_memory_percent OR cur_storage_pressure)
                              AND NOT critical_seen;
    IF NOT autovacuum_enabled_global
       OR cl_overdue = 0
       OR (NOT workers_saturated AND NOT worker_queue_pressure)
       OR backlog_under_control
       OR worker_blocked_by_host THEN
        recommended_workers := current_autovacuum_workers;
    ELSE
        /* Bounded doubling per step, toward the overdue count; independent of the cost budget. */
        recommended_workers := LEAST(GREATEST(cl_overdue, current_autovacuum_workers + 1),
                                     current_autovacuum_workers * 2);
        /* Extra workers must fit in half the free memory at autovacuum_work_mem each. */
        worker_mem_cap := CASE
            WHEN host_metrics_available AND current_autovacuum_work_mem_kb > 0
            THEN current_autovacuum_workers
                 + floor(host_mem_available_bytes / 2.0
                         / (current_autovacuum_work_mem_kb::double precision * 1024))::integer
            ELSE recommended_workers END;
        /* CPU count only gates via load per CPU; no 1-worker-per-CPU ceiling. */
        /* PG18 caps at autovacuum_worker_slots; PG17 stays record-only (restart GUC). */
        recommended_workers := LEAST(recommended_workers,
                                     worker_mem_cap,
                                     p.recommendation_workers_max,
                                     CASE WHEN server_vnum >= 180000
                                          THEN COALESCE(autovacuum_worker_slots_cfg,
                                                        current_autovacuum_workers)
                                          ELSE p.recommendation_workers_max END);
        recommended_workers := GREATEST(recommended_workers, current_autovacuum_workers);

        IF recommended_workers > current_autovacuum_workers THEN
            IF server_vnum >= 180000 THEN
                recommendation_reason := recommendation_reason || format(
                    ' %s of %s autovacuum workers are busy while %s relations are'
                    || ' overdue and maintenance debt is %s; raise autovacuum_max_workers'
                    || ' to %s (reloadable; the shared vacuum_cost_limit is split across'
                    || ' workers, so this does not raise total un-boosted vacuum I/O;'
                    || ' capped by autovacuum_worker_slots=%s which needs a restart to raise).',
                    av_workers_running, current_autovacuum_workers, cl_overdue, backlog_trend,
                    recommended_workers, autovacuum_worker_slots_cfg);
            ELSE
                recommendation_reason := recommendation_reason || format(
                    ' %s of %s autovacuum workers are busy while %s relations are'
                    || ' overdue and maintenance debt is %s; raise autovacuum_max_workers'
                    || ' to %s (on PostgreSQL 17 this requires a server restart, so it is'
                    || ' recorded here and never applied automatically).',
                    av_workers_running, current_autovacuum_workers, cl_overdue, backlog_trend,
                    recommended_workers);
            END IF;
        END IF;
    END IF;

    /* Launcher cadence: core starts one worker per database per autovacuum_naptime, so a raised pool stays
       empty until the interval follows; halve it while overdue relations wait and the pool is under-filled. */
    naptime_lower := p.manage_naptime
                     AND autovacuum_enabled_global
                     AND cl_overdue > 0
                     AND NOT backlog_under_control
                     AND NOT worker_blocked_by_host
                     AND av_workers_running < current_autovacuum_workers
                     AND current_naptime > p.naptime_min_seconds;
    IF naptime_lower THEN
        recommended_naptime := GREATEST(p.naptime_min_seconds, current_naptime / 2);
        recommendation_reason := recommendation_reason || format(
            ' %s of %s autovacuum workers are running while %s relations are overdue: the launcher starts'
            || ' one worker per database per autovacuum_naptime, so it goes %s -> %s s (floor %s s) to fill the pool.',
            av_workers_running, current_autovacuum_workers, cl_overdue,
            current_naptime, recommended_naptime, p.naptime_min_seconds);
    END IF;

    /* Mistuned baseline: many overdue relations = wrong global triggers; recommend the median. */
    recommended_scale := NULL;
    recommended_thresh := NULL;
    recommended_max_thresh := NULL;
    recommended_an_scale := NULL;
    recommended_an_thresh := NULL;
    IF cl_dead_overdue >= 3
       AND cl_dead_overdue * 4 >= cl_eligible
       AND cl_w_scale > 0
       AND cl_w_thresh > 0 THEN
        recommended_scale := cl_w_scale / cl_dead_overdue;
        recommended_thresh := round(cl_w_thresh / cl_dead_overdue)::integer;

        /* Analyze at half the vacuum scale factor (PostgreSQL's default ratio). */
        recommended_an_scale := GREATEST(0.005, recommended_scale * 0.5);
        recommended_an_thresh := GREATEST(50, recommended_thresh / 2);

        recommendation_reason := recommendation_reason || format(
            ' The global baseline appears mistuned: %s of %s eligible relations'
            || ' are overdue on dead-tuple backlog; setting cluster-wide'
            || ' autovacuum_vacuum_scale_factor ~ %s, autovacuum_vacuum_threshold ~ %s'
            || ' (analyze baseline in proportion: %s / %s)'
            || ' so that per-table overrides remain the exception.',
            cl_dead_overdue, cl_eligible,
            trim(trailing '.' from to_char(recommended_scale, 'FM0.9999')),
            recommended_thresh,
            trim(trailing '.' from to_char(recommended_an_scale, 'FM0.9999')),
            recommended_an_thresh);
    END IF;

    /* PG18 trigger ceiling derived from the largest relation's dead-tuple target, with hysteresis. */
    IF server_vnum >= 180000
       AND cl_fleet_max > 0
       AND (current_vacuum_max_threshold < 0
            OR current_vacuum_max_threshold > cl_fleet_max * 1.10
            OR current_vacuum_max_threshold < cl_fleet_max * 0.50) THEN
        recommended_max_thresh := cl_fleet_max::integer;
        recommendation_reason := recommendation_reason || format(
            ' Dead-tuple trigger ceiling autovacuum_vacuum_max_threshold -> %s,'
            || ' derived from the largest eligible relation'
            || ' (target ratio %s of its rows, policy bounds %s..%s):'
            || ' large tables never wait longer than their policy target while'
            || ' the percentage scale factor keeps governing smaller tables.',
            recommended_max_thresh,
            trim(trailing '.' from to_char(p.target_dead_tuple_ratio, 'FM0.9999')),
            p.target_dead_tuple_min, p.target_dead_tuple_max);
    END IF;

    recommended_ins_scale := NULL;
    recommended_ins_thresh := NULL;
    IF cl_insert_overdue >= 3
       AND cl_insert_overdue * 4 >= cl_eligible
       AND cl_w_ins_scale > 0
       AND cl_w_ins_thresh > 0 THEN
        recommended_ins_scale := cl_w_ins_scale / cl_insert_overdue;
        recommended_ins_thresh := round(cl_w_ins_thresh / cl_insert_overdue)::integer;

        recommendation_reason := recommendation_reason || format(
            ' The insert-vacuum baseline appears mistuned: %s of %s eligible'
            || ' relations are overdue on insert backlog; setting cluster-wide'
            || ' autovacuum_vacuum_insert_scale_factor ~ %s and'
            || ' autovacuum_vacuum_insert_threshold ~ %s.',
            cl_insert_overdue, cl_eligible,
            trim(trailing '.' from to_char(recommended_ins_scale, 'FM0.9999')),
            recommended_ins_thresh);
    END IF;

    /* autovacuum_freeze_max_age sanity check; record-only (postmaster GUC). */
    IF freeze_max_age < 50000000 THEN
        recommendation_reason := recommendation_reason || format(
            ' WARNING: autovacuum_freeze_max_age is abnormally low (%s);'
            || ' forced anti-wraparound vacuums will fire near-constantly.'
            || ' Raise it toward the 200M default (requires a restart; not'
            || ' applied automatically).', freeze_max_age);
    ELSIF freeze_max_age > 1200000000 THEN
        recommendation_reason := recommendation_reason || format(
            ' WARNING: autovacuum_freeze_max_age is dangerously high (%s);'
            || ' little headroom remains before the vacuum failsafe'
            || ' (vacuum_failsafe_age, default 1.6B) and the ~2.1B read-only'
            || ' cutoff. Lower it (requires a restart; not applied'
            || ' automatically).', freeze_max_age);
    END IF;

    /* vacuum_buffer_usage_limit: cautious raise while workers run; policy and shared_buffers/8 caps. */
    recommended_buffer_usage_limit_kb := current_buffer_usage_limit_kb;
    IF current_buffer_usage_limit_kb > 0 THEN
        buffer_ring_cap_kb := LEAST(
            p.recommendation_buffer_usage_limit_max_mb::bigint * 1024,
            shared_buffers_kb / 8 / GREATEST(current_autovacuum_workers, 1));
        IF cur_host_pressure THEN
            SELECT GREATEST(s.boot_val::integer, current_buffer_usage_limit_kb / 2)
            INTO recommended_buffer_usage_limit_kb
            FROM pg_settings s WHERE s.name = 'vacuum_buffer_usage_limit';
        ELSIF av_workers_running > 0
              AND host_metrics_available
              AND current_buffer_usage_limit_kb < buffer_ring_cap_kb THEN
            recommended_buffer_usage_limit_kb := LEAST(
                buffer_ring_cap_kb,
                current_buffer_usage_limit_kb::bigint * 2)::integer;
        END IF;
    END IF;

    IF recommended_buffer_usage_limit_kb <> current_buffer_usage_limit_kb THEN
        IF recommended_buffer_usage_limit_kb > current_buffer_usage_limit_kb THEN
            recommendation_reason := recommendation_reason || format(
                ' %s autovacuum worker(s) are running with free host memory:'
                || ' raising vacuum_buffer_usage_limit %s -> %s kB so'
                || ' maintenance keeps its pages cached across passes'
                || ' (cap %s kB = LEAST(policy %s MB, shared_buffers/8 per'
                || ' worker)).',
                av_workers_running,
                current_buffer_usage_limit_kb, recommended_buffer_usage_limit_kb,
                buffer_ring_cap_kb, p.recommendation_buffer_usage_limit_max_mb);
        ELSE
            recommendation_reason := recommendation_reason || format(
                ' Host pressure: walking vacuum_buffer_usage_limit back'
                || ' %s -> %s kB.',
                current_buffer_usage_limit_kb, recommended_buffer_usage_limit_kb);
        END IF;
    END IF;

    recommendation_reason := recommendation_reason || format(
        ' Cluster-wide evidence (sweep %s): %s databases, %s eligible relations, %s overdue.',
        generation, cluster_db_count, cl_eligible, cl_overdue);

    /* Incomplete cluster evidence (a database failed or timed out this sweep): record the advice only. */
    IF NOT evidence_complete THEN
        recommendation_reason := recommendation_reason
            || ' Cluster evidence is incomplete (not every database was scanned in this sweep): recorded only, not applied.';
    END IF;

    INSERT INTO adaptive_autovacuum.global_recommendations
        (generation, databases, evidence_complete, host_metrics, overdue_relations, long_vacuums,
         delay_bound_long_vacuums, repeated_index_vacuum_cycles,
         recommended_cost_limit, recommended_cost_delay_ms,
         recommended_autovacuum_work_mem_kb, recommended_buffer_usage_limit_kb,
         recommended_autovacuum_workers, recommended_autovacuum_naptime_seconds,
         recommended_vacuum_scale_factor, recommended_vacuum_threshold,
         recommended_vacuum_max_threshold,
         recommended_insert_scale_factor, recommended_insert_threshold,
         recommended_analyze_scale_factor, recommended_analyze_threshold,
         maintenance_debt_tuples, maintenance_debt_velocity, backlog_trend,
         vacuum_activity_rate, vacuum_activity_detail, cost_budget_rate, cost_ceiling_mbps,
         reason)
    VALUES
        (generation, cluster_db_count, evidence_complete, host_json, cl_overdue, long_vacuum_count,
         delay_bound_count, repeated_index_cycle_count,
         recommended_cost_limit, recommended_cost_delay,
         recommended_work_mem_kb, recommended_buffer_usage_limit_kb,
         recommended_workers, recommended_naptime,
         recommended_scale, recommended_thresh,
         recommended_max_thresh,
         recommended_ins_scale, recommended_ins_thresh,
         recommended_an_scale, recommended_an_thresh,
         cl_debt_tuples, cl_debt_velocity, backlog_trend,
         cur_activity_rate, activity_detail,
         adaptive_autovacuum.cost_budget_rate(current_global_cost_limit, current_global_cost_delay),
         adaptive_autovacuum.vacuum_cost_ceiling_mbps(recommended_cost_limit, recommended_cost_delay,
                                                      page_hit_cost, block_size),
         recommendation_reason);

    /* autovacuum=off repair: the one non-numeric change; queued separately, only ever 'on'. */
    /* Normally already done before the sweep (_repair_disabled_autovacuum); a repair applied moments ago is still propagating. */
    IF p.manage_global_settings AND NOT p.dry_run
       AND NOT autovacuum_enabled_global
       AND p.repair_disabled_autovacuum
       AND av_off_cycles >= p.repair_disabled_autovacuum_cycles
       AND NOT EXISTS (SELECT 1
                       FROM adaptive_autovacuum.global_apply_queue q
                       WHERE q.guc_name = 'autovacuum'
                         AND (q.status = 'pending'
                              OR (q.status = 'applied'
                                  AND q.applied_at > clock_timestamp() - interval '30 seconds'))) THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue(generation, guc_name, desired_value, reason)
        VALUES (generation, 'autovacuum', 'on', recommendation_reason);
    END IF;

    /* Cluster-first: queue ALTER SYSTEM changes for the controller process (deduplicated, audited). */
    globals_applied_here := p.manage_global_settings AND NOT p.dry_run AND autovacuum_enabled_global
                            AND evidence_complete;
    IF globals_applied_here THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue(generation, guc_name, desired_value, reason)
        SELECT generation, cand.guc_name, cand.desired_value, recommendation_reason
        FROM (VALUES
            ('autovacuum_vacuum_cost_limit',
             recommended_cost_limit::text,
             current_global_cost_limit::text),
            ('autovacuum_vacuum_cost_delay',
             trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99')),
             trim(trailing '.' from to_char(current_global_cost_delay, 'FM999990.99'))),
            ('autovacuum_max_workers',
             /* Reloadable only on PG18+; on PG17 it stays a recorded recommendation. */
             CASE WHEN server_vnum >= 180000
                       AND recommended_workers > current_autovacuum_workers
                  THEN recommended_workers::text END,
             current_autovacuum_workers::text),
            ('autovacuum_naptime',
             CASE WHEN p.manage_naptime THEN recommended_naptime::text END,
             current_naptime::text),
            ('autovacuum_work_mem',
             recommended_work_mem_kb::text,
             current_autovacuum_work_mem_kb::text),
            ('vacuum_buffer_usage_limit',
             recommended_buffer_usage_limit_kb::text,
             current_buffer_usage_limit_kb::text),
            ('autovacuum_vacuum_scale_factor',
             CASE WHEN recommended_scale IS NOT NULL
                  THEN trim(trailing '.' from to_char(recommended_scale, 'FM0.9999')) END,
             trim(trailing '.' from to_char(current_vacuum_scale_factor, 'FM999990.9999'))),
            ('autovacuum_vacuum_threshold',
             CASE WHEN recommended_thresh IS NOT NULL
                  THEN recommended_thresh::text END,
             current_vacuum_threshold::text),
            ('autovacuum_vacuum_max_threshold',
             CASE WHEN recommended_max_thresh IS NOT NULL
                  THEN recommended_max_thresh::text END,
             current_vacuum_max_threshold::text),
            ('autovacuum_vacuum_insert_scale_factor',
             CASE WHEN recommended_ins_scale IS NOT NULL
                  THEN trim(trailing '.' from to_char(recommended_ins_scale, 'FM0.9999')) END,
             trim(trailing '.' from to_char(current_insert_scale_factor, 'FM999990.9999'))),
            ('autovacuum_vacuum_insert_threshold',
             CASE WHEN recommended_ins_thresh IS NOT NULL
                  THEN recommended_ins_thresh::text END,
             current_insert_threshold::text),
            ('autovacuum_analyze_scale_factor',
             CASE WHEN recommended_an_scale IS NOT NULL
                  THEN trim(trailing '.' from to_char(recommended_an_scale, 'FM0.9999')) END,
             trim(trailing '.' from to_char(current_analyze_scale, 'FM999990.9999'))),
            ('autovacuum_analyze_threshold',
             CASE WHEN recommended_an_thresh IS NOT NULL
                  THEN recommended_an_thresh::text END,
             current_analyze_threshold::text)
        ) AS cand(guc_name, desired_value, current_value)
        WHERE cand.desired_value IS NOT NULL
          AND cand.desired_value::numeric IS DISTINCT FROM cand.current_value::numeric
          /* Never enqueue outside pg_settings min/max (also drops GUCs this version lacks). */
          AND EXISTS (SELECT 1
                      FROM pg_settings s
                      WHERE s.name = cand.guc_name
                        AND (s.min_val IS NULL
                             OR cand.desired_value::numeric >= s.min_val::numeric)
                        AND (s.max_val IS NULL
                             OR cand.desired_value::numeric <= s.max_val::numeric))
          AND NOT EXISTS (SELECT 1
                          FROM adaptive_autovacuum.global_apply_queue q
                          WHERE q.guc_name = cand.guc_name
                            AND q.status = 'pending');
    END IF;

    /* Remember a queued raise with the activity seen before it; the next sweep judges it. */
    /* A pair still waiting in the queue is re-recommended each sweep: keep its first record. */
    IF globals_applied_here AND cost_raise
       AND (recommended_cost_limit > current_global_cost_limit
            OR recommended_cost_delay < current_global_cost_delay)
       AND (raise_limit IS DISTINCT FROM recommended_cost_limit
            OR raise_delay IS DISTINCT FROM
               trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99'))::double precision) THEN
        raise_at := clock_timestamp();
        raise_limit := recommended_cost_limit;
        raise_delay := trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99'))::double precision;
        rate_before_raise := COALESCE(cur_activity_rate, 0);
    END IF;
    /* A backlog-free sweep closes the episode: the next incident's first raise is judged fresh. */
    IF cl_overdue = 0 AND raise_at IS NOT NULL THEN
        raise_at := NULL;
        raise_limit := NULL;
        raise_delay := NULL;
        rate_before_raise := NULL;
    END IF;

    UPDATE adaptive_autovacuum.controller_state
    SET last_sweep_completed_at = clock_timestamp(),
        last_complete_generation = CASE WHEN evidence_complete THEN generation ELSE last_complete_generation END,
        observed_sweep_seconds = COALESCE(sweep_seconds, observed_sweep_seconds),
        last_xid8 = cur_xid8,
        xid_rate = cur_xid_rate,
        last_sample_at = clock_timestamp(),
        last_wal_bytes = cur_wal_bytes,
        wal_rate_mbps = cur_wal_rate_mbps,
        host_pressure = cur_host_pressure,
        storage_pressure = cur_storage_pressure,
        moderate_pressure = cur_moderate_pressure,
        last_debt_tuples = cl_debt_tuples,
        debt_velocity = CASE WHEN cl_velocity_known THEN cl_debt_velocity END,
        backlog_free_cycles = free_cycles,
        autovacuum_off_cycles = av_off_cycles,
        baseline_settings = baseline_json,
        last_vacuum_activity_units = cur_activity_units,
        vacuum_activity_rate = cur_activity_rate,
        last_io_hits = io_hits,
        last_io_reads = io_reads,
        last_io_writes = io_writes,
        last_io_extends = io_extends,
        last_cost_raise_at = raise_at,
        last_raise_cost_limit = raise_limit,
        last_raise_cost_delay = raise_delay,
        activity_before_raise = rate_before_raise
    WHERE only_row;

    UPDATE adaptive_autovacuum.global_apply_queue
    SET status = 'failed',
        error = 'Expired before the controller applied it.'
    WHERE status = 'pending'
      AND requested_at < clock_timestamp() - interval '1 hour';

    /* Retention. */
    DELETE FROM adaptive_autovacuum.table_state ts
    WHERE ts.last_seen_at < clock_timestamp() - interval '7 days';

    DELETE FROM adaptive_autovacuum.decisions
    WHERE decided_at < clock_timestamp() - make_interval(days => p.history_retention_days);

    DELETE FROM adaptive_autovacuum.global_recommendations
    WHERE created_at < clock_timestamp() - make_interval(days => p.history_retention_days);

    DELETE FROM adaptive_autovacuum.emergency_queue
    WHERE finished_at < clock_timestamp() - make_interval(days => p.history_retention_days)
      AND status IN ('completed', 'cancelled', 'failed');

    /* The newest applied row per setting survives retention: it anchors the baseline tracking. */
    DELETE FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.status IN ('applied', 'failed')
      AND coalesce(q.applied_at, q.requested_at)
          < clock_timestamp() - make_interval(days => p.history_retention_days)
      AND q.id NOT IN (SELECT max(k.id)
                       FROM adaptive_autovacuum.global_apply_queue k
                       WHERE k.status = 'applied'
                       GROUP BY k.guc_name);
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum._global_controller(double precision, integer, bigint, bigint, bigint, boolean, bigint, jsonb) IS
'The single cluster-level decision step, run by the controller process once per completed sweep: aggregates database_state for the generation, samples cluster counters (next XID read without assigning one, WAL, cost-weighted autovacuum activity), records one recommendation and queues the allow-listed ALTER SYSTEM changes (cost pair, workers, autovacuum_naptime, memory, triggers). extra_summary is a diagnostic hook that folds a pre-aggregated summary in as additional databases.';

/* Run the database program in the current database the way a worker would, and absorb the result. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._scan_this_database(
    generation bigint,
    host_load1 double precision DEFAULT 0,
    host_cpu_count integer DEFAULT 1,
    host_mem_available_bytes bigint DEFAULT 0,
    host_mem_total_bytes bigint DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    dboid oid := (SELECT d.oid FROM pg_catalog.pg_database d WHERE d.datname = current_database());
    dbname name := current_database();
    doc jsonb;
BEGIN
    PERFORM set_config('adaptive_autovacuum.worker_input',
                       adaptive_autovacuum._worker_input(dboid, dbname, generation, host_load1, host_cpu_count,
                                                         host_mem_available_bytes, host_mem_total_bytes),
                       true);
    PERFORM set_config('adaptive_autovacuum.worker_output', '', true);
    EXECUTE format('DO %L', adaptive_autovacuum._database_program());
    doc := current_setting('adaptive_autovacuum.worker_output')::jsonb;
    PERFORM adaptive_autovacuum._absorb_database_result(dboid, dbname, generation, doc);
    RETURN doc;
END
$$;

/* Diagnostic/test harness: one full controller cycle for the current database in one call. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._run_cycle(
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint,
    others_summary jsonb DEFAULT NULL)
RETURNS TABLE(
    o_eligible integer,
    o_overdue integer,
    o_dead_overdue integer,
    o_insert_overdue integer,
    o_fleet_max_target bigint,
    o_median_scale double precision,
    o_median_thresh double precision,
    o_median_ins_scale double precision,
    o_median_ins_thresh double precision,
    o_debt_tuples bigint,
    o_debt_velocity double precision)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    gen bigint;
    doc jsonb;
    s jsonb;
BEGIN
    IF NOT COALESCE((SELECT p.enabled FROM adaptive_autovacuum.policy p WHERE p.singleton), false) THEN
        RETURN;
    END IF;
    gen := adaptive_autovacuum._begin_generation();
    PERFORM adaptive_autovacuum._recover_stale_emergencies();
    PERFORM adaptive_autovacuum._discover_databases();
    doc := adaptive_autovacuum._scan_this_database(gen, host_load1, host_cpu_count,
                                                   host_mem_available_bytes, host_mem_total_bytes);
    PERFORM adaptive_autovacuum._global_controller(host_load1, host_cpu_count, host_mem_available_bytes,
                                                   host_mem_total_bytes, gen, true, NULL, others_summary);
    s := doc -> 'summary';
    o_eligible := (s ->> 'eligible')::integer;
    o_overdue := (s ->> 'overdue')::integer;
    o_dead_overdue := (s ->> 'dead_overdue')::integer;
    o_insert_overdue := (s ->> 'insert_overdue')::integer;
    o_fleet_max_target := (s ->> 'fleet_max_target')::bigint;
    o_median_scale := (s ->> 'median_scale')::double precision;
    o_median_thresh := (s ->> 'median_thresh')::double precision;
    o_median_ins_scale := (s ->> 'median_ins_scale')::double precision;
    o_median_ins_thresh := (s ->> 'median_ins_thresh')::double precision;
    o_debt_tuples := (s ->> 'debt_tuples')::bigint;
    SELECT ds.debt_velocity INTO o_debt_velocity
    FROM adaptive_autovacuum.database_state ds
    WHERE ds.database_name = current_database();
    RETURN NEXT;
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum._run_cycle(double precision, integer, bigint, bigint, jsonb) IS
'Diagnostic harness: begins a generation, scans the current database with the worker program, absorbs the result and runs the global controller, as the controller process does for every database. others_summary is folded into the cluster evidence as additional databases.';

/* ---------- observability: cluster first, then per database, then per table ---------- */

CREATE OR REPLACE VIEW adaptive_autovacuum.database_status AS
SELECT
    ds.database_name,
    ds.database_oid,
    ds.status,
    ds.table_count,
    ds.eligible_relations,
    ds.overdue_relations,
    ds.emergency_relations,
    ds.recommended_relations,
    ds.debt_tuples AS maintenance_debt_tuples,
    ds.debt_velocity AS maintenance_debt_velocity,
    ds.max_xid_age,
    ds.max_mxid_age,
    ds.scan_generation,
    ds.last_scan_completed_at,
    ds.scan_seconds,
    /* Stale = not revisited within max(10 naptimes, 3 observed sweeps); a slow sweep is not a dead database. */
    ds.status <> 'excluded'
        AND (ds.last_scan_completed_at IS NULL
             OR ds.last_scan_completed_at < clock_timestamp() - make_interval(secs =>
                    GREATEST(10 * COALESCE((SELECT g.setting::integer FROM pg_settings g
                                            WHERE g.name = 'adaptive_autovacuum.naptime_seconds'), 60),
                             3 * COALESCE((SELECT c.observed_sweep_seconds FROM adaptive_autovacuum.controller_state c), 0))))
        AS stale,
    ds.extension_installed,
    ds.last_error,
    ds.first_seen_at,
    ds.last_seen_at
FROM adaptive_autovacuum.database_state ds
ORDER BY ds.emergency_relations DESC NULLS LAST, ds.debt_tuples DESC NULLS LAST, ds.database_name;

COMMENT ON VIEW adaptive_autovacuum.database_status IS
'One row per discovered database: status (healthy, backlog, emergency, failed, excluded, pending), latest scan summary and freshness. Lives in the control database only.';

CREATE OR REPLACE VIEW adaptive_autovacuum.table_status AS
SELECT
    state.database_name,
    state.database_oid,
    state.relation_oid,
    state.relation_name,
    state.state,
    state.consecutive_overdue,
    state.consecutive_healthy,
    state.last_seen_at,
    state.last_dead_tuples,
    state.last_live_tuples,
    state.last_trigger,
    state.last_backlog_ratio,
    state.last_inserts_since_vacuum,
    state.last_insert_backlog_ratio,
    state.last_xid_age,
    state.last_mxid_age,
    state.recommendation_status,
    state.recommended_reloptions,
    state.last_action
FROM adaptive_autovacuum.table_state state;

COMMENT ON VIEW adaptive_autovacuum.table_status IS
'Relations in any managed database the controller currently has state for: non-normal, carrying a table recommendation, or being vacuumed. Healthy relations without a recommendation are absent by design. The last_* metric columns are as of the last row write (state change or hourly heartbeat), not of the last scan.';

/* Table settings are never written by the extension: this is the SQL the operator runs, per database. */
CREATE OR REPLACE VIEW adaptive_autovacuum.table_recommendations AS
SELECT
    state.database_name,
    state.relation_name,
    state.state,
    state.recommendation_status,
    CASE WHEN state.recommendation_status = 'open'
         THEN adaptive_autovacuum._reloptions_sql(state.relation_name, state.recommended_reloptions)
    END AS apply_sql,
    CASE WHEN state.recommendation_status IN ('applied', 'revert')
         THEN adaptive_autovacuum._reloptions_sql(state.relation_name, state.previous_reloptions)
    END AS revert_sql,
    state.recommended_reloptions,
    state.previous_reloptions,
    state.recommendation_reason AS reason,
    state.recommended_at,
    state.applied_at,
    state.last_seen_at,
    state.database_oid,
    state.relation_oid
FROM adaptive_autovacuum.table_state state
WHERE state.recommendation_status IS NOT NULL
ORDER BY CASE state.recommendation_status WHEN 'open' THEN 0 WHEN 'revert' THEN 1 ELSE 2 END,
         state.database_name, state.relation_name;

COMMENT ON VIEW adaptive_autovacuum.table_recommendations IS
'Per-table settings the controller recommends but never writes. open: run apply_sql in database_name (trigger settings always as a threshold + scale factor pair, plus a tiered cost boost). applied: the current reloptions match the recommendation; revert_sql restores the previous values. revert: the table has been normal for healthy_cycles_before_revert checks and the cost boost should be removed with revert_sql. Rows disappear when the table is healthy and nothing of ours is left to revert.';

/* Per-database wraparound board: watch at half the emergency age, alarm at the age itself. */
CREATE OR REPLACE VIEW adaptive_autovacuum.wraparound_status AS
SELECT
    d.datname,
    age(d.datfrozenxid)::bigint AS xid_age,
    mxid_age(d.datminmxid)::bigint AS mxid_age,
    (2147483648 - 3000000 - age(d.datfrozenxid))::bigint AS xids_until_readonly,
    round(100.0 * age(d.datfrozenxid) / (2147483648 - 3000000), 1) AS pct_of_readonly_limit,
    CASE
        WHEN age(d.datfrozenxid) >= p.emergency_xid_age
          OR mxid_age(d.datminmxid) >= p.emergency_mxid_age THEN 'alarm'
        WHEN age(d.datfrozenxid) >= p.emergency_xid_age / 2
          OR mxid_age(d.datminmxid) >= p.emergency_mxid_age / 2 THEN 'watch'
        ELSE 'ok'
    END AS status
FROM pg_catalog.pg_database d
CROSS JOIN adaptive_autovacuum.policy p
ORDER BY age(d.datfrozenxid) DESC;

COMMENT ON VIEW adaptive_autovacuum.wraparound_status IS
'Per-database transaction-age early warning: ok / watch (half the emergency threshold) / alarm (emergency threshold). Alarm means the built-in anti-wraparound autovacuum is not keeping up - investigate stuck replication slots, prepared transactions, or long-running queries; adaptive_autovacuum.horizon_blocker() names the oldest blocker for the current database.';

/* The ten oldest relations of the database it is queried in, TOAST age included. */
CREATE OR REPLACE VIEW adaptive_autovacuum.aging_tables AS
SELECT c.oid::regclass AS table_name,
       GREATEST(age(c.relfrozenxid), COALESCE(age(t.relfrozenxid), 0))::bigint AS xid_age,
       GREATEST(mxid_age(c.relminmxid), COALESCE(mxid_age(t.relminmxid), 0))::bigint AS mxid_age,
       pg_size_pretty(pg_table_size(c.oid)) AS table_size
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_class t ON c.reltoastrelid = t.oid
WHERE c.relkind IN ('r', 'm')
ORDER BY 2 DESC
LIMIT 10;

COMMENT ON VIEW adaptive_autovacuum.aging_tables IS
'Top ten relations of the database you query it in (normally the control database) by transaction age, main heap or TOAST table whichever is older. Per-database maxima for every managed database are in database_status.max_xid_age; wraparound urgency is derived from these ages, never by allocating a transaction ID.';

/* The activity detail holds page deltas per second; times the block size they read as MiB/s by kind. */
CREATE OR REPLACE VIEW adaptive_autovacuum.latest_global_recommendation AS
SELECT recommendation.*,
       round(((recommendation.vacuum_activity_detail ->> 'reads_per_sec')::numeric
              * current_setting('block_size')::numeric / 1048576), 2) AS vacuum_read_mbps,
       round((((recommendation.vacuum_activity_detail ->> 'writes_per_sec')::numeric
               + (recommendation.vacuum_activity_detail ->> 'extends_per_sec')::numeric)
              * current_setting('block_size')::numeric / 1048576), 2) AS vacuum_write_mbps
FROM adaptive_autovacuum.global_recommendations recommendation
ORDER BY recommendation.created_at DESC
LIMIT 1;

COMMENT ON VIEW adaptive_autovacuum.latest_global_recommendation IS
'The newest global_recommendations row plus the autovacuum-worker I/O in MiB/s: vacuum_read_mbps = pages read from storage, vacuum_write_mbps = pages written or extended (pg_stat_io deltas x block size). vacuum_activity_rate and cost_budget_rate stay in vacuum cost units per second, the unit the cost-based delay is defined in.';

CREATE OR REPLACE VIEW adaptive_autovacuum.active_vacuums AS
SELECT
    activity.datname,
    progress.datid,
    progress.relid,
    CASE WHEN progress.datid = (SELECT d.oid
                                FROM pg_catalog.pg_database d
                                WHERE d.datname = pg_catalog.current_database())
         THEN progress.relid::regclass::text
    END AS relation_name,
    activity.pid,
    activity.backend_type,
    activity.query_start,
    clock_timestamp() - activity.query_start AS elapsed,
    progress.phase,
    progress.heap_blks_total,
    progress.heap_blks_scanned,
    progress.index_vacuum_count,
    progress.max_dead_tuple_bytes,
    progress.dead_tuple_bytes,
    /* PG18+ column, NULL on PG17 via the jsonb detour. */
    ((to_jsonb(progress) ->> 'delay_time'))::double precision AS delay_time,
    activity.query LIKE '%(to prevent wraparound)' AS antiwraparound,
    activity.backend_type = 'autovacuum worker' AS is_autovacuum
FROM pg_stat_progress_vacuum progress
JOIN pg_stat_activity activity ON activity.pid = progress.pid;

/* One cluster-wide action history over cluster settings, table changes and emergency vacuums. */
CREATE OR REPLACE VIEW adaptive_autovacuum.actions AS
SELECT q.requested_at AS at,
       'cluster'::text AS action_scope,
       NULL::oid AS database_oid,
       NULL::name AS database_name,
       NULL::oid AS relation_oid,
       NULL::text AS relation_name,
       CASE WHEN q.status = 'applied' THEN 'set_' || q.guc_name
            ELSE q.status || '_' || q.guc_name END AS action_type,
       q.old_value,
       q.desired_value AS new_value,
       q.status,
       q.reason,
       q.generation,
       q.error
FROM adaptive_autovacuum.global_apply_queue q
UNION ALL
SELECT d.decided_at,
       'table',
       d.database_oid,
       d.database_name,
       d.relid,
       d.relation_name,
       d.action,
       NULL,
       CASE WHEN d.proposed_reloptions IS NOT NULL THEN d.proposed_reloptions::text END,
       CASE WHEN d.error IS NOT NULL THEN 'failed'
            WHEN d.applied THEN 'applied'
            ELSE 'observed' END,
       d.reason,
       d.generation,
       d.error
FROM adaptive_autovacuum.decisions d
WHERE d.applied OR d.error IS NOT NULL
UNION ALL
SELECT COALESCE(e.finished_at, e.started_at, e.requested_at),
       'emergency',
       e.database_oid,
       e.database_name,
       e.relid,
       e.relation_name,
       'emergency_vacuum',
       NULL,
       format('cost_limit %s, cost_delay %s ms, work_mem %s MB', e.cost_limit, e.cost_delay_ms, e.work_mem_mb),
       e.status,
       e.reason,
       NULL,
       e.last_error
FROM adaptive_autovacuum.emergency_queue e
ORDER BY 1 DESC;

COMMENT ON VIEW adaptive_autovacuum.actions IS
'One place for everything the extension did: cluster settings applied (scope cluster), per-table ANALYZE runs and their failures (scope table; table settings are only recommended, see table_recommendations), and emergency vacuums (scope emergency), newest first.';

COMMENT ON TABLE adaptive_autovacuum.policy IS
'One-row cluster policy. enabled and dry_run are independent safety gates; included_databases / excluded_databases (LIKE patterns) choose the managed databases.';
COMMENT ON TABLE adaptive_autovacuum.table_state IS
'Hysteresis counters, vacuum fingerprint and the table-setting recommendation for relations in every managed database, keyed by database OID + relation OID. Rows exist only for relations with something to remember and are rewritten only on a state change or hourly.';
COMMENT ON TABLE adaptive_autovacuum.database_state IS
'One row per discovered database: identity, sweep bookkeeping (generation, timing, status) and the latest scan summary the global controller aggregates.';
COMMENT ON TABLE adaptive_autovacuum.decisions IS
'Transition log (UNLOGGED): one row when a relation enters a (state, action) pair, when a change is applied or fails, and when it returns to normal. Not a per-cycle trace.';
COMMENT ON TABLE adaptive_autovacuum.global_recommendations IS
'Cluster-level recommendations and decision history, one row per sweep. Recommendations are queued for automatic application (global_apply_queue) when policy.manage_global_settings = true and dry_run = false and the sweep evidence is complete; otherwise they are recorded only.';
COMMENT ON TABLE adaptive_autovacuum.emergency_queue IS
'Guarded manual VACUUM requests for any managed database, executed one at a time cluster-wide by the emergency worker the controller starts.';
COMMENT ON TABLE adaptive_autovacuum.controller_state IS
'The single authoritative row of cluster controller state: sweep generation and timing, per-sweep counter samples, backlog trend and the cost baseline.';

REVOKE ALL ON ALL TABLES IN SCHEMA adaptive_autovacuum FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA adaptive_autovacuum FROM PUBLIC;
GRANT USAGE ON SCHEMA adaptive_autovacuum TO PUBLIC;
GRANT SELECT ON adaptive_autovacuum.database_status,
                adaptive_autovacuum.table_status,
                adaptive_autovacuum.table_recommendations,
                adaptive_autovacuum.latest_global_recommendation,
                adaptive_autovacuum.active_vacuums,
                adaptive_autovacuum.wraparound_status,
                adaptive_autovacuum.aging_tables,
                adaptive_autovacuum.actions
TO PUBLIC;
/* Host metrics and controller internals go to pg_monitor, not PUBLIC. */
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.host_metrics() TO pg_monitor;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.controller_status() TO pg_monitor;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.horizon_blocker() TO PUBLIC;


/* ---------- operator and installer API ---------- */

/* True when a shared_preload_libraries value lists this library ($libdir/, quotes and suffixes tolerated). */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._preload_lists_library(setting_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN EXISTS (
    SELECT 1
    FROM unnest(string_to_array(coalesce(setting_value, ''), ',')) AS entry
    WHERE regexp_replace(
              regexp_replace(btrim(btrim(entry), '"'''), '^\$libdir[/\\]', ''),
              '\.(so|dll|dylib)$', '') = 'adaptive_autovacuum');

/* Sortable key of a dotted version; a trailing tag ("1.2.0-beta") is ignored. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum._version_key(version text)
RETURNS integer[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN string_to_array(regexp_replace(coalesce(version, '0'), '[^0-9.].*$', ''), '.')::integer[];

/* Idempotent: make sure the singleton policy row exists and is in the active operating mode. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum.enable_default_policy()
RETURNS TABLE (setting text, previous_value text, new_value text)
LANGUAGE plpgsql
AS $$
DECLARE
    prev record;
BEGIN
    INSERT INTO adaptive_autovacuum.policy (singleton)
    VALUES (true)
    ON CONFLICT (singleton) DO NOTHING;

    SELECT p.enabled, p.dry_run, p.manage_global_settings
    INTO prev
    FROM adaptive_autovacuum.policy p
    WHERE p.singleton;

    UPDATE adaptive_autovacuum.policy
    SET enabled = true,
        dry_run = false,
        manage_global_settings = true,
        updated_at = clock_timestamp(),
        updated_by = current_user
    WHERE singleton
      AND (NOT enabled OR dry_run OR NOT manage_global_settings);

    RETURN QUERY
    VALUES ('enabled', prev.enabled::text, 'true'),
           ('dry_run', prev.dry_run::text, 'false'),
           ('manage_global_settings', prev.manage_global_settings::text, 'true');
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum.enable_default_policy() IS
'Installer/operator API: puts the cluster policy into the active mode (enabled, applying, managing cluster settings). Safe to call repeatedly; returns the previous and new value of each switch. Other policy columns are never touched.';

/* One-row machine-readable state of the whole cluster installation; every column is nullable. */
CREATE OR REPLACE FUNCTION adaptive_autovacuum.status()
RETURNS TABLE (
    extension_version         text,
    available_version         text,
    server_version            text,
    library_preloaded         boolean,
    preload_pending_restart   boolean,
    control_database          text,
    is_control_database       boolean,
    launcher_enabled          boolean,
    launcher_running          boolean,
    controller_running        boolean,
    controller_state          text,
    in_recovery               boolean,
    policy_enabled            boolean,
    policy_dry_run            boolean,
    manage_global_settings    boolean,
    cluster_generation        bigint,
    last_complete_generation  bigint,
    last_sweep_started_at     timestamptz,
    last_sweep_completed_at   timestamptz,
    seconds_since_last_sweep  double precision,
    sweep_seconds             double precision,
    naptime_seconds           integer,
    managed_databases         bigint,
    excluded_databases        bigint,
    failed_databases          bigint,
    stale_databases           bigint,
    tables_seen               bigint,
    tables_needing_vacuum     bigint,
    tables_emergency          bigint,
    open_table_recommendations bigint,
    maintenance_debt_tuples   bigint,
    maintenance_debt_velocity double precision,
    backlog_trend             text,
    autovacuum_workers_running bigint,
    autovacuum_max_workers    integer,
    autovacuum_naptime_seconds integer,
    cost_limit                integer,
    cost_delay_ms             double precision,
    pending_global_changes    bigint,
    failed_global_changes_24h bigint,
    relation_errors_24h       bigint,
    active_emergencies        bigint,
    wraparound_status         text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    css record;
    file_value text;
    current_lists boolean;
    file_lists boolean;
    ctl text;
BEGIN
    SELECT * INTO css FROM adaptive_autovacuum.controller_status();

    current_lists := adaptive_autovacuum._preload_lists_library(
                         current_setting('shared_preload_libraries'));
    SELECT f.setting INTO file_value
    FROM pg_file_settings f
    WHERE f.name = 'shared_preload_libraries'
    ORDER BY f.seqno DESC
    LIMIT 1;
    /* Not set in any file (command line or defaults): nothing can be pending. */
    file_lists := CASE WHEN file_value IS NULL THEN current_lists
                       ELSE adaptive_autovacuum._preload_lists_library(file_value) END;

    ctl := coalesce(nullif(current_setting('adaptive_autovacuum.control_database', true), ''), 'postgres');

    RETURN QUERY
    SELECT
        (SELECT e.extversion FROM pg_extension e WHERE e.extname = 'adaptive_autovacuum'),
        (SELECT a.default_version FROM pg_available_extensions a WHERE a.name = 'adaptive_autovacuum'),
        current_setting('server_version'),
        css.available,
        /* The file says one thing and the running postmaster another: a restart is pending. */
        (file_lists IS DISTINCT FROM current_lists),
        ctl,
        current_database()::text = ctl,
        nullif(current_setting('adaptive_autovacuum.enabled', true), '')::boolean,
        EXISTS (SELECT 1 FROM pg_stat_activity a
                WHERE a.backend_type = 'adaptive autovacuum launcher'),
        EXISTS (SELECT 1 FROM pg_stat_activity a
                WHERE a.backend_type = 'adaptive autovacuum controller'),
        css.controller_state,
        pg_is_in_recovery(),
        (SELECT p.enabled FROM adaptive_autovacuum.policy p WHERE p.singleton),
        (SELECT p.dry_run FROM adaptive_autovacuum.policy p WHERE p.singleton),
        (SELECT p.manage_global_settings FROM adaptive_autovacuum.policy p WHERE p.singleton),
        (SELECT c.cluster_generation FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT c.last_complete_generation FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT c.last_sweep_started_at FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT c.last_sweep_completed_at FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT extract(epoch FROM clock_timestamp() - c.last_sweep_completed_at)::double precision
         FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT c.observed_sweep_seconds FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT g.setting::integer FROM pg_settings g WHERE g.name = 'adaptive_autovacuum.naptime_seconds'),
        (SELECT count(*) FROM adaptive_autovacuum.database_state d WHERE d.status <> 'excluded'),
        (SELECT count(*) FROM adaptive_autovacuum.database_state d WHERE d.status = 'excluded'),
        (SELECT count(*) FROM adaptive_autovacuum.database_state d WHERE d.status = 'failed'),
        (SELECT count(*) FROM adaptive_autovacuum.database_status d WHERE d.stale),
        (SELECT sum(d.table_count) FROM adaptive_autovacuum.database_state d WHERE d.status <> 'excluded'),
        (SELECT sum(d.overdue_relations) FROM adaptive_autovacuum.database_state d WHERE d.status <> 'excluded'),
        (SELECT sum(d.emergency_relations) FROM adaptive_autovacuum.database_state d WHERE d.status <> 'excluded'),
        (SELECT count(*) FROM adaptive_autovacuum.table_state t WHERE t.recommendation_status = 'open'),
        (SELECT c.last_debt_tuples FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT c.debt_velocity FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT r.backlog_trend FROM adaptive_autovacuum.latest_global_recommendation r),
        (SELECT count(*) FROM pg_stat_activity a WHERE a.backend_type = 'autovacuum worker'),
        (SELECT g.setting::integer FROM pg_settings g WHERE g.name = 'autovacuum_max_workers'),
        (SELECT g.setting::integer FROM pg_settings g WHERE g.name = 'autovacuum_naptime'),
        (SELECT CASE WHEN g.setting::integer < 0
                     THEN (SELECT v.setting::integer FROM pg_settings v WHERE v.name = 'vacuum_cost_limit')
                     ELSE g.setting::integer END
         FROM pg_settings g WHERE g.name = 'autovacuum_vacuum_cost_limit'),
        (SELECT g.setting::double precision FROM pg_settings g WHERE g.name = 'autovacuum_vacuum_cost_delay'),
        (SELECT count(*) FROM adaptive_autovacuum.global_apply_queue q WHERE q.status = 'pending'),
        (SELECT count(*) FROM adaptive_autovacuum.global_apply_queue q
         WHERE q.status = 'failed' AND q.requested_at > clock_timestamp() - interval '24 hours'),
        (SELECT count(*) FROM adaptive_autovacuum.decisions d
         WHERE d.error IS NOT NULL AND d.decided_at > clock_timestamp() - interval '24 hours'),
        (SELECT count(*) FROM adaptive_autovacuum.emergency_queue e
         WHERE e.status IN ('pending', 'running')),
        (SELECT CASE WHEN bool_or(w.status = 'alarm') THEN 'alarm'
                     WHEN bool_or(w.status = 'watch') THEN 'watch'
                     ELSE 'ok' END
         FROM adaptive_autovacuum.wraparound_status w);
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum.status() IS
'Installer/operator API: one row describing the whole cluster installation - library, launcher and controller, cluster policy, sweep progress, managed databases, backlog, open table recommendations and emergency state. Readable by pg_monitor; meaningful in the control database.';

/* Health checks with a fixed vocabulary: OK, WARN, FAIL, RESTART_REQUIRED (19 checks). */
CREATE OR REPLACE FUNCTION adaptive_autovacuum.doctor()
RETURNS TABLE (check_name text, status text, detail text, remediation text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    s record;
    file_errors text;
    stale_after integer;
    autovacuum_on boolean;
    delay_timing text;
    dup_dbs text;
BEGIN
    SELECT * INTO s FROM adaptive_autovacuum.status();

    /* 1. library_preloaded */
    IF s.library_preloaded THEN
        RETURN QUERY SELECT 'library_preloaded', 'OK',
            'shared_preload_libraries lists adaptive_autovacuum and the library is loaded',
            NULL::text;
    ELSIF s.preload_pending_restart THEN
        RETURN QUERY SELECT 'library_preloaded', 'RESTART_REQUIRED',
            'shared_preload_libraries was changed in the configuration file but the running server has not been restarted',
            'Restart the PostgreSQL service for this cluster.';
    ELSE
        RETURN QUERY SELECT 'library_preloaded', 'FAIL',
            'adaptive_autovacuum is not in shared_preload_libraries (current value: '
                || coalesce(nullif(current_setting('shared_preload_libraries'), ''), '<empty>') || ')',
            'Append adaptive_autovacuum to shared_preload_libraries, keeping the existing entries, then restart PostgreSQL.';
    END IF;

    /* 2. config_file_errors */
    SELECT string_agg(f.name || ': ' || f.error, '; ')
    INTO file_errors
    FROM pg_file_settings f
    WHERE f.error IS NOT NULL
      AND (f.name = 'shared_preload_libraries' OR f.name LIKE 'adaptive\_autovacuum.%');
    IF file_errors IS NULL THEN
        RETURN QUERY SELECT 'config_file_errors', 'OK',
            'no configuration file errors for shared_preload_libraries or adaptive_autovacuum.*',
            NULL::text;
    ELSE
        RETURN QUERY SELECT 'config_file_errors', 'FAIL', file_errors,
            'Fix the reported setting in postgresql.conf / postgresql.auto.conf (SELECT * FROM pg_file_settings WHERE error IS NOT NULL).';
    END IF;

    /* 3. extension_version */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'extension_version', 'FAIL',
            'the extension is not created in database ' || current_database(),
            'CREATE EXTENSION adaptive_autovacuum; (in the control database ' || s.control_database || ')';
    ELSIF s.available_version IS NULL THEN
        RETURN QUERY SELECT 'extension_version', 'FAIL',
            'installed version ' || s.extension_version || ' but no control file is visible to the server',
            'Reinstall the extension files (control and SQL scripts) into the server''s sharedir/extension.';
    ELSIF adaptive_autovacuum._version_key(s.extension_version) < adaptive_autovacuum._version_key(s.available_version) THEN
        RETURN QUERY SELECT 'extension_version', 'WARN',
            'installed ' || s.extension_version || ', available ' || s.available_version,
            'ALTER EXTENSION adaptive_autovacuum UPDATE;';
    ELSIF adaptive_autovacuum._version_key(s.extension_version) > adaptive_autovacuum._version_key(s.available_version) THEN
        RETURN QUERY SELECT 'extension_version', 'FAIL',
            'installed ' || s.extension_version || ' is newer than the files on disk (' || s.available_version || ')',
            'Reinstall extension files of version ' || s.extension_version || ' or newer; never downgrade the SQL objects.';
    ELSE
        RETURN QUERY SELECT 'extension_version', 'OK',
            'installed ' || s.extension_version || ' (current)', NULL::text;
    END IF;

    /* 4. control_database */
    IF s.is_control_database THEN
        RETURN QUERY SELECT 'control_database', 'OK',
            current_database() || ' is the control database; every connectable database is managed from here',
            NULL::text;
    ELSE
        RETURN QUERY SELECT 'control_database', 'FAIL',
            'the extension is created in ' || current_database() || ' but the control database is '
                || s.control_database || ' (adaptive_autovacuum.control_database); objects here are ignored',
            'Install the extension once, in ' || s.control_database
                || ', and DROP EXTENSION adaptive_autovacuum here; or set adaptive_autovacuum.control_database = '''
                || current_database() || ''' and reload.';
    END IF;

    /* 5. launcher_enabled */
    IF NOT s.library_preloaded THEN
        RETURN QUERY SELECT 'launcher_enabled', 'WARN',
            'adaptive_autovacuum.enabled cannot take effect until the library is preloaded',
            'Resolve library_preloaded first.';
    ELSIF coalesce(s.launcher_enabled, false) THEN
        RETURN QUERY SELECT 'launcher_enabled', 'OK', 'adaptive_autovacuum.enabled = on', NULL::text;
    ELSE
        RETURN QUERY SELECT 'launcher_enabled', 'WARN',
            'adaptive_autovacuum.enabled = off: the launcher is idle and no database is managed',
            'ALTER SYSTEM SET adaptive_autovacuum.enabled = on; SELECT pg_reload_conf();';
    END IF;

    /* 6. launcher_running */
    IF s.launcher_running THEN
        RETURN QUERY SELECT 'launcher_running', 'OK',
            'the adaptive autovacuum launcher background worker is running', NULL::text;
    ELSIF NOT s.library_preloaded THEN
        RETURN QUERY SELECT 'launcher_running', 'FAIL',
            'no launcher: background workers are registered only when the library is preloaded',
            'Resolve library_preloaded first.';
    ELSIF s.in_recovery THEN
        RETURN QUERY SELECT 'launcher_running', 'WARN',
            'the server is in recovery; the launcher starts after promotion', NULL::text;
    ELSE
        RETURN QUERY SELECT 'launcher_running', 'FAIL',
            'the library is preloaded but no launcher worker is visible in pg_stat_activity',
            'Check the server log for "adaptive autovacuum launcher" errors and verify max_worker_processes leaves room for the launcher, the controller and max_database_workers.';
    END IF;

    /* 7. controller_running */
    IF s.controller_running THEN
        RETURN QUERY SELECT 'controller_running', 'OK',
            'the cluster controller is connected to the control database (' || coalesce(s.controller_state, 'running') || ')',
            NULL::text;
    ELSIF NOT s.library_preloaded OR NOT coalesce(s.launcher_enabled, false) OR s.in_recovery THEN
        RETURN QUERY SELECT 'controller_running', 'WARN',
            'no controller: ' || coalesce(s.controller_state, 'the launcher is not active'),
            'Resolve library_preloaded, launcher_enabled and recovery first.';
    ELSE
        RETURN QUERY SELECT 'controller_running', 'FAIL',
            'the launcher runs but the controller is not connected: ' || coalesce(s.controller_state, 'unknown'),
            'Check that adaptive_autovacuum.control_database (' || s.control_database
                || ') exists and allows connections, that max_worker_processes has a free slot, and the server log for "adaptive autovacuum controller".';
    END IF;

    /* 8. policy */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'policy', 'FAIL', 'no policy: the extension is not created here',
            'CREATE EXTENSION adaptive_autovacuum;';
    ELSIF coalesce(s.policy_enabled, false) AND NOT coalesce(s.policy_dry_run, true) THEN
        RETURN QUERY SELECT 'policy', 'OK',
            'active (enabled'
                || CASE WHEN s.manage_global_settings THEN ', applying cluster settings' ELSE ', cluster settings recorded only' END
                || ', table settings recommended only)',
            NULL::text;
    ELSIF coalesce(s.policy_enabled, false) THEN
        RETURN QUERY SELECT 'policy', 'WARN',
            'watch-only: dry_run = true, decisions are logged but nothing is changed',
            'UPDATE adaptive_autovacuum.policy SET dry_run = false; or SELECT adaptive_autovacuum.enable_default_policy();';
    ELSE
        RETURN QUERY SELECT 'policy', 'WARN',
            'paused: policy.enabled = false for the whole cluster',
            'SELECT adaptive_autovacuum.enable_default_policy();';
    END IF;

    /* 9. last_sweep */
    stale_after := greatest(3 * coalesce(s.naptime_seconds, 60), 600,
                            ceil(3 * coalesce(s.sweep_seconds, 0))::integer);
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'last_sweep', 'FAIL', 'no controller state: the extension is not created here',
            'CREATE EXTENSION adaptive_autovacuum;';
    ELSIF s.last_sweep_completed_at IS NULL THEN
        IF s.controller_running AND coalesce(s.launcher_enabled, false) AND coalesce(s.policy_enabled, false) THEN
            RETURN QUERY SELECT 'last_sweep', 'WARN',
                'no sweep completed yet; the first one runs within adaptive_autovacuum.naptime_seconds ('
                    || coalesce(s.naptime_seconds::text, '60') || ' s) of the controller start',
                'Re-run the check in a minute.';
        ELSE
            RETURN QUERY SELECT 'last_sweep', 'WARN',
                'no sweep has completed yet',
                'Resolve controller_running, launcher_enabled and policy first.';
        END IF;
    ELSIF s.seconds_since_last_sweep > stale_after THEN
        RETURN QUERY SELECT 'last_sweep', 'WARN',
            'last sweep completed ' || round(s.seconds_since_last_sweep)::text || ' s ago (stale after ' || stale_after || ' s)',
            'Check the server log; a database worker may be blocked (adaptive_autovacuum.database_worker_timeout_seconds) or the launcher was turned off.';
    ELSE
        RETURN QUERY SELECT 'last_sweep', 'OK',
            'sweep ' || coalesce(s.cluster_generation::text, '?') || ' completed ' || round(s.seconds_since_last_sweep)::text
                || ' s ago over ' || coalesce(s.managed_databases::text, '?') || ' database(s)', NULL::text;
    END IF;

    /* 10. cluster_evidence */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'cluster_evidence', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.failed_databases, 0) > 0 THEN
        RETURN QUERY SELECT 'cluster_evidence', 'WARN',
            s.failed_databases::text || ' database(s) failed their last scan; cluster-wide changes are recorded but not applied until every database is scanned',
            'SELECT database_name, last_error FROM adaptive_autovacuum.database_status WHERE status = ''failed'';';
    ELSIF coalesce(s.stale_databases, 0) > 0 AND s.last_sweep_completed_at IS NOT NULL THEN
        RETURN QUERY SELECT 'cluster_evidence', 'WARN',
            s.stale_databases::text || ' database(s) have not been revisited within the freshness window',
            'SELECT * FROM adaptive_autovacuum.database_status WHERE stale;';
    ELSE
        RETURN QUERY SELECT 'cluster_evidence', 'OK',
            coalesce(s.managed_databases, 0)::text || ' managed database(s)'
                || CASE WHEN coalesce(s.excluded_databases, 0) > 0 THEN ', ' || s.excluded_databases::text || ' excluded by policy' ELSE '' END
                || CASE WHEN s.last_complete_generation IS NOT NULL THEN ', last complete sweep ' || s.last_complete_generation::text ELSE '' END,
            NULL::text;
    END IF;

    /* 11. duplicate_installations */
    SELECT string_agg(d.database_name, ', ' ORDER BY d.database_name)
    INTO dup_dbs
    FROM adaptive_autovacuum.database_state d
    WHERE d.extension_installed AND d.database_name <> s.control_database;
    IF dup_dbs IS NULL THEN
        RETURN QUERY SELECT 'duplicate_installations', 'OK',
            'the extension is installed only in the control database', NULL::text;
    ELSE
        RETURN QUERY SELECT 'duplicate_installations', 'WARN',
            'the extension is also created in: ' || dup_dbs || '; those copies are ignored (one control plane per cluster)',
            'DROP EXTENSION adaptive_autovacuum; in each of those databases.';
    END IF;

    /* 12. global_changes */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'global_changes', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.failed_global_changes_24h, 0) > 0 THEN
        RETURN QUERY SELECT 'global_changes', 'WARN',
            s.failed_global_changes_24h::text || ' cluster-setting change(s) failed in the last 24 h'
                || CASE WHEN s.pending_global_changes > 0 THEN ', ' || s.pending_global_changes::text || ' pending' ELSE '' END,
            'SELECT guc_name, desired_value, error FROM adaptive_autovacuum.global_apply_queue WHERE status = ''failed'' ORDER BY requested_at DESC;';
    ELSE
        RETURN QUERY SELECT 'global_changes', 'OK',
            'no failed cluster-setting changes in the last 24 h'
                || CASE WHEN s.pending_global_changes > 0 THEN ', ' || s.pending_global_changes::text || ' pending' ELSE '' END,
            NULL::text;
    END IF;

    /* 13. relation_errors */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'relation_errors', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.relation_errors_24h, 0) > 0 THEN
        RETURN QUERY SELECT 'relation_errors', 'WARN',
            s.relation_errors_24h::text || ' per-table action(s) failed in the last 24 h',
            'SELECT decided_at, database_name, relation_name, action, error FROM adaptive_autovacuum.decisions WHERE error IS NOT NULL ORDER BY decided_at DESC;';
    ELSE
        RETURN QUERY SELECT 'relation_errors', 'OK', 'no failed per-table actions in the last 24 h', NULL::text;
    END IF;

    /* 14. table_recommendations */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'table_recommendations', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.open_table_recommendations, 0) > 0 THEN
        RETURN QUERY SELECT 'table_recommendations', 'WARN',
            s.open_table_recommendations::text || ' table(s) have an open settings recommendation waiting for an operator',
            'SELECT database_name, relation_name, apply_sql, reason FROM adaptive_autovacuum.table_recommendations WHERE recommendation_status = ''open''; run apply_sql in that database.';
    ELSE
        RETURN QUERY SELECT 'table_recommendations', 'OK', 'no open table settings recommendation', NULL::text;
    END IF;

    /* 15. emergency_vacuum */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'emergency_vacuum', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.active_emergencies, 0) > 0 THEN
        RETURN QUERY SELECT 'emergency_vacuum', 'WARN',
            s.active_emergencies::text || ' emergency VACUUM request(s) pending or running',
            'SELECT * FROM adaptive_autovacuum.emergency_queue WHERE status IN (''pending'', ''running'');';
    ELSE
        RETURN QUERY SELECT 'emergency_vacuum', 'OK', 'no emergency VACUUM pending or running', NULL::text;
    END IF;

    /* 16. wraparound */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'wraparound', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF s.wraparound_status = 'alarm' THEN
        RETURN QUERY SELECT 'wraparound', 'FAIL',
            'a database has reached the emergency transaction-age threshold',
            'SELECT * FROM adaptive_autovacuum.wraparound_status; SELECT * FROM adaptive_autovacuum.horizon_blocker();';
    ELSIF s.wraparound_status = 'watch' THEN
        RETURN QUERY SELECT 'wraparound', 'WARN',
            'a database is past half the emergency transaction-age threshold',
            'SELECT * FROM adaptive_autovacuum.wraparound_status;';
    ELSE
        RETURN QUERY SELECT 'wraparound', 'OK', 'all databases are below the watch threshold', NULL::text;
    END IF;

    /* 17. autovacuum */
    autovacuum_on := current_setting('autovacuum')::boolean;
    IF autovacuum_on THEN
        RETURN QUERY SELECT 'autovacuum', 'OK', 'autovacuum = on', NULL::text;
    ELSE
        RETURN QUERY SELECT 'autovacuum', 'WARN',
            'autovacuum = off; the controller turns it back on before its next sweep (repair_disabled_autovacuum)',
            'ALTER SYSTEM SET autovacuum = on; SELECT pg_reload_conf();';
    END IF;

    /* 18. track_cost_delay_timing (PG18+) */
    delay_timing := current_setting('track_cost_delay_timing', true);
    IF delay_timing IS NULL THEN
        RETURN QUERY SELECT 'track_cost_delay_timing', 'OK',
            'not available on this server version; delay-bound vacuums are inferred from the cost settings', NULL::text;
    ELSIF delay_timing = 'on' THEN
        RETURN QUERY SELECT 'track_cost_delay_timing', 'OK', 'track_cost_delay_timing = on', NULL::text;
    ELSE
        RETURN QUERY SELECT 'track_cost_delay_timing', 'WARN',
            'track_cost_delay_timing = off; vacuums that are mostly sleeping are not recognised as delay-bound',
            'ALTER SYSTEM SET track_cost_delay_timing = on; SELECT pg_reload_conf();';
    END IF;

    /* 19. recovery */
    IF s.in_recovery THEN
        RETURN QUERY SELECT 'recovery', 'WARN',
            'this server is a standby; the controller stays idle until promotion', NULL::text;
    ELSE
        RETURN QUERY SELECT 'recovery', 'OK', 'primary server', NULL::text;
    END IF;
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum.doctor() IS
'Installer/operator API: one row per health check with status OK, WARN, FAIL or RESTART_REQUIRED, a detail line and a remediation command. Readable by pg_monitor; run it in the control database.';

REVOKE ALL ON FUNCTION adaptive_autovacuum._preload_lists_library(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum._version_key(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum.enable_default_policy() FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum.status() FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum.doctor() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum._preload_lists_library(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum._version_key(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.status() TO pg_monitor;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.doctor() TO pg_monitor;
