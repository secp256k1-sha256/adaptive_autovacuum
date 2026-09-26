\echo Use "CREATE EXTENSION adaptive_autovacuum" to load this file. \quit

/* Install once per cluster, in the control database; every other database is managed from here. */
DO $aav_install$
DECLARE
    control_db text := coalesce(nullif(current_setting('adaptive_autovacuum.control_database', true), ''), 'postgres');
BEGIN
    IF current_database() <> control_db THEN
        RAISE WARNING 'adaptive_autovacuum is being installed in a database that is not the control database "%" (adaptive_autovacuum.control_database); the controller ignores the objects created here and already manages this database from the control database',
                      control_db
            USING HINT = 'Install the extension once, in the control database, or point adaptive_autovacuum.control_database at this database.';
    END IF;
END
$aav_install$;

CREATE SCHEMA adaptive_autovacuum;
REVOKE ALL ON SCHEMA adaptive_autovacuum FROM PUBLIC;

CREATE FUNCTION adaptive_autovacuum.host_metrics()
RETURNS jsonb
AS 'MODULE_PATHNAME', 'adaptive_autovacuum_host_metrics'
LANGUAGE C
VOLATILE
PARALLEL UNSAFE;

/* Shared-memory controller identity and sweep-generation tracking; available=false without preload. */
CREATE FUNCTION adaptive_autovacuum.controller_status(
    OUT available boolean,
    OUT launcher_pid integer,
    OUT controller_pid integer,
    OUT controller_state text,
    OUT control_database_oid oid,
    OUT current_generation bigint,
    OUT last_complete_generation bigint,
    OUT expected_databases integer,
    OUT completed_databases integer,
    OUT failed_databases integer,
    OUT generation_started_at timestamptz,
    OUT generation_completed_at timestamptz,
    OUT observed_sweep_seconds double precision,
    OUT emergency_worker_pid integer,
    OUT emergency_database_oid oid)
RETURNS record
AS 'MODULE_PATHNAME', 'adaptive_autovacuum_controller_status'
LANGUAGE C
VOLATILE
PARALLEL UNSAFE;

