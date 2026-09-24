
/* ---------- control plane: functions the controller process calls in the control database ---------- */

/* Sweep bookkeeping: a new generation starts; returns its number. */
CREATE FUNCTION adaptive_autovacuum._begin_generation()
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
CREATE FUNCTION adaptive_autovacuum._discover_databases()
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
CREATE FUNCTION adaptive_autovacuum._worker_input(
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
            'boosted_relations_elsewhere',
                (SELECT count(*) FROM adaptive_autovacuum.table_state ts
                 WHERE ts.database_oid <> dboid
                   AND ts.managed_values ? 'autovacuum_vacuum_cost_limit'
                   AND NOT ts.ownership_conflict),
            'boost_budget_used_elsewhere',
                (SELECT COALESCE(sum((ts.managed_values ->> 'autovacuum_vacuum_cost_limit')::numeric), 0)::integer
                 FROM adaptive_autovacuum.table_state ts
                 WHERE ts.database_oid <> dboid
                   AND ts.managed_values ? 'autovacuum_vacuum_cost_limit'
                   AND NOT ts.ownership_conflict)),
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
CREATE FUNCTION adaptive_autovacuum._record_database_failure(
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
CREATE FUNCTION adaptive_autovacuum._absorb_database_result(
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
         original_reloptions, original_captured, managed_values, ownership_conflict,
         state, consecutive_overdue, consecutive_healthy, last_seen_at, last_change_at,
         last_dead_tuples, last_live_tuples, last_trigger, last_backlog_ratio,
         last_inserts_since_vacuum, last_insert_backlog_ratio, last_xid_age, last_mxid_age,
         last_vacuum_pid, last_vacuum_progress, vacuum_stalled_cycles, last_error, last_action)
    SELECT dboid, x.relation_oid, dbname, x.relation_name,
           x.original_reloptions, COALESCE(x.original_captured, false),
           COALESCE(x.managed_values, '{}'::jsonb), COALESCE(x.ownership_conflict, false),
           COALESCE(x.state, 'normal'), COALESCE(x.consecutive_overdue, 0),
           COALESCE(x.consecutive_healthy, 0), clock_timestamp(), x.last_change_at,
           x.last_dead_tuples, x.last_live_tuples, x.last_trigger, x.last_backlog_ratio,
           x.last_inserts_since_vacuum, x.last_insert_backlog_ratio, x.last_xid_age, x.last_mxid_age,
           x.last_vacuum_pid, x.last_vacuum_progress, COALESCE(x.vacuum_stalled_cycles, 0),
           x.last_error, x.last_action
    FROM jsonb_to_recordset(COALESCE(doc -> 'table_state', '[]'::jsonb)) AS x(
        relation_oid oid, relation_name text, original_reloptions text[], original_captured boolean,
        managed_values jsonb, ownership_conflict boolean, state text, consecutive_overdue integer,
        consecutive_healthy integer, last_change_at timestamptz, last_dead_tuples bigint,
        last_live_tuples bigint, last_trigger double precision, last_backlog_ratio double precision,
        last_inserts_since_vacuum bigint, last_insert_backlog_ratio double precision,
        last_xid_age bigint, last_mxid_age bigint, last_vacuum_pid integer,
        last_vacuum_progress text, vacuum_stalled_cycles integer, last_error text, last_action text)
    ON CONFLICT (database_oid, relation_oid) DO UPDATE
    SET database_name = EXCLUDED.database_name,
        relation_name = EXCLUDED.relation_name,
        original_reloptions = EXCLUDED.original_reloptions,
        original_captured = EXCLUDED.original_captured,
        managed_values = EXCLUDED.managed_values,
        ownership_conflict = EXCLUDED.ownership_conflict,
        state = EXCLUDED.state,
        consecutive_overdue = EXCLUDED.consecutive_overdue,
        consecutive_healthy = EXCLUDED.consecutive_healthy,
        last_seen_at = EXCLUDED.last_seen_at,
        last_change_at = EXCLUDED.last_change_at,
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
        last_error = EXCLUDED.last_error,
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
         debt_velocity, max_xid_age, max_mxid_age, changes_applied, analyzed_relations)
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
         (s ->> 'changes_applied')::integer, (s ->> 'analyzed')::integer)
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
        changes_applied = EXCLUDED.changes_applied,
        analyzed_relations = EXCLUDED.analyzed_relations;

    RETURN QUERY
    SELECT true, (s ->> 'eligible')::integer, n_overdue, n_emergency,
           COALESCE((doc ->> 'extension_installed')::boolean, false),
           EXISTS (SELECT 1 FROM adaptive_autovacuum.emergency_queue q
                   WHERE q.status = 'pending' AND q.next_retry_at <= clock_timestamp());
