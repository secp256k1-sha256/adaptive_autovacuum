-- Run in the CONTROL database (postgres) with the controller disabled.
-- Wipes the extension's learned state and history so the next run starts like a fresh install:
-- empty global_recommendations / decisions / apply queue, no per-table or per-database memory,
-- controller_state back to its install-time defaults (generation 0, no baseline, no last-raise memory).
BEGIN;
TRUNCATE adaptive_autovacuum.global_recommendations,
         adaptive_autovacuum.decisions,
         adaptive_autovacuum.global_apply_queue,
         adaptive_autovacuum.emergency_queue;
DELETE FROM adaptive_autovacuum.table_state;
DELETE FROM adaptive_autovacuum.database_state;
DELETE FROM adaptive_autovacuum.controller_state;
INSERT INTO adaptive_autovacuum.controller_state (only_row) VALUES (true);
COMMIT;

SELECT (SELECT count(*) FROM adaptive_autovacuum.global_recommendations) AS recommendations,
       (SELECT count(*) FROM adaptive_autovacuum.table_state)             AS table_state_rows,
       (SELECT cluster_generation FROM adaptive_autovacuum.controller_state) AS generation;