/* One cluster policy row; database scope is chosen here, not by where the extension is installed. */
CREATE TABLE adaptive_autovacuum.policy
(
    singleton                       boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    enabled                         boolean NOT NULL DEFAULT true,
    dry_run                         boolean NOT NULL DEFAULT false,
    manage_global_settings          boolean NOT NULL DEFAULT true,

    /* LIKE patterns against datname; NULL included = every connectable non-template database. */
    included_databases              text[],
    excluded_databases              text[] NOT NULL DEFAULT ARRAY[]::text[],

    /* Size floor for the performance scan; 0 = every table counts (small hot tables matter too). */
    min_table_bytes                 bigint NOT NULL DEFAULT 0 CHECK (min_table_bytes >= 0),
    excluded_schemas                text[] NOT NULL DEFAULT ARRAY['pg_catalog', 'information_schema', 'pg_toast', 'adaptive_autovacuum'],

    target_dead_tuple_ratio         double precision NOT NULL DEFAULT 0.01 CHECK (target_dead_tuple_ratio > 0 AND target_dead_tuple_ratio <= 1),
    target_dead_tuple_min           bigint NOT NULL DEFAULT 1000 CHECK (target_dead_tuple_min >= 0),
    target_dead_tuple_max           bigint NOT NULL DEFAULT 1000000 CHECK (target_dead_tuple_max >= target_dead_tuple_min AND target_dead_tuple_max <= 2147483647),
    target_insert_ratio             double precision NOT NULL DEFAULT 0.10 CHECK (target_insert_ratio > 0 AND target_insert_ratio <= 1),
    target_insert_min               bigint NOT NULL DEFAULT 10000 CHECK (target_insert_min >= 0),
    target_insert_max               bigint NOT NULL DEFAULT 10000000 CHECK (target_insert_max >= target_insert_min AND target_insert_max <= 2147483647),
    threshold_floor                 integer NOT NULL DEFAULT 50 CHECK (threshold_floor >= 0),
    min_scale_factor                double precision NOT NULL DEFAULT 0.0001 CHECK (min_scale_factor >= 0),
    max_scale_factor                double precision NOT NULL DEFAULT 0.20 CONSTRAINT policy_max_scale_factor_check CHECK (max_scale_factor >= min_scale_factor AND max_scale_factor <= 100),

    backlog_elevated_ratio          double precision NOT NULL DEFAULT 1.50 CHECK (backlog_elevated_ratio >= 1),
    backlog_urgent_ratio            double precision NOT NULL DEFAULT 3.00 CHECK (backlog_urgent_ratio >= backlog_elevated_ratio),
    backlog_critical_ratio          double precision NOT NULL DEFAULT 6.00 CHECK (backlog_critical_ratio >= backlog_urgent_ratio),
    /* Consecutive non-normal checks before a table recommendation is issued. */
    overdue_cycles_before_recommend integer NOT NULL DEFAULT 2 CHECK (overdue_cycles_before_recommend >= 1),
    /* Consecutive normal checks before an applied cost boost gets a revert recommendation. */
    healthy_cycles_before_revert    integer NOT NULL DEFAULT 6 CHECK (healthy_cycles_before_revert >= 1),
    /* Lock timeout of the in-cycle ANALYZE (the program never runs ALTER TABLE). */
    lock_timeout_ms                 integer NOT NULL DEFAULT 250 CHECK (lock_timeout_ms >= 1),

    /* Never-analyzed tables leave the planner guessing; analyze the largest within a budget. */
    analyze_missing_stats           boolean NOT NULL DEFAULT true,
    analyze_missing_stats_budget_ms integer NOT NULL DEFAULT 10000 CHECK (analyze_missing_stats_budget_ms >= 0),

    /* autovacuum=off is repaired after this many consecutive checks; it is never turned off. */
    repair_disabled_autovacuum      boolean NOT NULL DEFAULT true,
    repair_disabled_autovacuum_cycles integer NOT NULL DEFAULT 1 CHECK (repair_disabled_autovacuum_cycles >= 1),

    /* Debt trend deadband: growth per check above it = growing, below its negative = shrinking. */
    backlog_trend_deadband          double precision NOT NULL DEFAULT 0.05 CHECK (backlog_trend_deadband > 0 AND backlog_trend_deadband < 1),
    /* Backlog-free checks in a row before one cost step back toward the baseline. */
    recovery_cycles_before_decay    integer NOT NULL DEFAULT 10 CHECK (recovery_cycles_before_decay >= 1),
    /* A shrinking backlog only holds the raises if it is projected to clear within this time. */
    max_backlog_drain_seconds       integer NOT NULL DEFAULT 180 CHECK (max_backlog_drain_seconds >= 1),

    /* Table-level cost boosts are recommendations (table_recommendations), tiered by severity. */
    recommend_table_costs           boolean NOT NULL DEFAULT true,
    max_boosted_relations           integer NOT NULL DEFAULT 2 CHECK (max_boosted_relations >= 0),
    /* Caps = documented maxima of (auto)vacuum_cost_limit / _cost_delay. */
    elevated_cost_limit             integer NOT NULL DEFAULT 1000 CHECK (elevated_cost_limit >= 200 AND elevated_cost_limit <= 10000),
    urgent_cost_limit               integer NOT NULL DEFAULT 3000 CONSTRAINT policy_urgent_cost_limit_check CHECK (urgent_cost_limit >= elevated_cost_limit AND urgent_cost_limit <= 10000),
    critical_cost_limit             integer NOT NULL DEFAULT 6000 CONSTRAINT policy_critical_cost_limit_check CHECK (critical_cost_limit >= urgent_cost_limit AND critical_cost_limit <= 10000),
    elevated_cost_delay_ms          double precision NOT NULL DEFAULT 2.0 CHECK (elevated_cost_delay_ms >= 0 AND elevated_cost_delay_ms <= 100),
    urgent_cost_delay_ms            double precision NOT NULL DEFAULT 1.0 CHECK (urgent_cost_delay_ms >= 0 AND urgent_cost_delay_ms <= elevated_cost_delay_ms),
    critical_cost_delay_ms          double precision NOT NULL DEFAULT 0.0 CHECK (critical_cost_delay_ms >= 0 AND critical_cost_delay_ms <= urgent_cost_delay_ms),

    xid_warning_ratio               double precision NOT NULL DEFAULT 0.70 CHECK (xid_warning_ratio > 0 AND xid_warning_ratio < 1),
    mxid_warning_ratio              double precision NOT NULL DEFAULT 0.70 CHECK (mxid_warning_ratio > 0 AND mxid_warning_ratio < 1),
    /* Absolute age caps for the emergency vacuum (RDS-style 1B early warning, ~1.1B headroom left). */
    emergency_xid_age               bigint NOT NULL DEFAULT 1000000000 CHECK (emergency_xid_age >= 100000),
    emergency_mxid_age              bigint NOT NULL DEFAULT 1000000000 CHECK (emergency_mxid_age >= 100000),
    /* Stall line = LEAST(emergency_xid_age, multiplier x freeze_max_age); must stay > 1.0. */
    emergency_stall_multiplier      double precision NOT NULL DEFAULT 1.5 CHECK (emergency_stall_multiplier > 1.0),
    /* Minimum runtime before a running anti-wraparound autovacuum may be judged stuck. */
    emergency_takeover_min_runtime_seconds integer NOT NULL DEFAULT 3600 CHECK (emergency_takeover_min_runtime_seconds >= 60),
    /* Consecutive samples with frozen pg_stat_progress_vacuum counters required for takeover. */
    emergency_takeover_stall_samples integer NOT NULL DEFAULT 5 CHECK (emergency_takeover_stall_samples >= 2),

    long_vacuum_seconds             integer NOT NULL DEFAULT 1800 CHECK (long_vacuum_seconds >= 60),
    high_delay_fraction             double precision NOT NULL DEFAULT 0.25 CHECK (high_delay_fraction >= 0 AND high_delay_fraction <= 1),
    high_load_per_cpu               double precision NOT NULL DEFAULT 1.50 CHECK (high_load_per_cpu > 0),
    low_memory_percent              double precision NOT NULL DEFAULT 15.0 CHECK (low_memory_percent > 0 AND low_memory_percent < 100),
    /* Storage guardrail: WAL MB/s above this counts as host pressure; 0 = off. */
    high_wal_mbps                   double precision NOT NULL DEFAULT 0 CHECK (high_wal_mbps >= 0),

    recommendation_cost_limit_max   integer NOT NULL DEFAULT 10000 CHECK (recommendation_cost_limit_max >= 200 AND recommendation_cost_limit_max <= 10000),
    recommendation_delay_max_ms     integer NOT NULL DEFAULT 20 CHECK (recommendation_delay_max_ms >= 0 AND recommendation_delay_max_ms <= 100),
    /* Floor for the automatic cost-delay walk-down; a lower operator value is respected. */
    recommendation_delay_min_ms     double precision NOT NULL DEFAULT 0.5 CONSTRAINT policy_recommendation_delay_min_ms_check CHECK (recommendation_delay_min_ms >= 0 AND recommendation_delay_min_ms <= recommendation_delay_max_ms),
    /* Theoretical page-rate ceiling for automatic cost raises (vacuum_cost_ceiling_mbps); 0 = no cap. */
    recommendation_max_vacuum_mbps  integer NOT NULL DEFAULT 3200 CHECK (recommendation_max_vacuum_mbps >= 0),
    /* Observed activity gain a raise must show before the next raise is allowed. */
    cost_raise_min_activity_gain_percent integer NOT NULL DEFAULT 10 CHECK (cost_raise_min_activity_gain_percent BETWEEN 0 AND 1000),
    /* 2097151 MB = MAX_KILOBYTES expressed in MB, the domain of autovacuum_work_mem. */
    recommendation_work_mem_max_mb  integer NOT NULL DEFAULT 4096 CHECK (recommendation_work_mem_max_mb >= 64 AND recommendation_work_mem_max_mb <= 2097151),
    /* Ceiling for the vacuum_buffer_usage_limit raise; also capped by shared_buffers/8. */
    recommendation_buffer_usage_limit_max_mb integer NOT NULL DEFAULT 256 CHECK (recommendation_buffer_usage_limit_max_mb >= 2 AND recommendation_buffer_usage_limit_max_mb <= 16384),
    work_mem_available_fraction     double precision NOT NULL DEFAULT 0.10 CHECK (work_mem_available_fraction > 0 AND work_mem_available_fraction <= 0.50),
    recommendation_workers_max      integer NOT NULL DEFAULT 16 CHECK (recommendation_workers_max BETWEEN 1 AND 64),
    /* autovacuum_naptime is halved per check while overdue relations wait and the pool is under-filled; decays with the cost pair. */
    manage_naptime                  boolean NOT NULL DEFAULT true,
    naptime_min_seconds             integer NOT NULL DEFAULT 5 CHECK (naptime_min_seconds >= 1),

    emergency_vacuum_enabled        boolean NOT NULL DEFAULT true,
    emergency_work_mem_min_mb       integer NOT NULL DEFAULT 128 CHECK (emergency_work_mem_min_mb >= 64),
    emergency_work_mem_max_mb       integer NOT NULL DEFAULT 2048 CHECK (emergency_work_mem_max_mb >= emergency_work_mem_min_mb AND emergency_work_mem_max_mb <= 2097151),
    emergency_cost_limit            integer NOT NULL DEFAULT 10000 CHECK (emergency_cost_limit >= 200 AND emergency_cost_limit <= 10000),
    emergency_cost_delay_ms         integer NOT NULL DEFAULT 0 CHECK (emergency_cost_delay_ms >= 0 AND emergency_cost_delay_ms <= 100),
    emergency_lock_timeout_ms       integer NOT NULL DEFAULT 5000 CHECK (emergency_lock_timeout_ms >= 1),

    history_retention_days          integer NOT NULL DEFAULT 30 CHECK (history_retention_days >= 1),
    updated_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by                      name NOT NULL DEFAULT current_user
);

