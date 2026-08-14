\pset format unaligned
\pset tuples_only on
SET client_min_messages = warning;

CREATE EXTENSION adaptive_autovacuum;

SELECT enabled = false AS disabled_by_default,
       dry_run = true AS dry_run_by_default,
       manage_table_costs = false AS cost_changes_opt_in,
       emergency_vacuum_enabled = true AS emergency_on_by_default,
       manage_global_settings = true AS globals_managed_by_default,
       analyze_missing_stats = true AS analyze_missing_stats_by_default,
       analyze_missing_stats_per_cycle = 3 AS analyze_missing_stats_top3
FROM adaptive_autovacuum.policy;

SELECT recommendation_delay_min_ms = 0.5 AS delay_floor_default,
       recommendation_buffer_usage_limit_max_mb = 256 AS buffer_ring_cap_default,
       high_wal_mbps = 0 AS wal_guardrail_off_by_default
FROM adaptive_autovacuum.policy;

-- Absurd policy values (outside the documented bounds of the settings they
-- feed) are rejected by CHECK constraints.  Terse verbosity: the DETAIL line
-- would print the whole failing row, which contains timestamps.
\set VERBOSITY terse
UPDATE adaptive_autovacuum.policy SET recommendation_cost_limit_max = 50000;
UPDATE adaptive_autovacuum.policy SET recommendation_delay_max_ms = 500;
UPDATE adaptive_autovacuum.policy SET recommendation_delay_min_ms = 50;
UPDATE adaptive_autovacuum.policy SET critical_cost_limit = 60000;
UPDATE adaptive_autovacuum.policy SET elevated_cost_delay_ms = 1000;
UPDATE adaptive_autovacuum.policy SET emergency_cost_delay_ms = 101;
UPDATE adaptive_autovacuum.policy SET max_scale_factor = 500;
UPDATE adaptive_autovacuum.policy SET recommendation_buffer_usage_limit_max_mb = 99999;
\set VERBOSITY default

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

-- table_policy identity fingerprint: filled by trigger, refreshed when the
-- operator touches the row, and rows for dropped relations are cleaned up.
CREATE TABLE aav_policy_target(id integer);
INSERT INTO adaptive_autovacuum.table_policy(relid) VALUES ('aav_policy_target'::regclass);

SELECT schema_name = 'public' AND relation_name = 'aav_policy_target'
       AS table_policy_identity_filled
FROM adaptive_autovacuum.table_policy
WHERE relid = 'aav_policy_target'::regclass;

ALTER TABLE aav_policy_target RENAME TO aav_policy_renamed;

UPDATE adaptive_autovacuum.table_policy
SET enabled = enabled
WHERE relid = 'aav_policy_renamed'::regclass;

SELECT relation_name = 'aav_policy_renamed' AS table_policy_readopted
FROM adaptive_autovacuum.table_policy
WHERE relid = 'aav_policy_renamed'::regclass;

DROP TABLE aav_policy_renamed;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 0 AS table_policy_dropped_relation_cleaned
FROM adaptive_autovacuum.table_policy;

CREATE TABLE aav_no_stats(id integer, payload text);
INSERT INTO aav_no_stats SELECT g, g::text FROM generate_series(1, 1000) g;
SELECT pg_stat_force_next_flush();

SELECT pg_stat_get_live_tuples('aav_no_stats'::regclass) > 0
       AND pg_stat_get_last_analyze_time('aav_no_stats'::regclass) IS NULL
       AND pg_stat_get_last_autoanalyze_time('aav_no_stats'::regclass) IS NULL
       AS never_analyzed_candidate_visible;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 1 AS analyze_proposed_in_dry_run
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_no_stats'::regclass
  AND action = 'propose_analyze'
  AND NOT applied;

UPDATE adaptive_autovacuum.policy
SET dry_run = false,
    manage_global_settings = false;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT reltuples::integer = 1000 AS analyze_updated_reltuples
FROM pg_class WHERE oid = 'aav_no_stats'::regclass;

SELECT count(*) = 1 AS analyze_executed
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_no_stats'::regclass
  AND action = 'analyze'
  AND applied
  AND error IS NULL;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 1 AS analyzed_table_not_repeated
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_no_stats'::regclass
  AND action = 'analyze';

DROP TABLE aav_no_stats;
DROP TABLE aav_test;
DROP EXTENSION adaptive_autovacuum;
