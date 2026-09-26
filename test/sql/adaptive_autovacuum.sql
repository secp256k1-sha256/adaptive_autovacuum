\pset format unaligned
\pset tuples_only on
SET client_min_messages = warning;

CREATE EXTENSION adaptive_autovacuum;

SELECT enabled = true AS active_by_default,
       dry_run = false AS applies_by_default,
       recommend_table_costs = true AS cost_recommendations_on_by_default,
       min_table_bytes = 0 AS every_table_eligible_by_default,
       target_dead_tuple_min = 1000 AS dead_tuple_floor_default,
       overdue_cycles_before_recommend = 2 AS recommend_after_two_checks,
       healthy_cycles_before_revert = 6 AS revert_after_six_healthy_checks,
       emergency_vacuum_enabled = true AS emergency_on_by_default,
       manage_global_settings = true AS globals_managed_by_default,
       analyze_missing_stats = true AS analyze_missing_stats_by_default,
       analyze_missing_stats_budget_ms = 10000 AS analyze_budget_default,
       repair_disabled_autovacuum = true AS autovacuum_repair_on_by_default,
       repair_disabled_autovacuum_cycles = 1 AS autovacuum_repair_on_first_check,
       recommendation_workers_max = 16 AS workers_max_default,
       manage_naptime = true AS naptime_managed_by_default,
       naptime_min_seconds = 5 AS naptime_floor_default,
       recovery_cycles_before_decay = 10 AS decay_after_ten_clean_checks
FROM adaptive_autovacuum.policy;

SELECT recommendation_delay_min_ms = 0.5 AS delay_floor_default,
       recommendation_buffer_usage_limit_max_mb = 256 AS buffer_ring_cap_default,
       high_wal_mbps = 0 AS wal_guardrail_off_by_default,
       recommendation_max_vacuum_mbps = 3200 AS throughput_cap_default,
       cost_raise_min_activity_gain_percent = 10 AS activity_gain_default,
       max_backlog_drain_seconds = 180 AS drain_target_default,
       included_databases IS NULL AS all_databases_included_by_default,
       excluded_databases = ARRAY[]::text[] AS no_databases_excluded_by_default
FROM adaptive_autovacuum.policy;

SELECT adaptive_autovacuum.vacuum_cost_ceiling_mbps(200, 2) = 781.25 AS pg_default_ceiling_is_781_mib_s,
       adaptive_autovacuum.vacuum_cost_ceiling_mbps(200, 0) = 'infinity' AS zero_delay_is_unbounded;

-- Out-of-bounds policy values are rejected by CHECK constraints (terse: DETAIL has timestamps).
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

-- SQL text for the operator: SET for values, RESET for null values, allow-listed keys only, sorted.
SELECT adaptive_autovacuum._reloptions_sql('public.aav_test',
           '{"autovacuum_vacuum_threshold":"50", "autovacuum_vacuum_scale_factor":"0.01"}'::jsonb)
       = 'ALTER TABLE public.aav_test SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50);'
       AS reloptions_sql_set;

SELECT adaptive_autovacuum._reloptions_sql('public.aav_test',
           '{"autovacuum_vacuum_threshold":"123", "autovacuum_vacuum_scale_factor":null}'::jsonb)
       = 'ALTER TABLE public.aav_test SET (autovacuum_vacuum_threshold = 123); ALTER TABLE public.aav_test RESET (autovacuum_vacuum_scale_factor);'
       AS reloptions_sql_set_and_reset;

SELECT adaptive_autovacuum._reloptions_sql('public.aav_test',
           '{"fillfactor":"50", "autovacuum_vacuum_threshold":"1; DROP TABLE x"}'::jsonb) IS NULL
       AS reloptions_sql_rejects_unknown_keys_and_values;

-- The database program never writes table settings; ANALYZE is its only DDL.
SELECT position('ALTER TABLE' IN adaptive_autovacuum._database_program()) = 0 AS program_never_alters_tables;

SELECT count(*) = 0 AS table_recommendations_view_empty
FROM adaptive_autovacuum.table_recommendations;

SELECT count(*) = 0 AS global_apply_queue_empty
FROM adaptive_autovacuum.global_apply_queue;

-- Controller status works with and without preload (controller_state names the situation).
SELECT available IS NOT NULL AND controller_state IS NOT NULL
       AND (available OR controller_state = 'not preloaded')
       AS controller_status_sane
FROM adaptive_autovacuum.controller_status();

-- Size estimate: relpages when known; exact size only for unanalyzed relations with enough tuples.
SELECT adaptive_autovacuum._relation_bytes(10, 0, 0, 67108864, 8192, 'aav_test'::regclass) = 81920
       AND adaptive_autovacuum._relation_bytes(0, 100, 0, 67108864, 8192, 'aav_test'::regclass) = 0
       AND adaptive_autovacuum._relation_bytes(0, 9000, 0, 67108864, 8192, 'aav_test'::regclass)
           = pg_total_relation_size('aav_test'::regclass)
       AS relation_bytes_estimate;

SELECT emergency_xid_age = 1000000000
       AND emergency_mxid_age = 1000000000
       AND emergency_stall_multiplier = 1.5
       AND emergency_takeover_min_runtime_seconds = 3600
       AND emergency_takeover_stall_samples = 5
       AS emergency_trigger_defaults