INSERT INTO adaptive_autovacuum.policy(singleton) VALUES (true);

/* Name-keyed so one central row addresses a relation in any managed database (dump/restore safe). */
CREATE TABLE adaptive_autovacuum.table_policy
(
    database_name         name NOT NULL,
    schema_name           name NOT NULL,
    relation_name         name NOT NULL,
    enabled               boolean NOT NULL DEFAULT true,
    target_dead_tuple_ratio double precision,
    target_dead_tuple_min bigint,
    target_dead_tuple_max bigint,
    min_scale_factor      double precision,
    max_scale_factor      double precision,
    note                  text,
    updated_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by            name NOT NULL DEFAULT current_user,
    PRIMARY KEY (database_name, schema_name, relation_name),
    CHECK (target_dead_tuple_ratio IS NULL OR (target_dead_tuple_ratio > 0 AND target_dead_tuple_ratio <= 1)),
    CHECK (target_dead_tuple_min IS NULL OR target_dead_tuple_min >= 0),
    CHECK (target_dead_tuple_max IS NULL OR (target_dead_tuple_max >= 0 AND target_dead_tuple_max <= 2147483647)),
    CHECK (target_dead_tuple_min IS NULL OR target_dead_tuple_max IS NULL OR target_dead_tuple_max >= target_dead_tuple_min),
    CHECK (min_scale_factor IS NULL OR (min_scale_factor >= 0 AND min_scale_factor <= 100)),
    CHECK (max_scale_factor IS NULL OR (max_scale_factor >= 0 AND max_scale_factor <= 100)),
    CHECK (min_scale_factor IS NULL OR max_scale_factor IS NULL OR max_scale_factor >= min_scale_factor)
);

