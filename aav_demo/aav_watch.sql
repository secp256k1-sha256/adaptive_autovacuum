\set QUIET on
\pset linestyle ascii
\pset border 2
\pset pager off
\pset footer off
SELECT coalesce(nullif(current_setting('adaptive_autovacuum.control_database', true), ''), 'postgres') AS ctrl \gset
\c :ctrl
\set QUIET off

SELECT now()::time(0)                                              AS time,
       current_setting('autovacuum')                               AS autovacuum,
       count(*) FILTER (WHERE backend_type = 'autovacuum worker')  AS av_running,
       current_setting('autovacuum_max_workers')                   AS max_workers,
       current_setting('autovacuum_naptime')                       AS naptime,
       current_setting('autovacuum_vacuum_cost_limit')             AS av_cost_limit,
       (SELECT setting::numeric FROM pg_settings
        WHERE name = 'autovacuum_vacuum_cost_delay')                AS av_cost_delay_ms
FROM pg_stat_activity;

SELECT * FROM (
    SELECT to_char(created_at, 'HH24:MI:SS')                       AS check,
           CASE WHEN recommended_cost_limit
                     = lag(recommended_cost_limit)    OVER (ORDER BY id)
                 AND recommended_cost_delay_ms
                     = lag(recommended_cost_delay_ms) OVER (ORDER BY id)
                THEN 'held'
                ELSE recommended_cost_limit || ' / ' || recommended_cost_delay_ms
           END                                                     AS cost_pair,
           recommended_autovacuum_workers                          AS workers,
           recommended_autovacuum_naptime_seconds                  AS naptime,
           maintenance_debt_tuples                                 AS dead_tuples,
           overdue_relations                                       AS overdue,
           backlog_trend                                           AS trend,
           round((vacuum_activity_detail ->> 'reads_per_sec')::numeric
                 * current_setting('block_size')::numeric / 1048576, 1) AS read_mbps,
           round(((vacuum_activity_detail ->> 'writes_per_sec')::numeric
                  + (vacuum_activity_detail ->> 'extends_per_sec')::numeric)
                 * current_setting('block_size')::numeric / 1048576, 1) AS write_mbps,
           id
    FROM adaptive_autovacuum.global_recommendations
) r
ORDER BY id DESC
LIMIT 10;
