
/* ---------- observability: cluster first, then per database, then per table ---------- */

CREATE VIEW adaptive_autovacuum.database_status AS
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

CREATE VIEW adaptive_autovacuum.table_status AS
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
CREATE VIEW adaptive_autovacuum.table_recommendations AS
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
CREATE VIEW adaptive_autovacuum.wraparound_status AS
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
CREATE VIEW adaptive_autovacuum.aging_tables AS
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
CREATE VIEW adaptive_autovacuum.latest_global_recommendation AS
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

CREATE VIEW adaptive_autovacuum.active_vacuums AS
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
CREATE VIEW adaptive_autovacuum.actions AS
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
CREATE FUNCTION adaptive_autovacuum._preload_lists_library(setting_value text)
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
CREATE FUNCTION adaptive_autovacuum._version_key(version text)
RETURNS integer[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN string_to_array(regexp_replace(coalesce(version, '0'), '[^0-9.].*$', ''), '.')::integer[];

/* Idempotent: make sure the singleton policy row exists and is in the active operating mode. */
CREATE FUNCTION adaptive_autovacuum.enable_default_policy()
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
CREATE FUNCTION adaptive_autovacuum.status()
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
CREATE FUNCTION adaptive_autovacuum.doctor()
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