COMMENT ON TABLE adaptive_autovacuum.table_policy IS
'Per-relation operator overrides for any managed database, keyed by database, schema and relation name. A row whose relation no longer exists is kept (it may return after a restore); the database worker simply finds nothing to apply it to.';

/* Rows only for relations with control state (non-normal, recommendation, vacuum fingerprint); rewritten on change or hourly. */
CREATE TABLE adaptive_autovacuum.table_state
(
    database_oid          oid NOT NULL,
    relation_oid          oid NOT NULL,
    database_name         name NOT NULL,
    relation_name         text NOT NULL,
    /* open = SQL waits for the operator; applied = the reloptions match it; revert = the cost boost is no longer needed. */
    recommendation_status text CHECK (recommendation_status IN ('open', 'applied', 'revert')),
    recommended_reloptions jsonb,
    /* Values of the recommended keys before the operator applied them; a null value = the key was not set. */
    previous_reloptions   jsonb,
    recommendation_reason text,
    recommended_at        timestamptz,
    applied_at            timestamptz,
    state                 text NOT NULL DEFAULT 'normal',
    /* Saturate at their policy thresholds so a steady state produces no write. */
    consecutive_overdue   integer NOT NULL DEFAULT 0,
    consecutive_healthy   integer NOT NULL DEFAULT 0,
    /* Time of the last row write, not of the last scan. */
    last_seen_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_dead_tuples      bigint,
    last_live_tuples      bigint,
    last_trigger          double precision,
    last_backlog_ratio    double precision,
    last_inserts_since_vacuum bigint,
    last_insert_backlog_ratio double precision,
    last_xid_age          bigint,
    last_mxid_age         bigint,
    /* Previous cycle's pg_stat_progress_vacuum fingerprint; unchanged = stuck-vacuum evidence. */
    last_vacuum_pid       integer,
    last_vacuum_progress  text,
    vacuum_stalled_cycles integer NOT NULL DEFAULT 0,
    /* Previous cycle's action; decisions log (state, action) transitions only. */
    last_action           text,
    PRIMARY KEY (database_oid, relation_oid)
);