FROM adaptive_autovacuum.policy;

SELECT count(*) = 1 AND bool_and(last_xid8 IS NULL) AND bool_and(cluster_generation = 0)
       AND bool_and(last_debt_tuples IS NULL AND backlog_free_cycles = 0
                    AND autovacuum_off_cycles = 0 AND baseline_settings = '{}'::jsonb)
       AS controller_state_seeded
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
    (database_oid, database_name, relid, relation_name, reason, status, started_at, worker_pid,
     work_mem_mb, cost_limit, cost_delay_ms, lock_timeout_ms)
VALUES
    ((SELECT oid FROM pg_database WHERE datname = current_database()), current_database(),
     'aav_test'::regclass, 'public.aav_test', 'regression stale request',
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

-- table_policy is keyed by database, schema and relation name and applied by the database program.
CREATE TABLE aav_policy_target(id integer, payload text);
INSERT INTO aav_policy_target SELECT g, g::text FROM generate_series(1, 5000) g;
SELECT pg_stat_force_next_flush();
VACUUM ANALYZE aav_policy_target;
UPDATE adaptive_autovacuum.policy SET min_table_bytes = 0;

SELECT o_eligible >= 1 AS policy_target_eligible_without_override
FROM adaptive_autovacuum._run_cycle(0, 1, 0, 0);

INSERT INTO adaptive_autovacuum.table_policy(database_name, schema_name, relation_name, enabled)
VALUES (current_database(), 'public', 'aav_policy_target', false);
SELECT o_eligible AS aav_eligible_excluded FROM adaptive_autovacuum._run_cycle(0, 1, 0, 0) \gset

ALTER TABLE aav_policy_target RENAME TO aav_policy_renamed;
SELECT o_eligible = :aav_eligible_excluded + 1 AS renamed_relation_no_longer_matches_policy
FROM adaptive_autovacuum._run_cycle(0, 1, 0, 0);

UPDATE adaptive_autovacuum.table_policy SET relation_name = 'aav_policy_renamed'
WHERE database_name = current_database() AND relation_name = 'aav_policy_target';
SELECT o_eligible = :aav_eligible_excluded AS readopted_policy_applies_again
FROM adaptive_autovacuum._run_cycle(0, 1, 0, 0);

DROP TABLE aav_policy_renamed;
SELECT count(*) = 1 AS table_policy_row_kept_after_drop
FROM adaptive_autovacuum.table_policy;
DELETE FROM adaptive_autovacuum.table_policy;
UPDATE adaptive_autovacuum.policy SET min_table_bytes = 9223372036854775807;

-- The database program uses no extension objects and never allocates a transaction ID.
SELECT position('adaptive_autovacuum.' IN regexp_replace(adaptive_autovacuum._database_program(),
                                                          'adaptive_autovacuum\.worker_(in|out)put', '', 'g')) = 0
       AS program_uses_no_extension_objects,
       position('pg_current_xact_id(' IN adaptive_autovacuum._database_program()) = 0
       AS program_allocates_no_xid,
       position('$aav_program$' IN adaptive_autovacuum._database_program()) = 0
       AS program_free_of_quoting_tag;
SELECT position('pg_current_xact_id(' IN p.prosrc) = 0 AS controller_allocates_no_xid
FROM pg_proc p WHERE p.oid = 'adaptive_autovacuum._global_controller'::regproc;

-- Discovery: every connectable database is managed unless the policy excludes it.
SELECT excluded = false AS current_database_managed_by_default
FROM adaptive_autovacuum._discover_databases() WHERE database_name = current_database();
UPDATE adaptive_autovacuum.policy SET excluded_databases = ARRAY[current_database()::text];
SELECT excluded AS current_database_excluded_by_pattern
FROM adaptive_autovacuum._discover_databases() WHERE database_name = current_database();
SELECT status = 'excluded' AS excluded_database_marked
FROM adaptive_autovacuum.database_status WHERE database_name = current_database();
UPDATE adaptive_autovacuum.policy SET excluded_databases = ARRAY[]::text[];
SELECT excluded = false AS current_database_managed_again
FROM adaptive_autovacuum._discover_databases() WHERE database_name = current_database();


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

-- Dry run proposes each never-analyzed table once, not once per check.
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 1 AS analyze_proposal_not_repeated
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_no_stats'::regclass
  AND action = 'propose_analyze';

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

-- Cluster-evidence merge: an injected summary of two other databases drives the recommendation.
UPDATE adaptive_autovacuum.policy
SET manage_global_settings = true,
    min_table_bytes = 9223372036854775807;

SELECT o_eligible = 0 AND o_overdue = 0 AS local_summary_row_returned
FROM adaptive_autovacuum._run_cycle(0, 1, 0, 0,
    '{"db_count":2,"eligible":8,"overdue":6,"dead_overdue":6,"insert_overdue":0,"fleet_max_target":50000,"w_scale_sum":0.06,"w_thresh_sum":3000,"w_ins_scale_sum":0,"w_ins_thresh_sum":0}'::jsonb);

SELECT recommended_vacuum_scale_factor BETWEEN 0.0099 AND 0.0101
       AND recommended_vacuum_threshold = 500
       AND reason LIKE '%Cluster-wide evidence (sweep %): 3 databases%'
       AS cluster_merge_drives_recommendation
FROM adaptive_autovacuum.latest_global_recommendation;

SELECT (recommended_vacuum_max_threshold IS NOT NULL)
       = (current_setting('server_version_num')::integer >= 180000)
       AS trigger_ceiling_only_on_pg18
FROM adaptive_autovacuum.latest_global_recommendation;

SELECT count(*) = CASE WHEN current_setting('server_version_num')::integer >= 180000
                       THEN 1 ELSE 0 END
       AS max_threshold_queued_only_on_pg18
FROM adaptive_autovacuum.global_apply_queue
WHERE guc_name = 'autovacuum_vacuum_max_threshold';

SELECT count(*) = 1 AS scale_factor_queued_from_cluster_evidence
FROM adaptive_autovacuum.global_apply_queue
WHERE guc_name = 'autovacuum_vacuum_scale_factor'
  AND desired_value = '0.01';

DELETE FROM adaptive_autovacuum.global_apply_queue;
UPDATE adaptive_autovacuum.policy SET manage_global_settings = false;

-- Write discipline: a healthy table leaves nothing, an overdue one logs transitions only.
CREATE TABLE aav_healthy(id integer, payload text) WITH (autovacuum_enabled = false);
INSERT INTO aav_healthy SELECT g, g::text FROM generate_series(1, 10000) g;
CREATE TABLE aav_overdue(id integer, payload text) WITH (autovacuum_enabled = false);
INSERT INTO aav_overdue SELECT g, g::text FROM generate_series(1, 10000) g;
-- Flush BEFORE the VACUUM so it resets the insert counters.
SELECT pg_stat_force_next_flush();
VACUUM ANALYZE aav_healthy;
VACUUM ANALYZE aav_overdue;
DELETE FROM aav_overdue WHERE id > 1000;
SELECT pg_stat_force_next_flush();

UPDATE adaptive_autovacuum.policy SET min_table_bytes = 0;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 0 AS healthy_relation_has_no_state_row
FROM adaptive_autovacuum.table_state
WHERE relation_oid = 'aav_healthy'::regclass;

SELECT count(*) = 0 AS healthy_relation_has_no_decisions
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_healthy'::regclass;

SELECT state LIKE 'backlog_%'
       AND consecutive_overdue = 2
       AND last_action = 'autovacuum_disabled'
       AS overdue_relation_state_row
FROM adaptive_autovacuum.table_state
WHERE relation_oid = 'aav_overdue'::regclass;

SELECT count(*) = 1 AS overdue_episode_logged_once
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_overdue'::regclass
  AND state LIKE 'backlog_%'
  AND action = 'autovacuum_disabled';

VACUUM aav_overdue;
SELECT pg_stat_force_next_flush();

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 0 AS recovered_relation_row_removed
FROM adaptive_autovacuum.table_state
WHERE relation_oid = 'aav_overdue'::regclass;

SELECT count(*) = 2 AS overdue_relation_two_decisions_total
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_overdue'::regclass;

SELECT state = 'normal' AND action = 'recovered' AS recovery_closes_episode
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_overdue'::regclass
ORDER BY id DESC
LIMIT 1;

SELECT pg_stat_force_next_flush();

SELECT n_tup_ins = 1 AND n_tup_upd = 1 AND n_tup_del = 1
       AS state_row_written_only_on_transitions
FROM pg_stat_all_tables
WHERE relid = 'adaptive_autovacuum.table_state'::regclass;

-- Table settings are recommended, never written: open -> applied -> revert, with ready-to-run SQL.
CREATE TABLE aav_rec(id integer, payload text);
INSERT INTO aav_rec SELECT g, g::text FROM generate_series(1, 10000) g;
CREATE TABLE aav_tight(id integer, payload text)
WITH (autovacuum_vacuum_threshold = 100, autovacuum_vacuum_scale_factor = 0);
INSERT INTO aav_tight SELECT g, g::text FROM generate_series(1, 10000) g;
SELECT pg_stat_force_next_flush();
VACUUM ANALYZE aav_rec;
VACUUM ANALYZE aav_tight;
DELETE FROM aav_rec WHERE id > 1000;
DELETE FROM aav_tight WHERE id > 9100;
SELECT pg_stat_force_next_flush();

-- The lock keeps core autovacuum off these tables (it skips locked relations) while the checks run.
BEGIN;
LOCK TABLE aav_rec, aav_tight IN SHARE UPDATE EXCLUSIVE MODE;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 0 AS no_recommendation_before_hysteresis
FROM adaptive_autovacuum.table_recommendations;

SELECT state = 'backlog_urgent' AND last_action = 'observe' AS first_check_observes
FROM adaptive_autovacuum.table_state
WHERE relation_oid = 'aav_rec'::regclass;

DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommendation_status = 'open'
       AND apply_sql = format('ALTER TABLE public.aav_rec SET (autovacuum_vacuum_cost_delay = 1, autovacuum_vacuum_cost_limit = 3000, %sautovacuum_vacuum_scale_factor = 0.09, autovacuum_vacuum_threshold = 100);',
                              CASE WHEN current_setting('server_version_num')::integer >= 180000
                                   THEN 'autovacuum_vacuum_max_threshold = 1000, ' ELSE '' END)
       AND revert_sql IS NULL
       AND applied_at IS NULL
       AND reason LIKE 'Dead tuples 9000 are 4.39x the current trigger of 2050 (threshold 50 + scale factor 0.2 x 10000 rows%firing at 1000 dead tuples (1% of the table) needs threshold 100 and scale factor 0.09%Urgent tier: a table-level cost limit 3000 / delay 1 ms%(boost slot 2 of 2)%'
       AS trigger_and_cost_recommended_together
FROM adaptive_autovacuum.table_recommendations
WHERE relation_name = 'public.aav_rec';

-- Never loosen: a trigger already tighter than the policy target is left alone; the boost still comes.
SELECT recommendation_status = 'open'
       AND apply_sql = 'ALTER TABLE public.aav_tight SET (autovacuum_vacuum_cost_delay = 0, autovacuum_vacuum_cost_limit = 6000);'
       AND NOT (recommended_reloptions ? 'autovacuum_vacuum_threshold')
       AND reason LIKE 'The current trigger (100 dead tuples) is already at or below the policy target (1000)%Critical tier: a table-level cost limit 6000 / delay 0 ms%(boost slot 1 of 2)%'
       AS tight_trigger_never_loosened
FROM adaptive_autovacuum.table_recommendations
WHERE relation_name = 'public.aav_tight';

SELECT count(*) = 1 AS recommendation_transition_logged_once
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_rec'::regclass AND action = 'recommend_reloptions' AND NOT applied;

SELECT recommended_relations = 2 AS database_status_counts_open_recommendations
FROM adaptive_autovacuum.database_status
WHERE database_name = current_database();

-- The operator runs the SQL in the table's database; the next check sees it applied.
DO $$
BEGIN
    EXECUTE (SELECT apply_sql FROM adaptive_autovacuum.table_recommendations WHERE relation_name = 'public.aav_rec');
END
$$;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommendation_status = 'applied'
       AND applied_at IS NOT NULL
       AND apply_sql IS NULL
       AND revert_sql = format('ALTER TABLE public.aav_rec RESET (autovacuum_vacuum_cost_delay, autovacuum_vacuum_cost_limit, %sautovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold);',
                               CASE WHEN current_setting('server_version_num')::integer >= 180000
                                    THEN 'autovacuum_vacuum_max_threshold, ' ELSE '' END)
       AS recommendation_detected_as_applied
FROM adaptive_autovacuum.table_recommendations
WHERE relation_name = 'public.aav_rec';

-- Against its new trigger the table reads critical, but an applied recommendation is never re-tuned.
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT state = 'backlog_critical'
       AND recommendation_status = 'applied'
       AND recommended_reloptions ->> 'autovacuum_vacuum_cost_limit' = '3000'
       AS applied_recommendation_frozen
FROM adaptive_autovacuum.table_state
WHERE relation_oid = 'aav_rec'::regclass;

SELECT count(*) = 1 AS applied_transition_logged_once
FROM adaptive_autovacuum.decisions
WHERE relid = 'aav_rec'::regclass AND action = 'recommendation_applied';
COMMIT;

-- Healthy again: the trigger settings stay with the operator, the cost boost gets a revert.
VACUUM aav_rec;
VACUUM aav_tight;
SELECT pg_stat_force_next_flush();
UPDATE adaptive_autovacuum.policy SET healthy_cycles_before_revert = 1;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommendation_status = 'revert'
       AND revert_sql = 'ALTER TABLE public.aav_rec RESET (autovacuum_vacuum_cost_delay, autovacuum_vacuum_cost_limit);'
       AND apply_sql IS NULL
       AND reason LIKE 'The relation has been normal for 1 check(s); the table-level cost boost (3000 / 1 ms)%'
       AS cost_boost_revert_recommended
FROM adaptive_autovacuum.table_recommendations
WHERE relation_name = 'public.aav_rec';

-- The unapplied recommendation of the now-healthy table is withdrawn.
SELECT count(*) = 0 AS open_recommendation_withdrawn_when_healthy
FROM adaptive_autovacuum.table_recommendations
WHERE relation_name = 'public.aav_tight';

DO $$
BEGIN
    EXECUTE (SELECT revert_sql FROM adaptive_autovacuum.table_recommendations WHERE relation_name = 'public.aav_rec');
END
$$;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT count(*) = 0 AS reverted_recommendation_closed
FROM adaptive_autovacuum.table_recommendations;

SELECT adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_threshold')::integer = 100
       AND adaptive_autovacuum._option_value(reloptions, 'autovacuum_vacuum_cost_limit') IS NULL
       AS operator_keeps_trigger_boost_removed
FROM pg_class WHERE oid = 'aav_rec'::regclass;
UPDATE adaptive_autovacuum.policy SET healthy_cycles_before_revert = 6;

-- A dropped table takes its state row with it at the next check.
CREATE TABLE aav_gone(id integer) WITH (autovacuum_enabled = false);
INSERT INTO aav_gone SELECT g FROM generate_series(1, 10000) g;
SELECT pg_stat_force_next_flush();
VACUUM ANALYZE aav_gone;
DELETE FROM aav_gone WHERE id > 1000;
SELECT pg_stat_force_next_flush();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
SELECT count(*) = 1 AS overdue_table_has_state_row
FROM adaptive_autovacuum.table_state WHERE relation_name = 'public.aav_gone';
DROP TABLE aav_gone;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
SELECT count(*) = 0 AS dropped_table_state_row_pruned
FROM adaptive_autovacuum.table_state WHERE relation_name = 'public.aav_gone';

-- Debt trend: a synthetic previous sample makes the same backlog read as growing, then shrinking.
DELETE FROM aav_overdue WHERE id > 100;
SELECT pg_stat_force_next_flush();
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT backlog_trend = 'growing'
       AND maintenance_debt_tuples >= 900
       AND maintenance_debt_velocity > 0
       AND recommended_cost_limit = 2 * current_setting('vacuum_cost_limit')::integer
       AND reason LIKE '%maintenance debt is growing%'
       AS growing_debt_raises_cost_limit
FROM adaptive_autovacuum.latest_global_recommendation;

UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = debt_tuples * 100, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT backlog_trend = 'shrinking'
       AND maintenance_debt_velocity < 0
       AND recommended_cost_limit = current_setting('vacuum_cost_limit')::integer
       AND reason LIKE '%debt is shrinking%clear in about%holding%'
       AS shrinking_debt_holds_cost_limit
FROM adaptive_autovacuum.latest_global_recommendation;

-- Shrinking 10% per 60 s check projects a 600 s drain, above the 180 s target: keep raising.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = round(debt_tuples * 1.1), debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT backlog_trend = 'shrinking'
       AND recommended_cost_limit = 2 * current_setting('vacuum_cost_limit')::integer
       AND reason LIKE '%but would take about%to clear (max_backlog_drain_seconds = 180)%'
       AS slow_shrinking_debt_still_raises
FROM adaptive_autovacuum.latest_global_recommendation;

-- Throughput cap: the delay is kept and only the part of the limit raise that fits is taken.
SELECT current_setting('vacuum_cost_limit')::integer AS aav_limit \gset
SELECT setting::double precision AS aav_delay FROM pg_settings
WHERE name = 'autovacuum_vacuum_cost_delay' \gset
UPDATE adaptive_autovacuum.policy SET recommendation_max_vacuum_mbps = 1600;
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT backlog_trend = 'growing'
       AND recommended_cost_limit = 2 * :aav_limit
       AND recommended_cost_delay_ms = :aav_delay
       AND cost_ceiling_mbps = adaptive_autovacuum.vacuum_cost_ceiling_mbps(2 * :aav_limit, :aav_delay)
       AND reason LIKE '%Throughput cap 1600 MB/s%delay stays at%'
       AS throughput_cap_keeps_delay_raises_limit
FROM adaptive_autovacuum.latest_global_recommendation;

UPDATE adaptive_autovacuum.policy SET recommendation_max_vacuum_mbps = 780;
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_cost_limit = :aav_limit
       AND recommended_cost_delay_ms = :aav_delay
       AND reason LIKE '%Throughput cap 780 MB/s%is held%'
       AS throughput_cap_holds_when_nothing_fits
FROM adaptive_autovacuum.latest_global_recommendation;
UPDATE adaptive_autovacuum.policy SET recommendation_max_vacuum_mbps = 3200;

-- Observed-throughput feedback: an applied raise that did not raise pg_stat_io throughput holds.
INSERT INTO adaptive_autovacuum.global_apply_queue
    (guc_name, desired_value, status, requested_at, applied_at)
VALUES ('autovacuum_vacuum_cost_limit', current_setting('vacuum_cost_limit'), 'applied',
        clock_timestamp() - interval '120 seconds', clock_timestamp() - interval '119 seconds');
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
UPDATE adaptive_autovacuum.controller_state
SET     last_vacuum_activity_units = 0,
    last_cost_raise_at = clock_timestamp() - interval '120 seconds',
    last_raise_cost_limit = :aav_limit,
    last_raise_cost_delay = :aav_delay,
    activity_before_raise = 1e15;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_cost_limit = :aav_limit
       AND recommended_cost_delay_ms = :aav_delay
       AND vacuum_activity_rate IS NOT NULL
       AND reason LIKE '%did not produce a meaningful increase in autovacuum activity%holding%'
       AS no_activity_gain_holds_cost_raise
FROM adaptive_autovacuum.latest_global_recommendation;

-- A raise younger than the previous sample has not been observed over a full interval yet.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
UPDATE adaptive_autovacuum.controller_state
SET     last_cost_raise_at = clock_timestamp() - interval '30 seconds';
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_cost_limit = :aav_limit
       AND reason LIKE '%has not yet been observed over a full check interval%'
       AS post_raise_interval_awaited
FROM adaptive_autovacuum.latest_global_recommendation;

-- A raise applied within the first tenth of the interval is judged on that interval.
INSERT INTO adaptive_autovacuum.global_apply_queue
    (guc_name, desired_value, status, requested_at, applied_at)
VALUES ('autovacuum_vacuum_cost_limit', current_setting('vacuum_cost_limit'), 'applied',
        clock_timestamp() - interval '59.5 seconds', clock_timestamp() - interval '59 seconds');
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
UPDATE adaptive_autovacuum.controller_state
SET     last_vacuum_activity_units = 0,
    last_cost_raise_at = clock_timestamp() - interval '59.5 seconds',
    activity_before_raise = 1e15;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_cost_limit = :aav_limit
       AND reason LIKE '%did not produce a meaningful increase in autovacuum activity%'
       AS raise_early_in_interval_is_judged
FROM adaptive_autovacuum.latest_global_recommendation;

-- A -1 MB seed guarantees a measured rate above a zero pre-raise rate: the raise is allowed.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
UPDATE adaptive_autovacuum.controller_state
SET     last_vacuum_activity_units = -1000000,
    last_cost_raise_at = clock_timestamp() - interval '120 seconds',
    activity_before_raise = 0;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_cost_limit = 2 * :aav_limit
       AND vacuum_activity_rate > 0
       AS observed_activity_gain_allows_raise
FROM adaptive_autovacuum.latest_global_recommendation;

-- Detail keys are counter deltas per second: a seed 100000 hits behind over 100000 s reads back as 1 hit/s.
UPDATE adaptive_autovacuum.controller_state
SET last_sample_at = clock_timestamp() - interval '100000 seconds',
    last_io_hits = last_io_hits - 100000,
    last_vacuum_activity_units = -1000000;
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT round((vacuum_activity_detail ->> 'hits_per_sec')::numeric, 1) = 1.0
       AND (vacuum_activity_detail ->> 'reads_per_sec')::numeric < 1
       AS activity_detail_uses_counter_deltas
FROM adaptive_autovacuum.latest_global_recommendation;

-- A record that no longer matches the live settings (operator change, failed apply) is ignored.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
UPDATE adaptive_autovacuum.controller_state
SET     last_raise_cost_limit = 12345,
    activity_before_raise = 1e15;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_cost_limit = 2 * :aav_limit AS stale_raise_record_ignored
FROM adaptive_autovacuum.latest_global_recommendation;

DELETE FROM adaptive_autovacuum.global_apply_queue;

-- Decay: no backlog for the configured checks steps cost settings halfway back to the baseline.
VACUUM aav_overdue;
SELECT pg_stat_force_next_flush();
INSERT INTO adaptive_autovacuum.global_apply_queue (guc_name, desired_value, status, applied_at)
SELECT s.name, s.setting, 'applied', clock_timestamp()
FROM pg_settings s
WHERE s.name IN ('autovacuum_vacuum_cost_limit', 'autovacuum_vacuum_cost_delay', 'autovacuum_naptime');
SELECT setting::integer AS aav_naptime FROM pg_settings WHERE name = 'autovacuum_naptime' \gset
UPDATE adaptive_autovacuum.global_apply_queue
SET desired_value = current_setting('vacuum_cost_limit')
WHERE guc_name = 'autovacuum_vacuum_cost_limit' AND desired_value = '-1';
UPDATE adaptive_autovacuum.controller_state
SET backlog_free_cycles = 9,
    baseline_settings = jsonb_build_object(
        'autovacuum_vacuum_cost_limit', current_setting('vacuum_cost_limit')::integer / 4,
        'autovacuum_vacuum_cost_delay', 20,
        'autovacuum_naptime', 4 * :aav_naptime);
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT r.overdue_relations = 0
       AND r.recommended_cost_limit = current_setting('vacuum_cost_limit')::integer / 2
       AND r.recommended_cost_delay_ms = LEAST(20, GREATEST(0.5, 2 * s.setting::double precision))
       AND r.recommended_autovacuum_naptime_seconds = 2 * :aav_naptime
       AND r.reason LIKE 'No overdue relations for 10 consecutive checks%'
       AS clean_checks_decay_toward_baseline
FROM adaptive_autovacuum.latest_global_recommendation r,
     pg_settings s
WHERE s.name = 'autovacuum_vacuum_cost_delay';

SELECT backlog_free_cycles = 0 AS decay_step_resets_counter
FROM adaptive_autovacuum.controller_state;

SELECT last_cost_raise_at IS NULL AND last_raise_cost_limit IS NULL
       AND activity_before_raise IS NULL
       AS backlog_free_check_clears_raise_record
FROM adaptive_autovacuum.controller_state;

DELETE FROM adaptive_autovacuum.global_apply_queue;

-- Worker pool: an overdue queue far longer than the pool counts as saturation, and the
-- recommendation may exceed the CPU count (host_cpu_count = 1 here).
DO $$
BEGIN
    FOR i IN 1..8 LOOP
        EXECUTE format('CREATE TABLE aav_wq_%s(id integer, payload text)'
                       || ' WITH (autovacuum_enabled = false)', i);
        EXECUTE format('INSERT INTO aav_wq_%s SELECT g, g::text FROM generate_series(1, 10000) g', i);
    END LOOP;
END
$$;
SELECT pg_stat_force_next_flush();
VACUUM ANALYZE aav_wq_1, aav_wq_2, aav_wq_3, aav_wq_4, aav_wq_5, aav_wq_6, aav_wq_7, aav_wq_8;
DO $$
BEGIN
    FOR i IN 1..8 LOOP
        EXECUTE format('DELETE FROM aav_wq_%s WHERE id > 1000', i);
    END LOOP;
END
$$;
SELECT pg_stat_force_next_flush();
SELECT setting::integer AS aav_workers FROM pg_settings WHERE name = 'autovacuum_max_workers' \gset

UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT overdue_relations >= 8
       AND backlog_trend = 'growing'
       AND recommended_autovacuum_workers = 2 * :aav_workers
       AND recommended_autovacuum_workers > (host_metrics ->> 'cpu_count')::integer
       AND reason LIKE format('%%raise autovacuum_max_workers to %s%%', 2 * :aav_workers)
       AS queue_pressure_raises_workers_past_cpu_count
FROM adaptive_autovacuum.latest_global_recommendation;

-- The launcher starts one worker per database per naptime: an under-filled pool halves autovacuum_naptime.
SELECT setting::integer AS aav_naptime FROM pg_settings WHERE name = 'autovacuum_naptime' \gset
SELECT recommended_autovacuum_naptime_seconds = GREATEST(5, :aav_naptime / 2)
       AND reason LIKE format('%%so it goes %s -> %s s (floor 5 s) to fill the pool%%', :aav_naptime, GREATEST(5, :aav_naptime / 2))
       AS underfilled_pool_halves_naptime
FROM adaptive_autovacuum.latest_global_recommendation;

-- CPU load alone (load 10 on 1 CPU) no longer blocks the raise: workers share one cost budget.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(10, 1, 0, 0);
END
$$;

SELECT overdue_relations >= 8
       AND recommended_autovacuum_workers = 2 * :aav_workers
       AND recommended_autovacuum_naptime_seconds = GREATEST(5, :aav_naptime / 2)
       AND recommended_cost_limit = current_setting('vacuum_cost_limit')::integer
       AS cpu_load_alone_does_not_block_worker_raise
FROM adaptive_autovacuum.latest_global_recommendation;

-- Memory pressure (1% free) still blocks the raise and the naptime step.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 1000000, 100000000);
END
$$;

