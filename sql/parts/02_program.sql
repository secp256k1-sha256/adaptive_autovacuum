
/* The per-database program: run by the database worker as an anonymous block in the managed database. */
/* It needs no extension objects there: input arrives in adaptive_autovacuum.worker_input, output leaves in worker_output. */
CREATE FUNCTION adaptive_autovacuum._database_program()
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

    autovacuum_enabled_global boolean;
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
    pv_original_reloptions text[];
    pv_original_captured boolean;
    pv_managed_values jsonb;
    pv_ownership_conflict boolean;
    pv_state text;
    pv_consecutive_overdue integer;
    pv_consecutive_healthy integer;
    pv_last_change_at timestamptz;
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
    relation_json jsonb;

    change_count integer := 0;
    cost_boost_count integer := 0;
    wants_cost_boost boolean;
    has_existing_cost_boost boolean;
    desired_cost_limit integer;
    desired_cost_delay double precision;
    tier_cost_limit integer;
    tier_cost_delay double precision;
    prev_boost integer;
    budget_headroom integer;
    cost_budget_used integer := 0;
    cooldown_ok boolean;
    current_matches_managed boolean;
    should_apply boolean;
    applied boolean;
    action_name text;
    action_error text;
    apply_kind text;
    apply_desired jsonb;
    rec_option_name text;
    rec_option_value text;
    rec_original_value text;
    rec_reset_names text[];
    rec_set_parts text[];
    state_needed boolean;
    new_last_change_at timestamptz;
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
        overdue_cycles_before_change integer, healthy_cycles_before_restore integer,
        change_cooldown_seconds integer, lock_timeout_ms integer, max_changes_per_cycle integer,
        analyze_missing_stats boolean, analyze_missing_stats_budget_ms integer,
        manage_table_costs boolean, max_boosted_relations integer,
        elevated_cost_limit integer, urgent_cost_limit integer, critical_cost_limit integer,
        elevated_cost_delay_ms double precision, urgent_cost_delay_ms double precision, critical_cost_delay_ms double precision,
        boost_ramp_factor double precision, boost_total_cost_limit_budget integer,
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
    /* Cost boosts held in the other databases count against the cluster-wide budget. */
    cost_boost_count := COALESCE((input -> 'cluster' ->> 'boosted_relations_elsewhere')::integer, 0);
    cost_budget_used := COALESCE((input -> 'cluster' ->> 'boost_budget_used_elsewhere')::integer, 0);

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

    /* This database's own cost boosts, from the previous state rows handed in. */
    SELECT cost_boost_count + count(*),
           cost_budget_used + COALESCE(sum((ts.managed_values ->> 'autovacuum_vacuum_cost_limit')::numeric), 0)::integer
    INTO cost_boost_count, cost_budget_used
    FROM jsonb_to_recordset(COALESCE(input -> 'table_state', '[]'::jsonb))
         AS ts(managed_values jsonb, ownership_conflict boolean)
    WHERE ts.managed_values ? 'autovacuum_vacuum_cost_limit'
      AND NOT ts.ownership_conflict;

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
                   AS x(relation_oid oid, relation_name text, original_reloptions text[],
                        original_captured boolean, managed_values jsonb, ownership_conflict boolean,
                        state text, consecutive_overdue integer, consecutive_healthy integer,
                        last_seen_at timestamptz, last_change_at timestamptz,
                        last_vacuum_pid integer, last_vacuum_progress text,
                        vacuum_stalled_cycles integer, last_error text, last_action text)
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
            /* Previous state joined once here; NULL = never persisted. */
            rs.relation_oid IS NOT NULL AS state_exists,
            rs.relation_name AS prev_relation_name,
            rs.original_reloptions AS prev_original_reloptions,
            rs.original_captured AS prev_original_captured,
            rs.managed_values AS prev_managed_values,
            rs.ownership_conflict AS prev_ownership_conflict,
            rs.state AS prev_state,
            rs.consecutive_overdue AS prev_consecutive_overdue,
            rs.consecutive_healthy AS prev_consecutive_healthy,
            rs.last_seen_at AS prev_last_seen_at,
            rs.last_change_at AS prev_last_change_at,
            rs.last_vacuum_pid AS prev_last_vacuum_pid,
            rs.last_vacuum_progress AS prev_last_vacuum_progress,
            rs.vacuum_stalled_cycles AS prev_vacuum_stalled_cycles,
            rs.last_error AS prev_last_error,
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
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_insert_scale_factor') AS ro_insert_scale_factor
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
            insert_ratio := 0;
        ELSE
            insert_ratio := r.inserts_since_vacuum /
                            GREATEST(1, r.insert_threshold
                                        + r.insert_scale_factor
                                          * GREATEST(r.reltuples, 0)
                                          * r.insert_pcnt_unfrozen);
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

        /* r.prev_* is the before-image for the write-on-change test; pv_* is mutated this cycle. */
        pv_original_reloptions := r.prev_original_reloptions;
        pv_original_captured := COALESCE(r.prev_original_captured, false);
        pv_managed_values := COALESCE(r.prev_managed_values, '{}'::jsonb);
        pv_ownership_conflict := COALESCE(r.prev_ownership_conflict, false);
        pv_state := COALESCE(r.prev_state, 'normal');
        pv_consecutive_overdue := COALESCE(r.prev_consecutive_overdue, 0);
        pv_consecutive_healthy := COALESCE(r.prev_consecutive_healthy, 0);
        pv_last_change_at := r.prev_last_change_at;
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
            reason := format('XID/MXID age ratio vs freeze_max_age is elevated (xid=%s, mxid=%s); the forced autovacuum will handle this - prioritized only.', to_char(xid_ratio, 'FM0.000'), to_char(mxid_ratio, 'FM0.000'));
        ELSIF pressure_ratio >= p.backlog_critical_ratio THEN
            relation_state := 'backlog_critical';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM0.00'));
        ELSIF pressure_ratio >= p.backlog_urgent_ratio THEN
            relation_state := 'backlog_urgent';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM0.00'));
        ELSIF pressure_ratio >= p.backlog_elevated_ratio THEN
            relation_state := 'backlog_elevated';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM0.00'));
        ELSE
            relation_state := 'normal';
            reason := 'Relation is within configured backlog and wraparound limits.';
        END IF;

        /* Counters saturate at the thresholds they are compared with. */
        IF relation_state = 'normal' THEN
            overdue_cycles := 0;
            healthy_cycles := LEAST(pv_consecutive_healthy + 1,
                                    p.healthy_cycles_before_restore);
        ELSE
            overdue_cycles := LEAST(pv_consecutive_overdue + 1,
                                    p.overdue_cycles_before_change);
            healthy_cycles := 0;
            overdue_relation_count := overdue_relation_count + 1;
        END IF;

        /* Ownership check: every managed key must still hold the value written last time. */
        SELECT NOT EXISTS
        (
            SELECT 1
            FROM jsonb_each_text(pv_managed_values) AS managed(option_name, option_value)
            WHERE (SELECT split_part(o, '=', 2) FROM unnest(r.reloptions) AS o
                   WHERE split_part(o, '=', 1) = managed.option_name LIMIT 1)::numeric
                  IS DISTINCT FROM managed.option_value::numeric
        )
        INTO current_matches_managed;

        IF pv_managed_values <> '{}'::jsonb AND NOT current_matches_managed THEN
            pv_ownership_conflict := true;
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

        IF relation_state LIKE 'backlog_%' AND r.normal_autovacuum_enabled THEN
            desired_values := '{}'::jsonb;

            IF backlog_ratio >= p.backlog_elevated_ratio THEN
                desired_values := desired_values || jsonb_build_object(
                    'autovacuum_vacuum_threshold', desired_threshold::text,
                    'autovacuum_vacuum_scale_factor', trim(trailing '.' from to_char(desired_scale_factor, 'FM0.999999999'))
                );
                /* The per-table trigger ceiling exists only on PG18+. */
                IF server_vnum >= 180000 THEN
                    desired_values := desired_values || jsonb_build_object(
                        'autovacuum_vacuum_max_threshold', desired_max_threshold::text
                    );
                END IF;
            END IF;

            IF insert_ratio >= p.backlog_elevated_ratio THEN
                desired_values := desired_values || jsonb_build_object(
                    'autovacuum_vacuum_insert_threshold', desired_insert_threshold::text,
                    'autovacuum_vacuum_insert_scale_factor', trim(trailing '.' from to_char(desired_insert_scale, 'FM0.999999999'))
                );
            END IF;
        ELSIF relation_state LIKE 'backlog_%' THEN
            desired_values := pv_managed_values;
        ELSIF relation_state LIKE 'wraparound_%' THEN
            desired_values := pv_managed_values
                              - 'autovacuum_vacuum_cost_limit'
                              - 'autovacuum_vacuum_cost_delay';
        ELSIF relation_state = 'horizon_blocked' THEN
            /* Horizon blocked: hold as-is, aggression cannot help and a restore would flap. */
            desired_values := pv_managed_values;
        ELSE
            desired_values := '{}'::jsonb;
        END IF;

        has_existing_cost_boost := pv_managed_values ? 'autovacuum_vacuum_cost_limit';
        wants_cost_boost := p.manage_table_costs
                            AND relation_state <> 'normal'
                            AND relation_state <> 'horizon_blocked'
                            AND (r.normal_autovacuum_enabled OR relation_state LIKE 'wraparound_%')
                            AND (NOT host_pressure OR relation_state = 'wraparound_critical')
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

            /* Ramp: enter at the elevated tier, multiply per change window, capped by the severity tier. */
            prev_boost := NULLIF(pv_managed_values ->> 'autovacuum_vacuum_cost_limit', '')::integer;
            IF prev_boost IS NULL THEN
                desired_cost_limit := LEAST(tier_cost_limit, p.elevated_cost_limit);
            ELSE
                desired_cost_limit := LEAST(tier_cost_limit,
                                            GREATEST(prev_boost,
                                                     ceil(prev_boost * p.boost_ramp_factor)::integer));
            END IF;
            desired_cost_delay := tier_cost_delay;

            /* Cluster-wide admission budget for simultaneous cost boosts. */
            budget_headroom := p.boost_total_cost_limit_budget - cost_budget_used
                               + COALESCE(prev_boost, 0);
            IF desired_cost_limit > budget_headroom THEN
                desired_cost_limit := GREATEST(COALESCE(prev_boost, 0), budget_headroom);
            END IF;

            IF desired_cost_limit >= LEAST(p.elevated_cost_limit, tier_cost_limit) THEN
                desired_values := desired_values || jsonb_build_object(
                    'autovacuum_vacuum_cost_limit', desired_cost_limit::text,
                    'autovacuum_vacuum_cost_delay', trim(trailing '.' from to_char(desired_cost_delay, 'FM0.999'))
                );
                cost_budget_used := cost_budget_used - COALESCE(prev_boost, 0)
                                    + desired_cost_limit;

                IF NOT has_existing_cost_boost THEN
                    cost_boost_count := cost_boost_count + 1;
                END IF;
            END IF;
        END IF;

        /* Built only when a decision row can be written this cycle. */
        relation_json := NULL;
        IF relation_state <> 'normal'
           OR pv_state <> 'normal'
           OR pv_managed_values <> '{}'::jsonb
           OR pv_ownership_conflict THEN
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

        cooldown_ok := pv_last_change_at IS NULL
                       OR clock_timestamp() - pv_last_change_at
                          >= make_interval(secs => p.change_cooldown_seconds);

        should_apply := relation_state <> 'normal'
                        AND overdue_cycles >= p.overdue_cycles_before_change
                        AND cooldown_ok
                        AND r.vacuum_pid IS NULL
                        AND NOT pv_ownership_conflict
                        AND change_count < p.max_changes_per_cycle
                        AND desired_values IS DISTINCT FROM pv_managed_values;

        applied := false;
        action_error := NULL;
        action_name := 'observe';
        apply_kind := NULL;

        IF should_apply THEN
            action_name := CASE WHEN p.dry_run THEN 'propose_reloptions' ELSE 'set_reloptions' END;
            IF NOT p.dry_run THEN
                apply_kind := 'set';
                apply_desired := desired_values;
            END IF;
        ELSIF relation_state = 'normal'
           AND healthy_cycles >= p.healthy_cycles_before_restore
           AND pv_managed_values <> '{}'::jsonb
           AND NOT pv_ownership_conflict
           AND current_matches_managed
           AND cooldown_ok
           AND r.vacuum_pid IS NULL
           AND change_count < p.max_changes_per_cycle THEN
            action_name := CASE WHEN p.dry_run THEN 'propose_restore' ELSE 'restore_reloptions' END;
            IF NOT p.dry_run THEN
                apply_kind := 'restore';
                apply_desired := '{}'::jsonb;
            END IF;
        END IF;

        /* Reconcile: restore released keys to their original value, set the desired ones, in one ALTER. */
        IF apply_kind IS NOT NULL THEN
            BEGIN
                rec_reset_names := ARRAY[]::text[];
                rec_set_parts := ARRAY[]::text[];
                PERFORM set_config('lock_timeout', p.lock_timeout_ms::text || 'ms', true);
                FOR rec_option_name IN
                    SELECT key
                    FROM (SELECT jsonb_object_keys(pv_managed_values) AS key
                          UNION
                          SELECT jsonb_object_keys(apply_desired) AS key) keys
                    ORDER BY key
                LOOP
                    IF rec_option_name NOT IN (
                        'autovacuum_vacuum_threshold',
                        'autovacuum_vacuum_scale_factor',
                        'autovacuum_vacuum_max_threshold',
                        'autovacuum_vacuum_insert_threshold',
                        'autovacuum_vacuum_insert_scale_factor',
                        'autovacuum_vacuum_cost_limit',
                        'autovacuum_vacuum_cost_delay') THEN
                        RAISE EXCEPTION 'unsupported managed reloption: %', rec_option_name;
                    END IF;
                    IF apply_desired ? rec_option_name THEN
                        rec_option_value := apply_desired ->> rec_option_name;
                        IF rec_option_value !~ '^-?[0-9]+([.][0-9]+)?$' THEN
                            RAISE EXCEPTION 'invalid numeric reloption value for %: %', rec_option_name, rec_option_value;
                        END IF;
                        rec_set_parts := array_append(rec_set_parts, format('%I = %s', rec_option_name, rec_option_value));
                    ELSE
                        SELECT split_part(o, '=', 2) INTO rec_original_value
                        FROM unnest(pv_original_reloptions) AS o
                        WHERE split_part(o, '=', 1) = rec_option_name
                        LIMIT 1;
                        IF rec_original_value IS NULL THEN
                            rec_reset_names := array_append(rec_reset_names, rec_option_name);
                        ELSE
                            rec_set_parts := array_append(rec_set_parts, format('%I = %s', rec_option_name, rec_original_value));
                        END IF;
                    END IF;
                END LOOP;
                IF cardinality(rec_reset_names) > 0 THEN
                    EXECUTE format('ALTER TABLE %s RESET (%s)', r.fqname,
                                   (SELECT string_agg(format('%I', v), ', ') FROM unnest(rec_reset_names) AS v));
                END IF;
                IF cardinality(rec_set_parts) > 0 THEN
                    EXECUTE format('ALTER TABLE %s SET (%s)', r.fqname, array_to_string(rec_set_parts, ', '));
                END IF;
                applied := true;
                change_count := change_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
            END;
        END IF;

        IF should_apply THEN
            /* Transition log: attempted changes always, repeated dry-run proposals once per (state, action). */
            IF applied
               OR action_error IS NOT NULL
               OR pv_state IS DISTINCT FROM relation_state
               OR pv_last_action IS DISTINCT FROM action_name THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                    'action', action_name, 'reason', reason, 'host_metrics', host_json,
                    'relation_metrics', relation_json, 'proposed_reloptions', desired_values,
                    'applied', applied, 'error', action_error);
            END IF;
            IF applied THEN
                IF NOT pv_original_captured THEN
                    pv_original_reloptions := r.reloptions;
                    pv_original_captured := true;
                END IF;
                pv_managed_values := desired_values;
            END IF;
        ELSIF apply_kind = 'restore' OR action_name IN ('propose_restore') THEN
            /* Same transition rule: real restores always, repeated dry-run proposals once. */
            IF applied
               OR action_error IS NOT NULL
               OR pv_state IS DISTINCT FROM relation_state
               OR pv_last_action IS DISTINCT FROM action_name THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                    'action', action_name,
                    'reason', 'Relation remained healthy for the configured restore window.',
                    'host_metrics', host_json, 'relation_metrics', relation_json,
                    'proposed_reloptions', pv_managed_values, 'applied', applied, 'error', action_error);
            END IF;
            IF applied THEN
                pv_original_reloptions := NULL;
                pv_original_captured := false;
                pv_managed_values := '{}'::jsonb;
            END IF;
        ELSIF relation_state <> 'normal' OR pv_ownership_conflict THEN
            action_name := CASE
                WHEN pv_ownership_conflict THEN 'ownership_conflict'
                WHEN relation_state = 'horizon_blocked' THEN 'horizon_blocked'
                WHEN relation_state LIKE 'backlog_%' AND NOT r.normal_autovacuum_enabled THEN 'autovacuum_disabled'
                WHEN r.vacuum_pid IS NOT NULL THEN 'vacuum_already_running'
                WHEN NOT cooldown_ok THEN 'cooldown'
                ELSE 'observe'
            END;

            /* Observation-only: logged on entering this (state, action) pair. */
            IF pv_state IS DISTINCT FROM relation_state
               OR pv_last_action IS DISTINCT FROM action_name THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                    'action', action_name, 'reason', reason, 'host_metrics', host_json,
                    'relation_metrics', relation_json, 'proposed_reloptions', desired_values,
                    'applied', false,
                    'error', CASE WHEN pv_ownership_conflict
                                  THEN 'A managed reloption changed outside the controller; automatic writes are suspended.'
                                  ELSE NULL END);
            END IF;
        ELSIF pv_state <> 'normal' THEN
            /* Return to normal closes the episode. */
            action_name := 'recovered';
            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                'action', action_name,
                'reason', format('Relation returned to normal (was %s).', pv_state),
                'host_metrics', host_json, 'relation_metrics', relation_json,
                'proposed_reloptions', NULL, 'applied', false, 'error', NULL);
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

        new_last_change_at := CASE WHEN applied THEN clock_timestamp()
                                   ELSE pv_last_change_at END;

        /* Persist only what a later cycle needs; rewrite on control change or hourly heartbeat. */
        state_needed := relation_state <> 'normal'
                        OR pv_managed_values <> '{}'::jsonb
                        OR pv_ownership_conflict
                        OR pv_original_captured
                        OR r.vacuum_pid IS NOT NULL
                        OR action_error IS NOT NULL
                        OR (new_last_change_at IS NOT NULL
                            AND clock_timestamp() - new_last_change_at
                                < make_interval(secs => p.change_cooldown_seconds));

        IF NOT state_needed THEN
            IF r.state_exists THEN
                out_state_delete := out_state_delete || to_jsonb(r.relid);
            END IF;
        ELSIF NOT r.state_exists
              OR r.prev_relation_name IS DISTINCT FROM r.fqname
              OR r.prev_original_reloptions IS DISTINCT FROM pv_original_reloptions
              OR r.prev_original_captured IS DISTINCT FROM pv_original_captured
              OR r.prev_managed_values IS DISTINCT FROM pv_managed_values
              OR r.prev_ownership_conflict IS DISTINCT FROM pv_ownership_conflict
              OR r.prev_state IS DISTINCT FROM relation_state
              OR r.prev_consecutive_overdue IS DISTINCT FROM overdue_cycles
              OR r.prev_consecutive_healthy IS DISTINCT FROM healthy_cycles
              OR r.prev_last_change_at IS DISTINCT FROM new_last_change_at
              OR r.prev_last_vacuum_pid IS DISTINCT FROM r.vacuum_pid
              OR r.prev_last_vacuum_progress IS DISTINCT FROM cur_vacuum_progress
              OR r.prev_vacuum_stalled_cycles IS DISTINCT FROM vacuum_stalled_cycles
              OR r.prev_last_error IS DISTINCT FROM action_error
              OR r.prev_last_action IS DISTINCT FROM action_name
              OR r.prev_last_seen_at < clock_timestamp() - interval '1 hour'
        THEN
            out_state := out_state || jsonb_build_object(
                'relation_oid', r.relid, 'relation_name', r.fqname,
                'original_reloptions', pv_original_reloptions,
                'original_captured', pv_original_captured,
                'managed_values', pv_managed_values,
                'ownership_conflict', pv_ownership_conflict,
                'state', relation_state,
                'consecutive_overdue', overdue_cycles,
                'consecutive_healthy', healthy_cycles,
                'last_change_at', new_last_change_at,
                'last_dead_tuples', r.dead_tuples, 'last_live_tuples', r.live_tuples,
                'last_trigger', vacuum_trigger, 'last_backlog_ratio', backlog_ratio,
                'last_inserts_since_vacuum', r.inserts_since_vacuum,
                'last_insert_backlog_ratio', insert_ratio,
                'last_xid_age', r.xid_age, 'last_mxid_age', r.mxid_age,
                'last_vacuum_pid', r.vacuum_pid, 'last_vacuum_progress', cur_vacuum_progress,
                'vacuum_stalled_cycles', vacuum_stalled_cycles,
                'last_error', action_error, 'last_action', action_name);
        END IF;
    END LOOP;

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
            'changes_applied', change_count,
            'analyzed', analyze_count,
            'scan_seconds', extract(epoch FROM clock_timestamp() - scan_started_at)),
        'table_state', out_state,
        'table_state_delete', out_state_delete,
        'decisions', out_decisions,
        'emergency_requests', out_emergency)::text, false);
END
$aav_body$;

COMMENT ON FUNCTION adaptive_autovacuum._database_program() IS
'Body of the anonymous PL/pgSQL block the database worker runs inside each managed database. It reads adaptive_autovacuum.worker_input (policy, previous table state, gates) and leaves its result in adaptive_autovacuum.worker_output; it uses no extension objects, so managed databases need no CREATE EXTENSION.';