/* One row per discovered database: identity, sweep bookkeeping and the latest scan summary. */
CREATE TABLE adaptive_autovacuum.database_state
(
    database_oid          oid PRIMARY KEY,
    database_name         name NOT NULL,
    first_seen_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_scan_started_at  timestamptz,
    last_scan_completed_at timestamptz,
    scan_generation       bigint,
    scan_seconds          double precision,
    /* healthy | backlog | emergency | failed | excluded | pending */
    status                text NOT NULL DEFAULT 'pending',
    last_error            text,
    extension_installed   boolean NOT NULL DEFAULT false,
    table_count           integer,
    eligible_relations    integer,
    overdue_relations     integer,
    dead_overdue          integer,
    insert_overdue        integer,
    emergency_relations   integer,
    fleet_max_target      bigint,
    median_scale          double precision,
    median_thresh         double precision,
    median_ins_scale      double precision,
    median_ins_thresh     double precision,
    /* Maintenance debt (dead + inserted-since-vacuum tuples) and its smoothed tuples/s rate. */
    debt_tuples           bigint,
    debt_velocity         double precision,
    max_xid_age           bigint,
    max_mxid_age          bigint,
    /* Relations with an open table recommendation after the last scan. */
    recommended_relations integer,
    analyzed_relations    integer
);