SELECT overdue_relations >= 8
       AND recommended_autovacuum_workers = :aav_workers
       AND recommended_autovacuum_naptime_seconds = :aav_naptime
       AS memory_pressure_blocks_worker_raise
FROM adaptive_autovacuum.latest_global_recommendation;

-- Free memory caps the raise: 3 x autovacuum_work_mem free allows exactly one extra worker.
SELECT 3 * 1024 * CASE WHEN a.setting::integer < 0 THEN m.setting::bigint ELSE a.setting::bigint END
       AS aav_mem
FROM pg_settings a, pg_settings m
WHERE a.name = 'autovacuum_work_mem' AND m.name = 'maintenance_work_mem' \gset
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
SELECT o_overdue >= 8 AS memory_capped_cycle_ran
FROM adaptive_autovacuum._run_cycle(0, 1, :aav_mem, :aav_mem);

SELECT recommended_autovacuum_workers = :aav_workers + 1
       AS free_memory_caps_worker_raise
FROM adaptive_autovacuum.latest_global_recommendation;

-- recommendation_workers_max stays a hard ceiling.
UPDATE adaptive_autovacuum.policy SET recommendation_workers_max = :aav_workers + 1;
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = 0, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT recommended_autovacuum_workers = :aav_workers + 1
       AS policy_max_caps_worker_raise
