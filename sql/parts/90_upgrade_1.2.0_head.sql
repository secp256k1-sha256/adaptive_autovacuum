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