/* UNLOGGED: audit history only, never read back for control; unreadable on a hot standby. */
CREATE UNLOGGED TABLE adaptive_autovacuum.decisions
(
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decided_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    generation            bigint,
    database_oid          oid,
    database_name         name,
    relid                 oid,
    relation_name         text,
    state                 text NOT NULL,
    action                text NOT NULL,
    reason                text NOT NULL,
    host_metrics          jsonb NOT NULL,
    relation_metrics      jsonb,
    proposed_reloptions   jsonb,
    applied               boolean NOT NULL DEFAULT false,
    error                 text
);

CREATE INDEX decisions_decided_at_idx
    ON adaptive_autovacuum.decisions(decided_at DESC);
CREATE INDEX decisions_relation_decided_at_idx
    ON adaptive_autovacuum.decisions(database_oid, relid, decided_at DESC);

/* UNLOGGED: advisory history only, never read back for control. */
CREATE UNLOGGED TABLE adaptive_autovacuum.global_recommendations
(
    id                              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    generation                      bigint,
    databases                       integer,
    evidence_complete               boolean,
    host_metrics                    jsonb NOT NULL,
    overdue_relations               integer NOT NULL,
    long_vacuums                    integer NOT NULL,
    delay_bound_long_vacuums        integer NOT NULL,
    repeated_index_vacuum_cycles    integer NOT NULL,
    recommended_cost_limit          integer NOT NULL,
    recommended_cost_delay_ms       double precision NOT NULL,
    recommended_autovacuum_work_mem_kb integer NOT NULL,
    recommended_buffer_usage_limit_kb integer NOT NULL,
    recommended_autovacuum_workers  integer NOT NULL,
    recommended_autovacuum_naptime_seconds integer,
    recommended_vacuum_scale_factor double precision,
    recommended_vacuum_threshold    integer,
    recommended_vacuum_max_threshold integer,
    recommended_insert_scale_factor double precision,
    recommended_insert_threshold    integer,
    recommended_analyze_scale_factor double precision,
    recommended_analyze_threshold   integer,
    /* Cluster maintenance debt (dead + inserted-since-vacuum tuples), its rate, and the trend. */
    maintenance_debt_tuples         bigint,
    maintenance_debt_velocity       double precision,
    backlog_trend                   text,
    /* Cost-weighted autovacuum-worker activity (cost units/s) with its per-operation components. */
    vacuum_activity_rate            double precision,
    vacuum_activity_detail          jsonb,
    /* Cost units/s the live cost pair allows, and the theoretical page-rate ceiling of the recommended pair. */
    cost_budget_rate                double precision,
    cost_ceiling_mbps               double precision,
    reason                          text NOT NULL
);

CREATE INDEX global_recommendations_created_at_idx
    ON adaptive_autovacuum.global_recommendations(created_at DESC);

CREATE TABLE adaptive_autovacuum.global_apply_queue
(
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    generation      bigint,
    guc_name        text NOT NULL,
    desired_value   text NOT NULL,
    old_value       text,
    reason          text,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'applied', 'failed')),
    requested_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    applied_at      timestamptz,
    error           text
);

CREATE INDEX global_apply_queue_guc_status_idx
    ON adaptive_autovacuum.global_apply_queue(guc_name, status, requested_at DESC);

COMMENT ON TABLE adaptive_autovacuum.global_apply_queue IS
'Cluster-wide setting changes decided by the global controller and applied by the controller process via ALTER SYSTEM + reload. old_value records the pre-change setting for rollback.';

CREATE TABLE adaptive_autovacuum.emergency_queue
(
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    database_oid        oid NOT NULL,
    database_name       name NOT NULL,
    relid               oid NOT NULL,
    relation_name       text NOT NULL,
    reason              text NOT NULL,
    priority            integer NOT NULL DEFAULT 100,
    status              text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
    requested_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at          timestamptz,
    finished_at         timestamptz,
    next_retry_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
    attempts            integer NOT NULL DEFAULT 0,
    worker_pid          integer,
    work_mem_mb         integer NOT NULL,
    cost_limit          integer NOT NULL,
    cost_delay_ms       integer NOT NULL,
    lock_timeout_ms     integer NOT NULL,
    is_wraparound       boolean NOT NULL DEFAULT true,
    /* Projected seconds to the read-only cutoff at enqueue time; NULL without an XID rate. */
    deadline_seconds    double precision,
    last_error          text
);

