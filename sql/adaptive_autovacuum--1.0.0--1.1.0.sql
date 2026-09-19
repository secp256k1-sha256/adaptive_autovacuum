\echo Use "ALTER EXTENSION adaptive_autovacuum UPDATE TO '1.1.0'" to load this file. \quit

/* 1.1.0: stable operator and installer API. No table changes; operator values are preserved. */

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
'Installer/operator API: puts the policy into the active mode (enabled, applying, managing cluster settings). Safe to call repeatedly; returns the previous and new value of each switch. Other policy columns are never touched.';

/* One-row machine-readable state of the installation in this database; every column is nullable. */
CREATE FUNCTION adaptive_autovacuum.status()
RETURNS TABLE (
    extension_version         text,
    available_version         text,
    server_version            text,
    library_preloaded         boolean,
    preload_pending_restart   boolean,
    launcher_enabled          boolean,
    launcher_running          boolean,
    in_recovery               boolean,
    policy_enabled            boolean,
    policy_dry_run            boolean,
    manage_global_settings    boolean,
    last_cycle_at             timestamptz,
    seconds_since_last_cycle  double precision,
    naptime_seconds           integer,
    tracked_databases         integer,
    tracked_databases_capacity integer,
    evidence_complete         boolean,
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
    ext_installed boolean;
BEGIN
    SELECT * INTO css FROM adaptive_autovacuum.cluster_summary_status();

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

    ext_installed := EXISTS (SELECT 1 FROM pg_extension e WHERE e.extname = 'adaptive_autovacuum');

    RETURN QUERY
    SELECT
        (SELECT e.extversion FROM pg_extension e WHERE e.extname = 'adaptive_autovacuum'),
        (SELECT a.default_version FROM pg_available_extensions a WHERE a.name = 'adaptive_autovacuum'),
        current_setting('server_version'),
        css.available,
        /* The file says one thing and the running postmaster another: a restart is pending. */
        (file_lists IS DISTINCT FROM current_lists),
        nullif(current_setting('adaptive_autovacuum.enabled', true), '')::boolean,
        EXISTS (SELECT 1 FROM pg_stat_activity a
                WHERE a.backend_type = 'adaptive autovacuum launcher'),
        pg_is_in_recovery(),
        (SELECT p.enabled FROM adaptive_autovacuum.policy p WHERE p.singleton),
        (SELECT p.dry_run FROM adaptive_autovacuum.policy p WHERE p.singleton),
        (SELECT p.manage_global_settings FROM adaptive_autovacuum.policy p WHERE p.singleton),
        (SELECT c.last_sample_at FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT extract(epoch FROM clock_timestamp() - c.last_sample_at)::double precision
         FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT g.setting::integer FROM pg_settings g WHERE g.name = 'adaptive_autovacuum.naptime_seconds'),
        css.used,
        css.capacity,
        CASE WHEN css.available THEN NOT css.overflow END,
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
'Installer/operator API: one row describing the library, launcher, policy, heartbeat and backlog state of this database. Readable by pg_monitor.';

/* Health checks with a fixed vocabulary: OK, WARN, FAIL, RESTART_REQUIRED. */
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
            'CREATE EXTENSION adaptive_autovacuum;';
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

    /* 4. launcher_enabled */
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

    /* 5. launcher_running */
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
            'Check the server log for "adaptive autovacuum launcher" errors; verify max_worker_processes leaves room for one launcher plus max_database_workers, and that adaptive_autovacuum.control_database exists and accepts connections.';
    END IF;

    /* 6. policy */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'policy', 'FAIL', 'no policy: the extension is not created here',
            'CREATE EXTENSION adaptive_autovacuum;';
    ELSIF coalesce(s.policy_enabled, false) AND NOT coalesce(s.policy_dry_run, true) THEN
        RETURN QUERY SELECT 'policy', 'OK',
            'active (enabled, applying changes'
                || CASE WHEN s.manage_global_settings THEN ', managing cluster settings)' ELSE ', per-table only)' END,
            NULL::text;
    ELSIF coalesce(s.policy_enabled, false) THEN
        RETURN QUERY SELECT 'policy', 'WARN',
            'watch-only: dry_run = true, decisions are logged but nothing is changed',
            'UPDATE adaptive_autovacuum.policy SET dry_run = false; or SELECT adaptive_autovacuum.enable_default_policy();';
    ELSE
        RETURN QUERY SELECT 'policy', 'WARN',
            'paused: policy.enabled = false for database ' || current_database(),
            'SELECT adaptive_autovacuum.enable_default_policy();';
    END IF;

    /* 7. last_cycle */
    stale_after := greatest(3 * coalesce(s.naptime_seconds, 60), 600);
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'last_cycle', 'FAIL', 'no controller state: the extension is not created here',
            'CREATE EXTENSION adaptive_autovacuum;';
    ELSIF s.last_cycle_at IS NULL THEN
        IF s.launcher_running AND coalesce(s.launcher_enabled, false) AND coalesce(s.policy_enabled, false) THEN
            RETURN QUERY SELECT 'last_cycle', 'WARN',
                'no cycle recorded yet; the first one runs within adaptive_autovacuum.naptime_seconds ('
                    || coalesce(s.naptime_seconds::text, '60') || ' s) of the launcher start',
                'Re-run the check in a minute.';
        ELSE
            RETURN QUERY SELECT 'last_cycle', 'WARN',
                'no cycle has run in this database yet',
                'Resolve launcher_running, launcher_enabled and policy first.';
        END IF;
    ELSIF s.seconds_since_last_cycle > stale_after THEN
        RETURN QUERY SELECT 'last_cycle', 'WARN',
            'last cycle ' || round(s.seconds_since_last_cycle)::text || ' s ago (stale after ' || stale_after || ' s)',
            'Check the server log; a database worker may be blocked (adaptive_autovacuum.database_worker_timeout_seconds) or the launcher was turned off.';
    ELSE
        RETURN QUERY SELECT 'last_cycle', 'OK',
            'last cycle ' || round(s.seconds_since_last_cycle)::text || ' s ago', NULL::text;
    END IF;

    /* 8. cluster_evidence */
    IF NOT s.library_preloaded THEN
        RETURN QUERY SELECT 'cluster_evidence', 'WARN',
            'shared-memory summaries are unavailable without preload', 'Resolve library_preloaded first.';
    ELSIF coalesce(s.evidence_complete, true) THEN
        RETURN QUERY SELECT 'cluster_evidence', 'OK',
            s.tracked_databases::text || ' of ' || s.tracked_databases_capacity::text || ' summary slots in use',
            NULL::text;
    ELSE
        RETURN QUERY SELECT 'cluster_evidence', 'WARN',
            'more managed databases than adaptive_autovacuum.max_tracked_databases (' || s.tracked_databases_capacity::text
                || '); cluster-wide changes are recorded but not applied',
            'ALTER SYSTEM SET adaptive_autovacuum.max_tracked_databases = <databases>; then restart PostgreSQL.';
    END IF;

    /* 9. global_changes */
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

    /* 10. relation_errors */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'relation_errors', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.relation_errors_24h, 0) > 0 THEN
        RETURN QUERY SELECT 'relation_errors', 'WARN',
            s.relation_errors_24h::text || ' per-table action(s) failed in the last 24 h',
            'SELECT decided_at, relation_name, action, error FROM adaptive_autovacuum.decisions WHERE error IS NOT NULL ORDER BY decided_at DESC;';
    ELSE
        RETURN QUERY SELECT 'relation_errors', 'OK', 'no failed per-table actions in the last 24 h', NULL::text;
    END IF;

    /* 11. emergency_vacuum */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'emergency_vacuum', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.active_emergencies, 0) > 0 THEN
        RETURN QUERY SELECT 'emergency_vacuum', 'WARN',
            s.active_emergencies::text || ' emergency VACUUM request(s) pending or running',
            'SELECT * FROM adaptive_autovacuum.emergency_queue WHERE status IN (''pending'', ''running'');';
    ELSE
        RETURN QUERY SELECT 'emergency_vacuum', 'OK', 'no emergency VACUUM pending or running', NULL::text;
    END IF;

    /* 12. wraparound */
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

    /* 13. autovacuum */
    autovacuum_on := current_setting('autovacuum')::boolean;
    IF autovacuum_on THEN
        RETURN QUERY SELECT 'autovacuum', 'OK', 'autovacuum = on', NULL::text;
    ELSE
        RETURN QUERY SELECT 'autovacuum', 'WARN',
            'autovacuum = off; the controller turns it back on after repair_disabled_autovacuum_cycles consecutive checks',
            'ALTER SYSTEM SET autovacuum = on; SELECT pg_reload_conf();';
    END IF;

    /* 14. track_cost_delay_timing (PG18+) */
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

    /* 15. recovery */
    IF s.in_recovery THEN
        RETURN QUERY SELECT 'recovery', 'WARN',
            'this server is a standby; the controller stays idle until promotion', NULL::text;
    ELSE
        RETURN QUERY SELECT 'recovery', 'OK', 'primary server', NULL::text;
    END IF;
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum.doctor() IS
'Installer/operator API: one row per health check with status OK, WARN, FAIL or RESTART_REQUIRED, a detail line and a remediation command. Readable by pg_monitor.';

REVOKE ALL ON FUNCTION adaptive_autovacuum._preload_lists_library(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum._version_key(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum.enable_default_policy() FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum.status() FROM PUBLIC;
REVOKE ALL ON FUNCTION adaptive_autovacuum.doctor() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum._preload_lists_library(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum._version_key(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.status() TO pg_monitor;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.doctor() TO pg_monitor;
