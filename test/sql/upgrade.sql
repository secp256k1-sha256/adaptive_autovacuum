\pset format unaligned
\pset tuples_only on
SET client_min_messages = warning;

/* Upgrade path 1.0.0 -> 1.1.0: operator values and history survive, the new API appears. */
CREATE EXTENSION adaptive_autovacuum VERSION '1.0.0';

SELECT extversion FROM pg_extension WHERE extname = 'adaptive_autovacuum';

UPDATE adaptive_autovacuum.policy
SET dry_run = true,
    min_table_bytes = 12345,
    high_load_per_cpu = 0.85;

INSERT INTO adaptive_autovacuum.global_apply_queue (guc_name, desired_value, old_value, status)
VALUES ('autovacuum_vacuum_cost_limit', '400', '200', 'applied');

ALTER EXTENSION adaptive_autovacuum UPDATE;

SELECT extversion FROM pg_extension WHERE extname = 'adaptive_autovacuum';

SELECT dry_run AS dry_run_preserved,
       min_table_bytes = 12345 AS min_table_bytes_preserved,
       high_load_per_cpu = 0.85 AS load_gate_preserved,
       enabled AS enabled_untouched
FROM adaptive_autovacuum.policy;

SELECT count(*) = 1 AS history_preserved
FROM adaptive_autovacuum.global_apply_queue
WHERE status = 'applied' AND desired_value = '400';

SELECT count(*) = 15 AS doctor_available,
       bool_and(status IN ('OK', 'WARN', 'FAIL', 'RESTART_REQUIRED')) AS doctor_statuses_valid
FROM adaptive_autovacuum.doctor();

SELECT status = 'WARN' AS policy_check_warns_on_dry_run
FROM adaptive_autovacuum.doctor()
WHERE check_name = 'policy';

SELECT status = 'OK' AS version_check_current
FROM adaptive_autovacuum.doctor()
WHERE check_name = 'extension_version';

/* Installer activation: flips the three switches, reports old and new values. */
SELECT setting, previous_value, new_value
FROM adaptive_autovacuum.enable_default_policy()
ORDER BY setting;

SELECT enabled, dry_run, manage_global_settings
FROM adaptive_autovacuum.policy;

/* Idempotent second call. */
SELECT setting, previous_value, new_value
FROM adaptive_autovacuum.enable_default_policy()
ORDER BY setting;

SELECT status = 'OK' AS policy_check_ok_after_enable
FROM adaptive_autovacuum.doctor()
WHERE check_name = 'policy';

SELECT min_table_bytes = 12345 AS other_columns_untouched
FROM adaptive_autovacuum.policy;

/* pg_monitor may read status() and doctor() but may not change the policy. */
CREATE ROLE aav_upgrade_monitor;
GRANT pg_monitor TO aav_upgrade_monitor;
SET ROLE aav_upgrade_monitor;

SELECT count(*) = 15 AS monitor_can_run_doctor
FROM adaptive_autovacuum.doctor();

SELECT extension_version
FROM adaptive_autovacuum.status();

SELECT has_function_privilege('adaptive_autovacuum.enable_default_policy()', 'EXECUTE') AS monitor_can_enable_policy;

RESET ROLE;
DROP ROLE aav_upgrade_monitor;

DROP EXTENSION adaptive_autovacuum;