/* Claim order: shortest deadline first, unknown deadlines last, then age priority. */
CREATE INDEX emergency_queue_status_idx
    ON adaptive_autovacuum.emergency_queue(status, deadline_seconds, priority DESC, requested_at);
CREATE UNIQUE INDEX emergency_queue_one_active_per_relation_idx
    ON adaptive_autovacuum.emergency_queue(database_oid, relid)
    WHERE status IN ('pending', 'running');

/* Theoretical vacuum page rate of a cost pair: pages/s at page-hit cost times the block size. */
CREATE FUNCTION adaptive_autovacuum.vacuum_cost_ceiling_mbps(
    cost_limit integer,
    cost_delay_ms double precision,
    page_hit_cost double precision DEFAULT 1,
    block_size bigint DEFAULT 8192)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN CASE
    WHEN cost_delay_ms IS NULL OR cost_delay_ms <= 0 THEN 'infinity'::double precision
    ELSE (1000.0 / cost_delay_ms) * (cost_limit / GREATEST(page_hit_cost, 1))
         * block_size / 1048576.0
END;

COMMENT ON FUNCTION adaptive_autovacuum.vacuum_cost_ceiling_mbps(integer, double precision, double precision, bigint) IS
'Theoretical ceiling of a cost_limit / cost_delay pair if every cost unit were a page hit: (1000 / delay ms) * (limit / vacuum_cost_page_hit) * block size, in MiB/s. Not a physical bandwidth figure (misses and dirty pages cost more per page); used only to bound automatic raises. PostgreSQL defaults (200 / 2 ms) give 781.25.';

/* Cost units per second a cost pair allows: the budget observed activity is compared against. */
CREATE FUNCTION adaptive_autovacuum.cost_budget_rate(
    cost_limit integer,
    cost_delay_ms double precision)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN CASE
    WHEN cost_delay_ms IS NULL OR cost_delay_ms <= 0 THEN 'infinity'::double precision
    ELSE cost_limit * 1000.0 / cost_delay_ms
END;

/* One row of cluster controller state: generation bookkeeping and the per-sweep samples. */
CREATE TABLE adaptive_autovacuum.controller_state
(
    only_row        boolean PRIMARY KEY DEFAULT true CHECK (only_row),
    cluster_generation bigint NOT NULL DEFAULT 0,
    last_complete_generation bigint,
    last_sweep_started_at timestamptz,
    last_sweep_completed_at timestamptz,
    /* EMA of the full-sweep duration; freshness windows scale with it. */
    observed_sweep_seconds double precision,
    /* Next-XID counter (read without assigning an XID) and its rate. */
    last_xid8       bigint,
    xid_rate        double precision,
    last_sample_at  timestamptz,
    /* pg_stat_wal.wal_bytes at the previous sweep, for the high_wal_mbps guardrail. */
    last_wal_bytes  bigint,
    wal_rate_mbps   double precision,
    host_pressure   boolean NOT NULL DEFAULT false,
    storage_pressure boolean NOT NULL DEFAULT false,
    moderate_pressure boolean NOT NULL DEFAULT false,
    /* Cluster debt total and smoothed tuples/s rate as of the previous sweep. */
    last_debt_tuples bigint,
    debt_velocity   double precision,
    /* Consecutive sweeps with no overdue relation cluster-wide (drives the cost decay). */
    backlog_free_cycles integer NOT NULL DEFAULT 0,
    /* Consecutive sweeps that saw autovacuum = off (drives the repair). */
    autovacuum_off_cycles integer NOT NULL DEFAULT 0,
    /* Operator values of the cost settings before the first automatic change; the decay target. */
    baseline_settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    /* Cost-weighted autovacuum-worker activity (pg_stat_io, cumulative units) and units/s over the last interval. */
    last_vacuum_activity_units double precision,
    vacuum_activity_rate double precision,
    /* Autovacuum-worker pg_stat_io counters at the previous sweep; the activity detail differences them. */
    last_io_hits double precision,
    last_io_reads double precision,
    last_io_writes double precision,
    last_io_extends double precision,
    /* The last applied cost raise and the activity before it; the next raise must beat it. */
    last_cost_raise_at timestamptz,
    last_raise_cost_limit integer,
    last_raise_cost_delay double precision,
    activity_before_raise double precision
);
INSERT INTO adaptive_autovacuum.controller_state (only_row) VALUES (true);