FROM adaptive_autovacuum.latest_global_recommendation;
UPDATE adaptive_autovacuum.policy SET recommendation_workers_max = 16;

-- A shrinking backlog holds the pool even under queue pressure.
UPDATE adaptive_autovacuum.controller_state SET last_sample_at = clock_timestamp() - interval '60 seconds';
UPDATE adaptive_autovacuum.database_state
SET last_scan_completed_at = clock_timestamp() - interval '60 seconds', debt_tuples = debt_tuples * 100, debt_velocity = NULL
WHERE database_name = current_database();
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;

SELECT backlog_trend = 'shrinking'
       AND recommended_autovacuum_workers = :aav_workers
       AND recommended_autovacuum_naptime_seconds = :aav_naptime
       AS shrinking_debt_holds_workers_and_naptime
FROM adaptive_autovacuum.latest_global_recommendation;

-- A widely overdue fleet (the eight worker-pool tables) means the baseline is wrong: no per-table trigger advice.
CREATE TABLE aav_wide(id integer, payload text);
INSERT INTO aav_wide SELECT g, g::text FROM generate_series(1, 10000) g;
SELECT pg_stat_force_next_flush();
VACUUM ANALYZE aav_wide;
DELETE FROM aav_wide WHERE id > 1000;
SELECT pg_stat_force_next_flush();
BEGIN;
LOCK TABLE aav_wide IN SHARE UPDATE EXCLUSIVE MODE;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
SELECT recommendation_status = 'open'
       AND NOT (recommended_reloptions ? 'autovacuum_vacuum_threshold')
       AND recommended_reloptions ? 'autovacuum_vacuum_cost_limit'
       AND reason LIKE '9 of % eligible tables were overdue on the dead-tuple side in the last scan: the cluster baseline is being corrected%'
       AS widespread_overdue_suppresses_trigger_advice
