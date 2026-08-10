\pset format unaligned
\pset tuples_only on
SET client_min_messages = warning;

CREATE EXTENSION adaptive_autovacuum;

SELECT enabled = false AS disabled_by_default,
       dry_run = true AS dry_run_by_default,
       manage_table_costs = false AS cost_changes_opt_in,
       emergency_vacuum_enabled = false AS emergency_opt_in,
       manage_global_settings = true AS globals_managed_by_default
FROM adaptive_autovacuum.policy;

SELECT jsonb_typeof(adaptive_autovacuum.host_metrics()) = 'object' AS host_metrics_object;
SELECT adaptive_autovacuum.host_metrics() ?&
       ARRAY['load1', 'cpu_count', 'mem_total_bytes', 'mem_available_bytes']
       AS host_metrics_keys;

CREATE TABLE aav_test(id integer)
WITH (autovacuum_vacuum_threshold = 123);

SELECT adaptive_autovacuum._managed_values_match(
           ARRAY['autovacuum_vacuum_threshold=123'],
           '{"autovacuum_vacuum_threshold":"123.0"}'::jsonb)
       AS numeric_reloptions_compare;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._reconcile_relation_options(
        'public.aav_test',
        ARRAY['autovacuum_vacuum_threshold=123'],
        '{}'::jsonb,
        '{"autovacuum_vacuum_threshold":"50", "autovacuum_vacuum_scale_factor":"0.01"}'::jsonb,
        1000
    );
END
$$;

SELECT adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_threshold')::integer = 50
       AND adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_scale_factor')::numeric = 0.01
       AS reloptions_applied
FROM pg_class WHERE oid = 'aav_test'::regclass;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._reconcile_relation_options(
        'public.aav_test',
        ARRAY['autovacuum_vacuum_threshold=123'],
        '{"autovacuum_vacuum_threshold":"50", "autovacuum_vacuum_scale_factor":"0.01"}'::jsonb,
        '{}'::jsonb,
        1000
    );
END
$$;

SELECT adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_threshold')::integer = 123
       AND adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_scale_factor') IS NULL
       AS reloptions_restored
FROM pg_class WHERE oid = 'aav_test'::regclass;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._reconcile_relation_options(
        'public.aav_test',
        ARRAY['autovacuum_vacuum_threshold=123'],
        '{}'::jsonb,
        '{"autovacuum_vacuum_insert_threshold":"1000", "autovacuum_vacuum_insert_scale_factor":"0.05"}'::jsonb,
        1000
    );
END
$$;

SELECT adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_insert_threshold')::integer = 1000
       AND adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_insert_scale_factor')::numeric = 0.05
       AS insert_reloptions_applied
FROM pg_class WHERE oid = 'aav_test'::regclass;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._reconcile_relation_options(
        'public.aav_test',
        ARRAY['autovacuum_vacuum_threshold=123'],
        '{"autovacuum_vacuum_insert_threshold":"1000", "autovacuum_vacuum_insert_scale_factor":"0.05"}'::jsonb,
        '{}'::jsonb,
        1000
    );
END
$$;

SELECT adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_insert_threshold') IS NULL
       AND adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_insert_scale_factor') IS NULL
       AND adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_threshold')::integer = 123
       AS insert_reloptions_restored
FROM pg_class WHERE oid = 'aav_test'::regclass;

SELECT count(*) = 0 AS changed_tables_view_empty
FROM adaptive_autovacuum.changed_tables;

SELECT count(*) = 0 AS global_apply_queue_empty
FROM adaptive_autovacuum.global_apply_queue;

SELECT emergency_xid_age = 1000000000
       AND emergency_mxid_age = 1000000000
       AND emergency_stall_multiplier = 1.5
       AND emergency_takeover_min_runtime_seconds = 3600
       AS emergency_trigger_defaults
FROM adaptive_autovacuum.policy;

SELECT count(*) = 1 AND bool_and(last_xid8 IS NULL) AS controller_state_seeded
FROM adaptive_autovacuum.controller_state;

SELECT count(*) >= 1
       AND bool_and(status IN ('ok', 'watch', 'alarm'))
       AND bool_and(xids_until_readonly + xid_age = 2147483648 - 3000000)
       AS wraparound_status_view_sane
FROM adaptive_autovacuum.wraparound_status;

UPDATE adaptive_autovacuum.policy
SET enabled = true,
    dry_run = true,
    min_table_bytes = 9223372036854775807;

INSERT INTO adaptive_autovacuum.emergency_queue
    (relid, relation_name, reason, status, started_at, worker_pid,
     work_mem_mb, cost_limit, cost_delay_ms, lock_timeout_ms)
VALUES
    ('aav_test'::regclass, 'public.aav_test', 'regression stale request',
     'running', clock_timestamp() - interval '1 minute', 2147483647,
     128, 1000, 0, 1000);

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT status = 'failed'
       AND last_error LIKE 'Recovered stale running request:%'
       AS stale_request_recovered
FROM adaptive_autovacuum.emergency_queue
WHERE relation_name = 'public.aav_test';

SELECT count(*) = 1 AS recommendation_recorded
FROM adaptive_autovacuum.global_recommendations;

DROP TABLE aav_test;
DROP EXTENSION adaptive_autovacuum;