CREATE FUNCTION adaptive_autovacuum._option_value(options text[], option_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT split_part(option, '=', 2)
    FROM unnest(options) AS option
    WHERE split_part(option, '=', 1) = option_name
    LIMIT 1
$$;

/* relpages when known; exact size only for unanalyzed relations with enough tuples to matter. */
CREATE FUNCTION adaptive_autovacuum._relation_bytes(
    relpages integer, live_tuples bigint, dead_tuples bigint,
    min_table_bytes bigint, block_size bigint, relid oid)
RETURNS bigint
LANGUAGE sql
VOLATILE
PARALLEL UNSAFE
AS $$
    SELECT CASE
        WHEN relpages > 0 THEN relpages::bigint * block_size
        WHEN live_tuples + dead_tuples >= min_table_bytes / block_size THEN pg_total_relation_size(relid)
        ELSE 0::bigint
    END
$$;

/* Operator-runnable ALTER TABLE text for a set of reloptions; a null value means RESET that key. */
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

/* Oldest snapshot / prepared xact / slot holding the cleanup horizon (XID only, not MXID). */
CREATE FUNCTION adaptive_autovacuum.horizon_blocker()
RETURNS TABLE (blocker_age bigint, blocker_kind text, blocker_detail text)
LANGUAGE sql
STABLE
AS $$
    SELECT b.blocker_age, b.blocker_kind, b.blocker_detail
    FROM (
        SELECT GREATEST(age(a.backend_xmin), age(a.backend_xid))::bigint AS blocker_age,
               'backend'::text AS blocker_kind,
               format('pid %s, user %s, application %s, state %s, xact_start %s',
                      a.pid, a.usename, COALESCE(a.application_name, ''),
                      a.state, a.xact_start) AS blocker_detail
        FROM pg_catalog.pg_stat_activity a
        WHERE (a.datname = pg_catalog.current_database() OR a.datname IS NULL)
          AND (a.backend_xmin IS NOT NULL OR a.backend_xid IS NOT NULL)
        UNION ALL
        SELECT age(px.transaction)::bigint,
               'prepared_transaction',
               format('gid %L, prepared %s, owner %s', px.gid, px.prepared, px.owner)
        FROM pg_catalog.pg_prepared_xacts px
        WHERE px.database = pg_catalog.current_database()
        UNION ALL
        SELECT GREATEST(age(s.xmin), age(s.catalog_xmin))::bigint,
               'replication_slot',
               format('slot %s, type %s, active %s', s.slot_name, s.slot_type, s.active)
        FROM pg_catalog.pg_replication_slots s
        WHERE s.xmin IS NOT NULL OR s.catalog_xmin IS NOT NULL
    ) b
    WHERE b.blocker_age IS NOT NULL
    ORDER BY b.blocker_age DESC
    LIMIT 1
$$;

COMMENT ON FUNCTION adaptive_autovacuum.horizon_blocker() IS
'Oldest cleanup-horizon blocker visible from this database: long snapshot/transaction, prepared transaction, or replication slot xmin. NULL row set when nothing holds an xmin.';