FROM adaptive_autovacuum.table_recommendations
WHERE relation_name = 'public.aav_wide';
COMMIT;
DROP TABLE aav_wide;
-- The dropped table's recommendation goes with it at the next check.
DO $$
BEGIN
    PERFORM adaptive_autovacuum._run_cycle(0, 1, 0, 0);
END
$$;
SELECT count(*) = 0 AS dropped_table_recommendation_pruned
FROM adaptive_autovacuum.table_recommendations;

SELECT bool_and(relpersistence = 'u') AS audit_tables_unlogged
FROM pg_class
WHERE oid IN ('adaptive_autovacuum.decisions'::regclass,
              'adaptive_autovacuum.global_recommendations'::regclass);

SELECT bool_and(relpersistence = 'p') AS control_tables_logged
FROM pg_class
WHERE oid IN ('adaptive_autovacuum.policy'::regclass,
              'adaptive_autovacuum.table_policy'::regclass,
              'adaptive_autovacuum.table_state'::regclass,
              'adaptive_autovacuum.database_state'::regclass,
              'adaptive_autovacuum.global_apply_queue'::regclass,
              'adaptive_autovacuum.emergency_queue'::regclass,
              'adaptive_autovacuum.controller_state'::regclass);

/* Operator API: fixed check set, valid vocabulary, preload check agrees with shared memory. */
SELECT count(*) = 19 AS doctor_check_count,
       bool_and(status IN ('OK', 'WARN', 'FAIL', 'RESTART_REQUIRED')) AS doctor_statuses_valid,
       bool_and(detail IS NOT NULL) AS doctor_details_present