END
$$;

/* Recover requests whose worker is gone (controller restart, crash); PID-reuse guarded. */
CREATE FUNCTION adaptive_autovacuum._recover_stale_emergencies()
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
CREATE FUNCTION adaptive_autovacuum._claim_emergency_request()
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

CREATE FUNCTION adaptive_autovacuum._set_emergency_worker_pid(request_id bigint, pid integer)
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
CREATE FUNCTION adaptive_autovacuum._finish_emergency_request(
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
CREATE FUNCTION adaptive_autovacuum._global_controller(
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
    worker_mem_cap integer;

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
           cs.last_sweep_started_at, cs.observed_sweep_seconds
    INTO prev_xid8, prev_sample_at, prev_wal_bytes,
         free_cycles, av_off_cycles, baseline_json,
         prev_activity_units, raise_at, raise_limit,
         raise_delay, rate_before_raise,
         sweep_started_at, prev_sweep_seconds
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
            activity_detail := jsonb_build_object(
                'hits_per_sec', io_hits / sample_interval,
                'reads_per_sec', io_reads / sample_interval,
                'writes_per_sec', io_writes / sample_interval,
                'extends_per_sec', io_extends / sample_interval,
                'unit', 'cumulative counters divided by the sample interval; see cost weights',
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
    baseline_cost_limit := (baseline_json ->> 'autovacuum_vacuum_cost_limit')::integer;
    baseline_cost_delay := (baseline_json ->> 'autovacuum_vacuum_cost_delay')::double precision;

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
               OR current_global_cost_delay <> baseline_cost_delay) THEN
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
        free_cycles := 0;
        recommendation_reason := format(
            'No overdue relations for %s consecutive checks: stepping the cost settings back'
            || ' toward the pre-incident baseline (cost_limit %s, cost_delay %s ms).',
            p.recovery_cycles_before_decay, baseline_cost_limit,
            trim(trailing '.' from to_char(baseline_cost_delay, 'FM999990.99')));
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

    /* Workers: busy pool or a queue far longer than the pool, with non-shrinking debt. */
    workers_saturated := av_workers_running >= current_autovacuum_workers;
    /* One pg_stat_activity sample misses saturation; a long overdue queue is the same evidence. */
    worker_queue_pressure := cl_overdue >= GREATEST(current_autovacuum_workers * 2,
                                                    current_autovacuum_workers + 2);
    IF NOT autovacuum_enabled_global
       OR cl_overdue = 0
       OR (NOT workers_saturated AND NOT worker_queue_pressure)
       OR backlog_under_control
       OR (cur_host_pressure AND NOT critical_seen) THEN
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
         recommended_autovacuum_workers,
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
         recommended_workers,
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
    IF p.manage_global_settings AND NOT p.dry_run
       AND NOT autovacuum_enabled_global
       AND p.repair_disabled_autovacuum
       AND av_off_cycles >= p.repair_disabled_autovacuum_cycles
       AND NOT EXISTS (SELECT 1
                       FROM adaptive_autovacuum.global_apply_queue q
                       WHERE q.guc_name = 'autovacuum'
                         AND q.status = 'pending') THEN
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
'The single cluster-level decision step, run by the controller process once per completed sweep: aggregates database_state for the generation, samples cluster counters (next XID read without assigning one, WAL, cost-weighted autovacuum activity), records one recommendation and queues the allow-listed ALTER SYSTEM changes. extra_summary is a diagnostic hook that folds a pre-aggregated summary in as additional databases.';

/* Run the database program in the current database the way a worker would, and absorb the result. */
CREATE FUNCTION adaptive_autovacuum._scan_this_database(
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
CREATE FUNCTION adaptive_autovacuum._run_cycle(
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