FROM adaptive_autovacuum.doctor();

SELECT (SELECT status FROM adaptive_autovacuum.doctor() WHERE check_name = 'table_recommendations') = 'OK'
       AS doctor_no_open_recommendations;

SELECT (SELECT status FROM adaptive_autovacuum.doctor() WHERE check_name = 'library_preloaded')
       = CASE WHEN (SELECT available FROM adaptive_autovacuum.controller_status())
              THEN 'OK' ELSE 'FAIL' END AS preload_check_matches_shared_memory;

SELECT extension_version = '1.3.0' AS status_version,
       available_version = '1.3.0' AS status_available_version,
       library_preloaded = (SELECT available FROM adaptive_autovacuum.controller_status()) AS status_preload_matches,
       launcher_running IS NOT NULL AS status_launcher_known,
       controller_running IS NOT NULL AS status_controller_known,
       control_database = 'postgres' AS status_default_control_database,
       NOT is_control_database AS regression_database_is_not_the_control_database,
       cluster_generation > 0 AS status_generation_counts,
       managed_databases >= 1 AS status_sees_managed_databases,
       open_table_recommendations = 0 AS status_no_open_recommendations,
       wraparound_status IN ('ok', 'watch', 'alarm') AS status_wraparound_known
FROM adaptive_autovacuum.status();

-- Cluster-first observability: the current database has a row, actions has the applied table changes.
SELECT status IN ('healthy', 'backlog', 'emergency') AND scan_generation IS NOT NULL
       AND table_count >= 1 AND NOT stale
       AS database_status_row_for_current_database
FROM adaptive_autovacuum.database_status
WHERE database_name = current_database();

SELECT count(*) >= 1 AS actions_view_lists_table_actions
FROM adaptive_autovacuum.actions
WHERE action_scope = 'table' AND database_name = current_database() AND status = 'applied';

SELECT count(*) <= 10 AS aging_tables_is_top_ten
FROM adaptive_autovacuum.aging_tables;

SELECT adaptive_autovacuum._preload_lists_library('pg_stat_statements, "$libdir/adaptive_autovacuum"') AS preload_parse_quoted_libdir,
       adaptive_autovacuum._preload_lists_library('adaptive_autovacuum.so') AS preload_parse_suffix,
       NOT adaptive_autovacuum._preload_lists_library('pg_stat_statements,auto_explain') AS preload_parse_absent,
       NOT adaptive_autovacuum._preload_lists_library('adaptive_autovacuum_extra') AS preload_parse_exact_name,
       NOT adaptive_autovacuum._preload_lists_library('') AS preload_parse_empty;

SELECT adaptive_autovacuum._version_key('1.0.0') < adaptive_autovacuum._version_key('1.1.0') AS version_key_orders,
       adaptive_autovacuum._version_key('1.2.0-beta') = ARRAY[1, 2, 0] AS version_key_ignores_tag;

DROP TABLE aav_healthy;
DROP TABLE aav_overdue;
DROP TABLE aav_rec;
DROP TABLE aav_tight;
DROP TABLE aav_wq_1, aav_wq_2, aav_wq_3, aav_wq_4, aav_wq_5, aav_wq_6, aav_wq_7, aav_wq_8;
DROP TABLE aav_no_stats;
DROP TABLE aav_test;
DROP EXTENSION adaptive_autovacuum;
