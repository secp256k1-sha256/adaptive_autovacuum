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

    min_table_bytes                 bigint NOT NULL DEFAULT 67108864 CHECK (min_table_bytes >= 0),
    excluded_schemas                text[] NOT NULL DEFAULT ARRAY['pg_catalog', 'information_schema', 'pg_toast', 'adaptive_autovacuum'],

    target_dead_tuple_ratio         double precision NOT NULL DEFAULT 0.01 CHECK (target_dead_tuple_ratio > 0 AND target_dead_tuple_ratio <= 1),
    target_dead_tuple_min           bigint NOT NULL DEFAULT 5000 CHECK (target_dead_tuple_min >= 0),
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
    overdue_cycles_before_change    integer NOT NULL DEFAULT 2 CHECK (overdue_cycles_before_change >= 1),
    healthy_cycles_before_restore   integer NOT NULL DEFAULT 6 CHECK (healthy_cycles_before_restore >= 1),
    change_cooldown_seconds         integer NOT NULL DEFAULT 1800 CHECK (change_cooldown_seconds >= 0),
    lock_timeout_ms                 integer NOT NULL DEFAULT 250 CHECK (lock_timeout_ms >= 1),
    max_changes_per_cycle           integer NOT NULL DEFAULT 5 CHECK (max_changes_per_cycle >= 0),

    /* Never-analyzed tables leave the planner guessing; analyze the largest within a budget. */
    analyze_missing_stats           boolean NOT NULL DEFAULT true,
    analyze_missing_stats_budget_ms integer NOT NULL DEFAULT 10000 CHECK (analyze_missing_stats_budget_ms >= 0),

    /* autovacuum=off is repaired after this many consecutive checks; it is never turned off. */
    repair_disabled_autovacuum      boolean NOT NULL DEFAULT true,
    repair_disabled_autovacuum_cycles integer NOT NULL DEFAULT 10 CHECK (repair_disabled_autovacuum_cycles >= 1),

    /* Debt trend deadband: growth per check above it = growing, below its negative = shrinking. */
    backlog_trend_deadband          double precision NOT NULL DEFAULT 0.05 CHECK (backlog_trend_deadband > 0 AND backlog_trend_deadband < 1),
    /* Backlog-free checks in a row before one cost step back toward the baseline. */
    recovery_cycles_before_decay    integer NOT NULL DEFAULT 10 CHECK (recovery_cycles_before_decay >= 1),
    /* A shrinking backlog only holds the raises if it is projected to clear within this time. */
    max_backlog_drain_seconds       integer NOT NULL DEFAULT 180 CHECK (max_backlog_drain_seconds >= 1),

    manage_table_costs              boolean NOT NULL DEFAULT false,
    max_boosted_relations           integer NOT NULL DEFAULT 2 CHECK (max_boosted_relations >= 0),
    /* Caps = documented maxima of (auto)vacuum_cost_limit / _cost_delay. */
    elevated_cost_limit             integer NOT NULL DEFAULT 1000 CHECK (elevated_cost_limit >= 200 AND elevated_cost_limit <= 10000),
    urgent_cost_limit               integer NOT NULL DEFAULT 3000 CONSTRAINT policy_urgent_cost_limit_check CHECK (urgent_cost_limit >= elevated_cost_limit AND urgent_cost_limit <= 10000),
    critical_cost_limit             integer NOT NULL DEFAULT 6000 CONSTRAINT policy_critical_cost_limit_check CHECK (critical_cost_limit >= urgent_cost_limit AND critical_cost_limit <= 10000),
    elevated_cost_delay_ms          double precision NOT NULL DEFAULT 2.0 CHECK (elevated_cost_delay_ms >= 0 AND elevated_cost_delay_ms <= 100),
    urgent_cost_delay_ms            double precision NOT NULL DEFAULT 1.0 CHECK (urgent_cost_delay_ms >= 0 AND urgent_cost_delay_ms <= elevated_cost_delay_ms),
    critical_cost_delay_ms          double precision NOT NULL DEFAULT 0.0 CHECK (critical_cost_delay_ms >= 0 AND critical_cost_delay_ms <= urgent_cost_delay_ms),
    boost_ramp_factor               double precision NOT NULL DEFAULT 2.0 CHECK (boost_ramp_factor >= 1.1 AND boost_ramp_factor <= 10),
    boost_total_cost_limit_budget   integer NOT NULL DEFAULT 10000 CHECK (boost_total_cost_limit_budget >= 1000),

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

/* Rows only for relations with control state; rewritten on change or hourly, never per cycle. */
CREATE TABLE adaptive_autovacuum.table_state
(
    database_oid          oid NOT NULL,
    relation_oid          oid NOT NULL,
    database_name         name NOT NULL,
    relation_name         text NOT NULL,
    original_reloptions   text[],
    original_captured     boolean NOT NULL DEFAULT false,
    managed_values        jsonb NOT NULL DEFAULT '{}'::jsonb,
    ownership_conflict    boolean NOT NULL DEFAULT false,
    state                 text NOT NULL DEFAULT 'normal',
    /* Saturate at their policy thresholds so a steady state produces no write. */
    consecutive_overdue   integer NOT NULL DEFAULT 0,
    consecutive_healthy   integer NOT NULL DEFAULT 0,
    /* Time of the last row write, not of the last scan. */
    last_seen_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_change_at        timestamptz,
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
    last_error            text,
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
    changes_applied       integer,
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

CREATE FUNCTION adaptive_autovacuum._managed_values_match(
    options text[], managed_values jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT NOT EXISTS
    (
        SELECT 1
        FROM jsonb_each_text(COALESCE(managed_values, '{}'::jsonb)) AS managed(option_name, option_value)
        WHERE CASE
            WHEN managed.option_name IN (
                'autovacuum_vacuum_threshold',
                'autovacuum_vacuum_scale_factor',
                'autovacuum_vacuum_max_threshold',
                'autovacuum_vacuum_insert_threshold',
                'autovacuum_vacuum_insert_scale_factor',
                'autovacuum_vacuum_cost_limit',
                'autovacuum_vacuum_cost_delay'
            )
            THEN adaptive_autovacuum._option_value(options, managed.option_name)::numeric
                 IS DISTINCT FROM managed.option_value::numeric
            ELSE adaptive_autovacuum._option_value(options, managed.option_name)
                 IS DISTINCT FROM managed.option_value
        END
    )
$$;

/* Operator tool for the control database; the database program carries the same logic inline. */
CREATE FUNCTION adaptive_autovacuum._reconcile_relation_options(
    relation_name text,
    original_options text[],
    previous_managed jsonb,
    desired_managed jsonb,
    lock_timeout_ms integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    option_name text;
    option_value text;
    original_value text;
    reset_names text[] := ARRAY[]::text[];
    set_parts text[] := ARRAY[]::text[];
BEGIN
    previous_managed := COALESCE(previous_managed, '{}'::jsonb);
    desired_managed := COALESCE(desired_managed, '{}'::jsonb);

    PERFORM set_config('lock_timeout', lock_timeout_ms::text || 'ms', true);

    FOR option_name IN
        SELECT key
        FROM (
            SELECT jsonb_object_keys(previous_managed) AS key
            UNION
            SELECT jsonb_object_keys(desired_managed) AS key
        ) keys
        ORDER BY key
    LOOP
        IF option_name NOT IN (
            'autovacuum_vacuum_threshold',
            'autovacuum_vacuum_scale_factor',
            'autovacuum_vacuum_max_threshold',
            'autovacuum_vacuum_insert_threshold',
            'autovacuum_vacuum_insert_scale_factor',
            'autovacuum_vacuum_cost_limit',
            'autovacuum_vacuum_cost_delay'
        ) THEN
            RAISE EXCEPTION 'unsupported managed reloption: %', option_name;
        END IF;

        IF desired_managed ? option_name THEN
            option_value := desired_managed ->> option_name;
            IF option_value !~ '^-?[0-9]+([.][0-9]+)?$' THEN
                RAISE EXCEPTION 'invalid numeric reloption value for %: %', option_name, option_value;
            END IF;
            set_parts := array_append(set_parts, format('%I = %s', option_name, option_value));
        ELSE
            original_value := adaptive_autovacuum._option_value(original_options, option_name);
            IF original_value IS NULL THEN
                reset_names := array_append(reset_names, option_name);
            ELSE
                set_parts := array_append(set_parts, format('%I = %s', option_name, original_value));
            END IF;
        END IF;
    END LOOP;

    IF cardinality(reset_names) > 0 THEN
        EXECUTE format('ALTER TABLE %s RESET (%s)',
                       relation_name,
                       (SELECT string_agg(format('%I', value), ', ')
                        FROM unnest(reset_names) AS value));
    END IF;

    IF cardinality(set_parts) > 0 THEN
        EXECUTE format('ALTER TABLE %s SET (%s)',
                       relation_name,
                       array_to_string(set_parts, ', '));
    END IF;
END
$$;

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

/* The per-database program: run by the database worker as an anonymous block in the managed database. */
/* It needs no extension objects there: input arrives in adaptive_autovacuum.worker_input, output leaves in worker_output. */
CREATE FUNCTION adaptive_autovacuum._database_program()
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN $aav_body$
DECLARE
    input jsonb := pg_catalog.current_setting('adaptive_autovacuum.worker_input')::jsonb;
    p record;
    r record;
    scan_started_at timestamptz := clock_timestamp();

    server_vnum integer := current_setting('server_version_num')::integer;
    block_size bigint := current_setting('block_size')::bigint;

    host_json jsonb;
    host_pressure boolean;
    moderate_pressure boolean;
    host_metrics_available boolean;
    host_mem_available_bytes bigint;
    xid_rate double precision;

    autovacuum_enabled_global boolean;
    freeze_max_age bigint;
    multixact_freeze_max_age bigint;
    current_vacuum_threshold double precision;
    current_vacuum_scale_factor double precision;
    current_vacuum_max_threshold double precision;
    current_insert_threshold double precision;
    current_insert_scale_factor double precision;

    table_count integer := 0;
    scanned_relation_count integer := 0;
    fleet_max_target bigint := 0;
    total_debt_tuples bigint := 0;
    db_max_xid_age bigint := 0;
    db_max_mxid_age bigint := 0;
    dead_overdue_count integer := 0;
    overdue_scale_factors double precision[] := '{}';
    overdue_thresholds integer[] := '{}';
    insert_overdue_count integer := 0;
    overdue_insert_scale_factors double precision[] := '{}';
    overdue_insert_thresholds integer[] := '{}';
    local_median_scale double precision;
    local_median_thresh double precision;
    local_median_ins_scale double precision;
    local_median_ins_thresh double precision;
    overdue_relation_count integer := 0;
    emergency_relation_count integer := 0;
    critical_seen boolean := false;
    analyze_budget_ms integer;
    analyze_started_at timestamptz;
    analyze_count integer := 0;

    vacuum_trigger double precision;
    backlog_ratio double precision;
    insert_ratio double precision;
    pressure_ratio double precision;
    xid_ratio double precision;
    mxid_ratio double precision;
    horizon_age bigint;
    horizon_kind text;
    horizon_detail text;
    xid_horizon_blocked boolean;
    stall_xid_age bigint;
    stall_mxid_age bigint;
    av_wraparound_running boolean;
    av_elapsed_seconds double precision;
    seconds_until_readonly double precision;
    cur_vacuum_progress text;
    vacuum_stalled_cycles integer;
    emergency_due boolean;
    emergency_takeover boolean;
    emergency_gate jsonb;
    relation_state text;
    reason text;
    overdue_cycles integer;
    healthy_cycles integer;

    /* Previous table_state row (before-image in r.prev_*, mutable copy here). */
    pv_original_reloptions text[];
    pv_original_captured boolean;
    pv_managed_values jsonb;
    pv_ownership_conflict boolean;
    pv_state text;
    pv_consecutive_overdue integer;
    pv_consecutive_healthy integer;
    pv_last_change_at timestamptz;
    pv_last_vacuum_pid integer;
    pv_last_vacuum_progress text;
    pv_vacuum_stalled_cycles integer;
    pv_last_action text;

    effective_target_ratio double precision;
    effective_target_min bigint;
    effective_target_max bigint;
    effective_scale_min double precision;
    effective_scale_max double precision;
    target_dead_tuples bigint;
    desired_threshold integer;
    desired_scale_factor double precision;
    desired_max_threshold integer;
    target_inserts bigint;
    desired_insert_threshold integer;
    desired_insert_scale double precision;
    desired_values jsonb;
    relation_json jsonb;

    change_count integer := 0;
    cost_boost_count integer := 0;
    wants_cost_boost boolean;
    has_existing_cost_boost boolean;
    desired_cost_limit integer;
    desired_cost_delay double precision;
    tier_cost_limit integer;
    tier_cost_delay double precision;
    prev_boost integer;
    budget_headroom integer;
    cost_budget_used integer := 0;
    cooldown_ok boolean;
    current_matches_managed boolean;
    should_apply boolean;
    applied boolean;
    action_name text;
    action_error text;
    apply_kind text;
    apply_desired jsonb;
    rec_option_name text;
    rec_option_value text;
    rec_original_value text;
    rec_reset_names text[];
    rec_set_parts text[];
    state_needed boolean;
    new_last_change_at timestamptz;
    emergency_work_mem_mb integer;

    out_state jsonb := '[]'::jsonb;
    out_state_delete jsonb := '[]'::jsonb;
    out_decisions jsonb := '[]'::jsonb;
    out_emergency jsonb := '[]'::jsonb;
    extension_installed boolean;
BEGIN
    SELECT * INTO p
    FROM jsonb_to_record(input -> 'policy') AS x(
        enabled boolean, dry_run boolean, manage_global_settings boolean,
        min_table_bytes bigint, excluded_schemas text[],
        target_dead_tuple_ratio double precision, target_dead_tuple_min bigint, target_dead_tuple_max bigint,
        target_insert_ratio double precision, target_insert_min bigint, target_insert_max bigint,
        threshold_floor integer, min_scale_factor double precision, max_scale_factor double precision,
        backlog_elevated_ratio double precision, backlog_urgent_ratio double precision, backlog_critical_ratio double precision,
        overdue_cycles_before_change integer, healthy_cycles_before_restore integer,
        change_cooldown_seconds integer, lock_timeout_ms integer, max_changes_per_cycle integer,
        analyze_missing_stats boolean, analyze_missing_stats_budget_ms integer,
        manage_table_costs boolean, max_boosted_relations integer,
        elevated_cost_limit integer, urgent_cost_limit integer, critical_cost_limit integer,
        elevated_cost_delay_ms double precision, urgent_cost_delay_ms double precision, critical_cost_delay_ms double precision,
        boost_ramp_factor double precision, boost_total_cost_limit_budget integer,
        xid_warning_ratio double precision, mxid_warning_ratio double precision,
        emergency_xid_age bigint, emergency_mxid_age bigint, emergency_stall_multiplier double precision,
        emergency_takeover_min_runtime_seconds integer, emergency_takeover_stall_samples integer,
        high_load_per_cpu double precision, low_memory_percent double precision, high_wal_mbps double precision,
        work_mem_available_fraction double precision,
        emergency_vacuum_enabled boolean, emergency_work_mem_min_mb integer, emergency_work_mem_max_mb integer,
        emergency_cost_limit integer, emergency_cost_delay_ms integer, emergency_lock_timeout_ms integer);

    extension_installed := EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = 'adaptive_autovacuum');

    host_json := input -> 'host';
    host_pressure := COALESCE((host_json ->> 'pressure')::boolean, false);
    moderate_pressure := COALESCE((host_json ->> 'moderate_pressure')::boolean, false);
    host_metrics_available := COALESCE((host_json ->> 'memory_metrics_available')::boolean, false);
    host_mem_available_bytes := COALESCE((host_json ->> 'mem_available_bytes')::bigint, 0);
    xid_rate := (input -> 'cluster' ->> 'xid_rate')::double precision;
    /* Cost boosts held in the other databases count against the cluster-wide budget. */
    cost_boost_count := COALESCE((input -> 'cluster' ->> 'boosted_relations_elsewhere')::integer, 0);
    cost_budget_used := COALESCE((input -> 'cluster' ->> 'boost_budget_used_elsewhere')::integer, 0);

    SELECT setting::boolean INTO autovacuum_enabled_global
    FROM pg_settings WHERE name = 'autovacuum';
    SELECT setting::bigint INTO freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    SELECT setting::bigint INTO multixact_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_multixact_freeze_max_age';
    SELECT setting::double precision INTO current_vacuum_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold';
    SELECT setting::double precision INTO current_vacuum_scale_factor
    FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor';
    SELECT setting::double precision INTO current_vacuum_max_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_max_threshold';
    SELECT setting::double precision INTO current_insert_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_threshold';
    SELECT setting::double precision INTO current_insert_scale_factor
    FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_scale_factor';

    /* Oldest cleanup-horizon blocker visible from this database, fetched once per cycle. */
    SELECT b.blocker_age, b.blocker_kind, b.blocker_detail
    INTO horizon_age, horizon_kind, horizon_detail
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
    LIMIT 1;

    /* This database's own cost boosts, from the previous state rows handed in. */
    SELECT cost_boost_count + count(*),
           cost_budget_used + COALESCE(sum((ts.managed_values ->> 'autovacuum_vacuum_cost_limit')::numeric), 0)::integer
    INTO cost_boost_count, cost_budget_used
    FROM jsonb_to_recordset(COALESCE(input -> 'table_state', '[]'::jsonb))
         AS ts(managed_values jsonb, ownership_conflict boolean)
    WHERE ts.managed_values ? 'autovacuum_vacuum_cost_limit'
      AND NOT ts.ownership_conflict;

    /* Fleet aggregates over every eligible relation; the loop below only sees the interesting ones. */
    WITH tpol AS MATERIALIZED (
        SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
               AS x(schema_name name, relation_name name, enabled boolean,
                    target_dead_tuple_ratio double precision, target_dead_tuple_min bigint,
                    target_dead_tuple_max bigint, min_scale_factor double precision,
                    max_scale_factor double precision)
    ),
    rel AS (
        SELECT c.oid, c.reltuples, c.relkind, n.nspname,
               COALESCE(tp.enabled, true) AS tp_enabled,
               tp.target_dead_tuple_ratio AS tp_ratio, tp.target_dead_tuple_min AS tp_min,
               tp.target_dead_tuple_max AS tp_max,
               GREATEST(age(c.relfrozenxid), COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
               GREATEST(mxid_age(c.relminmxid), COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
               pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples,
               pg_stat_get_dead_tuples(c.oid)::bigint AS dead_tuples,
               CASE
                   WHEN c.relpages > 0 THEN c.relpages::bigint * block_size
                   WHEN pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)
                        >= p.min_table_bytes / block_size THEN pg_total_relation_size(c.oid)
                   ELSE 0::bigint
               END AS total_bytes
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
        LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
        WHERE c.relkind IN ('r', 'm')
          AND c.relpersistence <> 't'
    )
    SELECT count(*) FILTER (WHERE rel.relkind = 'r' AND rel.nspname NOT IN ('pg_catalog', 'information_schema')),
           count(*) FILTER (WHERE rel.relkind = 'r' AND NOT (rel.nspname = ANY (p.excluded_schemas))
                                  AND rel.tp_enabled AND rel.total_bytes >= p.min_table_bytes),
           COALESCE(max(LEAST(COALESCE(rel.tp_max, p.target_dead_tuple_max),
                              GREATEST(COALESCE(rel.tp_min, p.target_dead_tuple_min),
                                       ceil(GREATEST(rel.live_tuples::double precision,
                                                     rel.reltuples::double precision, 1)
                                            * COALESCE(rel.tp_ratio, p.target_dead_tuple_ratio))::bigint)))
                    FILTER (WHERE rel.relkind = 'r' AND NOT (rel.nspname = ANY (p.excluded_schemas))
                                  AND rel.tp_enabled AND rel.total_bytes >= p.min_table_bytes), 0),
           COALESCE(sum(rel.dead_tuples + pg_stat_get_ins_since_vacuum(rel.oid)::bigint)
                    FILTER (WHERE rel.relkind = 'r' AND NOT (rel.nspname = ANY (p.excluded_schemas))
                                  AND rel.tp_enabled AND rel.total_bytes >= p.min_table_bytes), 0),
           COALESCE(max(rel.xid_age), 0),
           COALESCE(max(rel.mxid_age), 0)
    INTO table_count, scanned_relation_count, fleet_max_target, total_debt_tuples,
         db_max_xid_age, db_max_mxid_age
    FROM rel;

    FOR r IN
        WITH tpol AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
                   AS x(schema_name name, relation_name name, enabled boolean,
                        target_dead_tuple_ratio double precision, target_dead_tuple_min bigint,
                        target_dead_tuple_max bigint, min_scale_factor double precision,
                        max_scale_factor double precision)
        ),
        prev_state AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_state', '[]'::jsonb))
                   AS x(relation_oid oid, relation_name text, original_reloptions text[],
                        original_captured boolean, managed_values jsonb, ownership_conflict boolean,
                        state text, consecutive_overdue integer, consecutive_healthy integer,
                        last_seen_at timestamptz, last_change_at timestamptz,
                        last_vacuum_pid integer, last_vacuum_progress text,
                        vacuum_stalled_cycles integer, last_error text, last_action text)
        ),
        active_vacuum AS
        (
            SELECT
                pv.relid,
                pv.pid AS vacuum_pid,
                pv.phase,
                pv.heap_blks_total,
                pv.heap_blks_scanned,
                pv.heap_blks_vacuumed,
                pv.indexes_processed,
                pv.index_vacuum_count,
                pv.max_dead_tuple_bytes,
                pv.dead_tuple_bytes,
                /* PG18+ column; NULL on PG17 via the jsonb detour. */
                ((to_jsonb(pv) ->> 'delay_time'))::double precision AS delay_time,
                clock_timestamp() - a.query_start AS vacuum_elapsed,
                a.query LIKE '%(to prevent wraparound)' AS antiwraparound,
                a.backend_type = 'autovacuum worker' AS is_autovacuum
            FROM pg_stat_progress_vacuum pv
            JOIN pg_stat_activity a ON a.pid = pv.pid
            WHERE pv.datid = (SELECT d.oid
                              FROM pg_catalog.pg_database d
                              WHERE d.datname = pg_catalog.current_database())
        ),
        cand AS
        (
        SELECT
            c.oid AS relid,
            format('%I.%I', n.nspname, c.relname) AS fqname,
            n.nspname,
            c.relname,
            c.reloptions,
            c.reltuples::double precision AS reltuples,
            sz.total_bytes,
            pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples,
            pg_stat_get_dead_tuples(c.oid)::bigint AS dead_tuples,
            /* TOAST has its own relfrozenxid; the older one drives wraparound. */
            GREATEST(age(c.relfrozenxid),
                     COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
            GREATEST(mxid_age(c.relminmxid),
                     COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
            autovacuum_enabled_global
                AND COALESCE(opt.ro_autovacuum_enabled::boolean, true)
                AS normal_autovacuum_enabled,
            CASE
                WHEN opt.ro_freeze_max_age IS NULL OR opt.ro_freeze_max_age::bigint < 0
                THEN freeze_max_age
                ELSE LEAST(freeze_max_age, opt.ro_freeze_max_age::bigint)
            END AS effective_xid_freeze_max_age,
            CASE
                WHEN opt.ro_multixact_freeze_max_age IS NULL OR opt.ro_multixact_freeze_max_age::bigint < 0
                THEN multixact_freeze_max_age
                ELSE LEAST(multixact_freeze_max_age, opt.ro_multixact_freeze_max_age::bigint)
            END AS effective_mxid_freeze_max_age,
            COALESCE(opt.ro_vacuum_threshold::double precision,
                     current_vacuum_threshold) AS vacuum_threshold,
            COALESCE(opt.ro_vacuum_scale_factor::double precision,
                     current_vacuum_scale_factor) AS vacuum_scale_factor,
            COALESCE(opt.ro_vacuum_max_threshold::double precision,
                     current_vacuum_max_threshold) AS vacuum_max_threshold,
            pg_stat_get_ins_since_vacuum(c.oid)::bigint AS inserts_since_vacuum,
            COALESCE(opt.ro_insert_threshold::double precision,
                     current_insert_threshold) AS insert_threshold,
            COALESCE(opt.ro_insert_scale_factor::double precision,
                     current_insert_scale_factor) AS insert_scale_factor,
            /* PG18 scales the insert trigger by the unfrozen page share (relallfrozen); 1.0 on PG17. */
            CASE
                WHEN c.relpages > 0
                 AND COALESCE(((to_jsonb(c) ->> 'relallfrozen'))::bigint, 0) > 0
                THEN GREATEST(0.0,
                              1.0 - LEAST(((to_jsonb(c) ->> 'relallfrozen'))::bigint,
                                          c.relpages)::double precision
                                    / c.relpages)
                ELSE 1.0
            END AS insert_pcnt_unfrozen,
            av.vacuum_pid,
            av.phase,
            av.heap_blks_total,
            av.heap_blks_scanned,
            av.heap_blks_vacuumed,
            av.indexes_processed,
            av.index_vacuum_count,
            av.max_dead_tuple_bytes,
            av.dead_tuple_bytes,
            av.delay_time,
            av.vacuum_elapsed,
            av.antiwraparound,
            av.is_autovacuum,
            tp.target_dead_tuple_ratio AS table_target_ratio,
            tp.target_dead_tuple_min AS table_target_min,
            tp.target_dead_tuple_max AS table_target_max,
            tp.min_scale_factor AS table_scale_min,
            tp.max_scale_factor AS table_scale_max,
            /* Previous state joined once here; NULL = never persisted. */
            rs.relation_oid IS NOT NULL AS state_exists,
            rs.relation_name AS prev_relation_name,
            rs.original_reloptions AS prev_original_reloptions,
            rs.original_captured AS prev_original_captured,
            rs.managed_values AS prev_managed_values,
            rs.ownership_conflict AS prev_ownership_conflict,
            rs.state AS prev_state,
            rs.consecutive_overdue AS prev_consecutive_overdue,
            rs.consecutive_healthy AS prev_consecutive_healthy,
            rs.last_seen_at AS prev_last_seen_at,
            rs.last_change_at AS prev_last_change_at,
            rs.last_vacuum_pid AS prev_last_vacuum_pid,
            rs.last_vacuum_progress AS prev_last_vacuum_progress,
            rs.vacuum_stalled_cycles AS prev_vacuum_stalled_cycles,
            rs.last_error AS prev_last_error,
            rs.last_action AS prev_last_action
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
        LEFT JOIN prev_state rs ON rs.relation_oid = c.oid
        CROSS JOIN LATERAL (
            /* Every reloption the policy reads, parsed in one pass per relation. */
            SELECT
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_enabled') AS ro_autovacuum_enabled,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_freeze_max_age') AS ro_freeze_max_age,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_multixact_freeze_max_age') AS ro_multixact_freeze_max_age,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_threshold') AS ro_vacuum_threshold,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_scale_factor') AS ro_vacuum_scale_factor,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_max_threshold') AS ro_vacuum_max_threshold,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_insert_threshold') AS ro_insert_threshold,
                max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_vacuum_insert_scale_factor') AS ro_insert_scale_factor
            FROM unnest(c.reloptions) AS o
        ) opt
        CROSS JOIN LATERAL (
            /* relpages avoids per-relation locks; exact size only for big unanalyzed relations. */
            SELECT CASE
                       WHEN c.relpages > 0 THEN c.relpages::bigint * block_size
                       WHEN pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)
                            >= p.min_table_bytes / block_size THEN pg_total_relation_size(c.oid)
                       ELSE 0::bigint
                   END AS total_bytes
        ) sz
        LEFT JOIN active_vacuum av ON av.relid = c.oid
        LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
        WHERE c.relkind = 'r'
          AND c.relpersistence <> 't'
          AND NOT (n.nspname = ANY (p.excluded_schemas))
          AND COALESCE(tp.enabled, true)
          AND sz.total_bytes >= p.min_table_bytes
        ),
        scored AS
        (
        /* The loop body's pressure formulas, computed once per relation for filter and order. */
        SELECT cand.*,
               cand.dead_tuples / GREATEST(1,
                   CASE WHEN cand.vacuum_max_threshold < 0
                        THEN cand.vacuum_threshold
                             + cand.vacuum_scale_factor * GREATEST(cand.reltuples, 0)
                        ELSE LEAST(cand.vacuum_max_threshold,
                                   cand.vacuum_threshold
                                   + cand.vacuum_scale_factor * GREATEST(cand.reltuples, 0))
                   END) AS pre_backlog_ratio,
               CASE WHEN cand.insert_threshold IS NULL OR cand.insert_threshold < 0 THEN 0
                    ELSE cand.inserts_since_vacuum / GREATEST(1,
                             cand.insert_threshold
                             + cand.insert_scale_factor * GREATEST(cand.reltuples, 0)
                               * cand.insert_pcnt_unfrozen)
               END AS pre_insert_ratio,
               cand.xid_age / NULLIF(cand.effective_xid_freeze_max_age, 0)::double precision AS pre_xid_ratio,
               cand.mxid_age / NULLIF(cand.effective_mxid_freeze_max_age, 0)::double precision AS pre_mxid_ratio
        FROM cand
        )
        /* Pre-filter: only relations that can be non-normal, carry state, or have a vacuum running. */
        SELECT *
        FROM scored
        WHERE scored.state_exists
           OR scored.vacuum_pid IS NOT NULL
           OR scored.pre_backlog_ratio >= p.backlog_elevated_ratio * 0.5
           OR scored.pre_insert_ratio >= p.backlog_elevated_ratio * 0.5
           OR scored.pre_xid_ratio >= p.xid_warning_ratio * 0.5
           OR scored.pre_mxid_ratio >= p.mxid_warning_ratio * 0.5
        ORDER BY GREATEST(COALESCE(scored.pre_xid_ratio, 0),
                          COALESCE(scored.pre_mxid_ratio, 0),
                          scored.pre_backlog_ratio,
                          scored.pre_insert_ratio) DESC
    LOOP
        /* PG17: vacuum_max_threshold is NULL, so this degrades to the uncapped formula. */
        IF r.vacuum_max_threshold < 0 THEN
            vacuum_trigger := r.vacuum_threshold
                              + r.vacuum_scale_factor * GREATEST(r.reltuples, 0);
        ELSE
            vacuum_trigger := LEAST(r.vacuum_max_threshold,
                                    r.vacuum_threshold
                                    + r.vacuum_scale_factor * GREATEST(r.reltuples, 0));
        END IF;

        vacuum_trigger := GREATEST(vacuum_trigger, 1);
        backlog_ratio := r.dead_tuples / vacuum_trigger;

        /* Negative effective insert threshold = insert vacuums disabled for this relation. */
        IF r.insert_threshold IS NULL OR r.insert_threshold < 0 THEN
            insert_ratio := 0;
        ELSE
            insert_ratio := r.inserts_since_vacuum /
                            GREATEST(1, r.insert_threshold
                                        + r.insert_scale_factor
                                          * GREATEST(r.reltuples, 0)
                                          * r.insert_pcnt_unfrozen);
        END IF;
        pressure_ratio := GREATEST(backlog_ratio, insert_ratio);
        xid_ratio := r.xid_age::double precision / NULLIF(r.effective_xid_freeze_max_age, 0);
        mxid_ratio := r.mxid_age::double precision / NULLIF(r.effective_mxid_freeze_max_age, 0);

        /* Emergency = built-in anti-wraparound autovacuum never started, or running with zero progress. */
        stall_xid_age := LEAST(p.emergency_xid_age,
                               ceil(p.emergency_stall_multiplier
                                    * COALESCE(NULLIF(r.effective_xid_freeze_max_age, 0),
                                               freeze_max_age))::bigint);
        stall_mxid_age := LEAST(p.emergency_mxid_age,
                                ceil(p.emergency_stall_multiplier
                                     * COALESCE(NULLIF(r.effective_mxid_freeze_max_age, 0),
                                                multixact_freeze_max_age))::bigint);

        /* Any autovacuum worker counts (the wraparound tag is not required); manual vacuums never. */
        av_wraparound_running := r.vacuum_pid IS NOT NULL
                                 AND COALESCE(r.is_autovacuum, false);
        av_elapsed_seconds := extract(epoch FROM COALESCE(r.vacuum_elapsed, interval '0'));

        seconds_until_readonly := NULL;
        IF xid_rate IS NOT NULL AND xid_rate > 0 THEN
            seconds_until_readonly :=
                GREATEST(2147483648 - 3000000 - r.xid_age, 0)::double precision / xid_rate;
        END IF;

        /* r.prev_* is the before-image for the write-on-change test; pv_* is mutated this cycle. */
        pv_original_reloptions := r.prev_original_reloptions;
        pv_original_captured := COALESCE(r.prev_original_captured, false);
        pv_managed_values := COALESCE(r.prev_managed_values, '{}'::jsonb);
        pv_ownership_conflict := COALESCE(r.prev_ownership_conflict, false);
        pv_state := COALESCE(r.prev_state, 'normal');
        pv_consecutive_overdue := COALESCE(r.prev_consecutive_overdue, 0);
        pv_consecutive_healthy := COALESCE(r.prev_consecutive_healthy, 0);
        pv_last_change_at := r.prev_last_change_at;
        pv_last_vacuum_pid := r.prev_last_vacuum_pid;
        pv_last_vacuum_progress := r.prev_last_vacuum_progress;
        pv_vacuum_stalled_cycles := COALESCE(r.prev_vacuum_stalled_cycles, 0);
        pv_last_action := r.prev_last_action;

        /* Progress fingerprint; unchanged across samples of the same backend = stuck. */
        IF r.vacuum_pid IS NOT NULL THEN
            cur_vacuum_progress := format('%s|%s|%s|%s|%s|%s|%s',
                                          COALESCE(r.phase, '?'),
                                          COALESCE(r.heap_blks_total, -1),
                                          COALESCE(r.heap_blks_scanned, -1),
                                          COALESCE(r.heap_blks_vacuumed, -1),
                                          COALESCE(r.indexes_processed, -1),
                                          COALESCE(r.index_vacuum_count, -1),
                                          COALESCE(r.dead_tuple_bytes, -1));
            IF pv_last_vacuum_pid IS NOT DISTINCT FROM r.vacuum_pid
               AND pv_last_vacuum_progress IS NOT DISTINCT FROM cur_vacuum_progress THEN
                vacuum_stalled_cycles := pv_vacuum_stalled_cycles + 1;
            ELSE
                vacuum_stalled_cycles := 0;
            END IF;
        ELSE
            cur_vacuum_progress := NULL;
            vacuum_stalled_cycles := 0;
        END IF;

        /* Horizon past the stall line: no vacuum can help, report the blocker instead (XID paths only). */
        xid_horizon_blocked := horizon_age IS NOT NULL
                               AND horizon_age >= stall_xid_age;

        /* Takeover needs stall-line age + minimum runtime + N frozen samples; age alone never cancels. */
        emergency_takeover := av_wraparound_running
            AND av_elapsed_seconds >= p.emergency_takeover_min_runtime_seconds
            AND vacuum_stalled_cycles >= p.emergency_takeover_stall_samples
            AND (r.mxid_age >= stall_mxid_age
                 OR (NOT xid_horizon_blocked
                     AND r.xid_age >= stall_xid_age));

        emergency_due := emergency_takeover
            OR (r.vacuum_pid IS NULL
                AND (r.mxid_age >= stall_mxid_age
                     OR (NOT xid_horizon_blocked
                         AND r.xid_age >= stall_xid_age)));

        IF emergency_due THEN
            relation_state := 'wraparound_critical';
            critical_seen := true;
            emergency_relation_count := emergency_relation_count + 1;
            IF emergency_takeover THEN
                reason := format('Anti-wraparound autovacuum (pid %s) has been running %s s on this table and has shown zero observable progress for %s consecutive checks (frozen at phase %s, heap %s/%s blocks, %s index pass(es)) while the age (%s) is past the stall line (%s, XID headroom %s s); taking over with the index-skipping profile.',
                                 r.vacuum_pid, round(av_elapsed_seconds),
                                 vacuum_stalled_cycles,
                                 COALESCE(r.phase, '?'),
                                 COALESCE(r.heap_blks_scanned, 0), COALESCE(r.heap_blks_total, 0),
                                 COALESCE(r.index_vacuum_count, 0),
                                 r.xid_age, stall_xid_age,
                                 COALESCE(round(seconds_until_readonly)::text, 'n/a'));
            ELSE
                reason := format('No anti-wraparound autovacuum has started on this table although its age (%s XIDs / %s MXIDs) is past the stall line (%s/%s = %s x freeze_max_age, capped at the absolute limit %s/%s); the built-in mechanism is not responding.',
                                 r.xid_age, r.mxid_age, stall_xid_age, stall_mxid_age,
                                 trim(trailing '.' from to_char(p.emergency_stall_multiplier, 'FM990.99')),
                                 p.emergency_xid_age, p.emergency_mxid_age);
            END IF;
        ELSIF xid_horizon_blocked AND r.xid_age >= stall_xid_age THEN
            relation_state := 'horizon_blocked';
            reason := format('XID age %s is past the stall line %s, but the cleanup horizon is held at age %s by a %s (%s); VACUUM cannot advance relfrozenxid past the horizon, so emergency escalation is suppressed until the blocker goes away.',
                             r.xid_age, stall_xid_age, horizon_age, horizon_kind, horizon_detail);
        ELSIF xid_ratio >= p.xid_warning_ratio OR mxid_ratio >= p.mxid_warning_ratio THEN
            relation_state := 'wraparound_warning';
            reason := format('XID/MXID age ratio vs freeze_max_age is elevated (xid=%s, mxid=%s); the forced autovacuum will handle this - prioritized only.', to_char(xid_ratio, 'FM0.000'), to_char(mxid_ratio, 'FM0.000'));
        ELSIF pressure_ratio >= p.backlog_critical_ratio THEN
            relation_state := 'backlog_critical';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM0.00'));
        ELSIF pressure_ratio >= p.backlog_urgent_ratio THEN
            relation_state := 'backlog_urgent';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM0.00'));
        ELSIF pressure_ratio >= p.backlog_elevated_ratio THEN
            relation_state := 'backlog_elevated';
            reason := format('%s backlog is %sx the current trigger.',
                             CASE WHEN insert_ratio > backlog_ratio THEN 'Insert' ELSE 'Dead-tuple' END,
                             to_char(pressure_ratio, 'FM0.00'));
        ELSE
            relation_state := 'normal';
            reason := 'Relation is within configured backlog and wraparound limits.';
        END IF;

        /* Counters saturate at the thresholds they are compared with. */
        IF relation_state = 'normal' THEN
            overdue_cycles := 0;
            healthy_cycles := LEAST(pv_consecutive_healthy + 1,
                                    p.healthy_cycles_before_restore);
        ELSE
            overdue_cycles := LEAST(pv_consecutive_overdue + 1,
                                    p.overdue_cycles_before_change);
            healthy_cycles := 0;
            overdue_relation_count := overdue_relation_count + 1;
        END IF;

        /* Ownership check: every managed key must still hold the value written last time. */
        SELECT NOT EXISTS
        (
            SELECT 1
            FROM jsonb_each_text(pv_managed_values) AS managed(option_name, option_value)
            WHERE (SELECT split_part(o, '=', 2) FROM unnest(r.reloptions) AS o
                   WHERE split_part(o, '=', 1) = managed.option_name LIMIT 1)::numeric
                  IS DISTINCT FROM managed.option_value::numeric
        )
        INTO current_matches_managed;

        IF pv_managed_values <> '{}'::jsonb AND NOT current_matches_managed THEN
            pv_ownership_conflict := true;
        END IF;

        effective_target_ratio := COALESCE(r.table_target_ratio, p.target_dead_tuple_ratio);
        effective_target_min := COALESCE(r.table_target_min, p.target_dead_tuple_min);
        effective_target_max := COALESCE(r.table_target_max, p.target_dead_tuple_max);
        effective_scale_min := COALESCE(r.table_scale_min, p.min_scale_factor);
        effective_scale_max := COALESCE(r.table_scale_max, p.max_scale_factor);

        target_dead_tuples := LEAST(
            effective_target_max,
            GREATEST(effective_target_min,
                     ceil(GREATEST(r.live_tuples, r.reltuples, 1) * effective_target_ratio)::bigint)
        );
        desired_threshold := LEAST(
            target_dead_tuples,
            GREATEST(p.threshold_floor,
                     floor(target_dead_tuples * 0.10)::integer)
        );
        desired_scale_factor := GREATEST(
            effective_scale_min,
            LEAST(
                effective_scale_max,
                (target_dead_tuples - desired_threshold)::double precision /
                    GREATEST(r.reltuples, 1)
            )
        );
        desired_max_threshold := GREATEST(desired_threshold, target_dead_tuples)::integer;

        /* Feed the mistuned-baseline detector with this relation's desired triggers. */
        IF backlog_ratio >= p.backlog_elevated_ratio THEN
            dead_overdue_count := dead_overdue_count + 1;
            overdue_scale_factors := overdue_scale_factors || desired_scale_factor;
            overdue_thresholds := overdue_thresholds || desired_threshold;
        END IF;

        target_inserts := LEAST(
            p.target_insert_max,
            GREATEST(p.target_insert_min,
                     ceil(GREATEST(r.live_tuples, r.reltuples, 1)
                          * p.target_insert_ratio)::bigint)
        );
        desired_insert_threshold := LEAST(
            target_inserts,
            GREATEST(p.threshold_floor,
                     floor(target_inserts * 0.10)::integer)
        );
        desired_insert_scale := GREATEST(
            effective_scale_min,
            LEAST(
                effective_scale_max,
                (target_inserts - desired_insert_threshold)::double precision /
                    GREATEST(r.reltuples, 1)
            )
        );

        IF insert_ratio >= p.backlog_elevated_ratio THEN
            insert_overdue_count := insert_overdue_count + 1;
            overdue_insert_scale_factors := overdue_insert_scale_factors || desired_insert_scale;
            overdue_insert_thresholds := overdue_insert_thresholds || desired_insert_threshold;
        END IF;

        IF relation_state LIKE 'backlog_%' AND r.normal_autovacuum_enabled THEN
            desired_values := '{}'::jsonb;

            IF backlog_ratio >= p.backlog_elevated_ratio THEN
                desired_values := desired_values || jsonb_build_object(
                    'autovacuum_vacuum_threshold', desired_threshold::text,
                    'autovacuum_vacuum_scale_factor', trim(trailing '.' from to_char(desired_scale_factor, 'FM0.999999999'))
                );
                /* The per-table trigger ceiling exists only on PG18+. */
                IF server_vnum >= 180000 THEN
                    desired_values := desired_values || jsonb_build_object(
                        'autovacuum_vacuum_max_threshold', desired_max_threshold::text
                    );
                END IF;
            END IF;

            IF insert_ratio >= p.backlog_elevated_ratio THEN
                desired_values := desired_values || jsonb_build_object(
                    'autovacuum_vacuum_insert_threshold', desired_insert_threshold::text,
                    'autovacuum_vacuum_insert_scale_factor', trim(trailing '.' from to_char(desired_insert_scale, 'FM0.999999999'))
                );
            END IF;
        ELSIF relation_state LIKE 'backlog_%' THEN
            desired_values := pv_managed_values;
        ELSIF relation_state LIKE 'wraparound_%' THEN
            desired_values := pv_managed_values
                              - 'autovacuum_vacuum_cost_limit'
                              - 'autovacuum_vacuum_cost_delay';
        ELSIF relation_state = 'horizon_blocked' THEN
            /* Horizon blocked: hold as-is, aggression cannot help and a restore would flap. */
            desired_values := pv_managed_values;
        ELSE
            desired_values := '{}'::jsonb;
        END IF;

        has_existing_cost_boost := pv_managed_values ? 'autovacuum_vacuum_cost_limit';
        wants_cost_boost := p.manage_table_costs
                            AND relation_state <> 'normal'
                            AND relation_state <> 'horizon_blocked'
                            AND (r.normal_autovacuum_enabled OR relation_state LIKE 'wraparound_%')
                            AND (NOT host_pressure OR relation_state = 'wraparound_critical')
                            AND (has_existing_cost_boost
                                 OR cost_boost_count < p.max_boosted_relations);

        IF wants_cost_boost THEN
            IF relation_state IN ('wraparound_critical', 'backlog_critical') THEN
                tier_cost_limit := p.critical_cost_limit;
                tier_cost_delay := p.critical_cost_delay_ms;
            ELSIF relation_state IN ('wraparound_warning', 'backlog_urgent') THEN
                tier_cost_limit := p.urgent_cost_limit;
                tier_cost_delay := p.urgent_cost_delay_ms;
            ELSE
                tier_cost_limit := p.elevated_cost_limit;
                tier_cost_delay := p.elevated_cost_delay_ms;
            END IF;

            /* Ramp: enter at the elevated tier, multiply per change window, capped by the severity tier. */
            prev_boost := NULLIF(pv_managed_values ->> 'autovacuum_vacuum_cost_limit', '')::integer;
            IF prev_boost IS NULL THEN
                desired_cost_limit := LEAST(tier_cost_limit, p.elevated_cost_limit);
            ELSE
                desired_cost_limit := LEAST(tier_cost_limit,
                                            GREATEST(prev_boost,
                                                     ceil(prev_boost * p.boost_ramp_factor)::integer));
            END IF;
            desired_cost_delay := tier_cost_delay;

            /* Cluster-wide admission budget for simultaneous cost boosts. */
            budget_headroom := p.boost_total_cost_limit_budget - cost_budget_used
                               + COALESCE(prev_boost, 0);
            IF desired_cost_limit > budget_headroom THEN
                desired_cost_limit := GREATEST(COALESCE(prev_boost, 0), budget_headroom);
            END IF;

            IF desired_cost_limit >= LEAST(p.elevated_cost_limit, tier_cost_limit) THEN
                desired_values := desired_values || jsonb_build_object(
                    'autovacuum_vacuum_cost_limit', desired_cost_limit::text,
                    'autovacuum_vacuum_cost_delay', trim(trailing '.' from to_char(desired_cost_delay, 'FM0.999'))
                );
                cost_budget_used := cost_budget_used - COALESCE(prev_boost, 0)
                                    + desired_cost_limit;

                IF NOT has_existing_cost_boost THEN
                    cost_boost_count := cost_boost_count + 1;
                END IF;
            END IF;
        END IF;

        /* Built only when a decision row can be written this cycle. */
        relation_json := NULL;
        IF relation_state <> 'normal'
           OR pv_state <> 'normal'
           OR pv_managed_values <> '{}'::jsonb
           OR pv_ownership_conflict THEN
            relation_json := jsonb_build_object(
                'total_bytes', r.total_bytes,
                'live_tuples', r.live_tuples,
                'dead_tuples', r.dead_tuples,
                'vacuum_trigger', vacuum_trigger,
                'backlog_ratio', backlog_ratio,
                'inserts_since_vacuum', r.inserts_since_vacuum,
                'insert_backlog_ratio', insert_ratio,
                'xid_age', r.xid_age,
                'xid_ratio', xid_ratio,
                'mxid_age', r.mxid_age,
                'mxid_ratio', mxid_ratio,
                'effective_xid_freeze_max_age', r.effective_xid_freeze_max_age,
                'effective_mxid_freeze_max_age', r.effective_mxid_freeze_max_age,
                'normal_autovacuum_enabled', r.normal_autovacuum_enabled,
                'vacuum_pid', r.vacuum_pid,
                'vacuum_phase', r.phase,
                'vacuum_elapsed', r.vacuum_elapsed,
                'heap_blks_total', r.heap_blks_total,
                'heap_blks_scanned', r.heap_blks_scanned,
                'index_vacuum_count', r.index_vacuum_count,
                'max_dead_tuple_bytes', r.max_dead_tuple_bytes,
                'dead_tuple_bytes', r.dead_tuple_bytes,
                'delay_time_ms', r.delay_time,
                'antiwraparound', r.antiwraparound,
                'vacuum_stalled_cycles', vacuum_stalled_cycles
            );
        END IF;

        cooldown_ok := pv_last_change_at IS NULL
                       OR clock_timestamp() - pv_last_change_at
                          >= make_interval(secs => p.change_cooldown_seconds);

        should_apply := relation_state <> 'normal'
                        AND overdue_cycles >= p.overdue_cycles_before_change
                        AND cooldown_ok
                        AND r.vacuum_pid IS NULL
                        AND NOT pv_ownership_conflict
                        AND change_count < p.max_changes_per_cycle
                        AND desired_values IS DISTINCT FROM pv_managed_values;

        applied := false;
        action_error := NULL;
        action_name := 'observe';
        apply_kind := NULL;

        IF should_apply THEN
            action_name := CASE WHEN p.dry_run THEN 'propose_reloptions' ELSE 'set_reloptions' END;
            IF NOT p.dry_run THEN
                apply_kind := 'set';
                apply_desired := desired_values;
            END IF;
        ELSIF relation_state = 'normal'
           AND healthy_cycles >= p.healthy_cycles_before_restore
           AND pv_managed_values <> '{}'::jsonb
           AND NOT pv_ownership_conflict
           AND current_matches_managed
           AND cooldown_ok
           AND r.vacuum_pid IS NULL
           AND change_count < p.max_changes_per_cycle THEN
            action_name := CASE WHEN p.dry_run THEN 'propose_restore' ELSE 'restore_reloptions' END;
            IF NOT p.dry_run THEN
                apply_kind := 'restore';
                apply_desired := '{}'::jsonb;
            END IF;
        END IF;

        /* Reconcile: restore released keys to their original value, set the desired ones, in one ALTER. */
        IF apply_kind IS NOT NULL THEN
            BEGIN
                rec_reset_names := ARRAY[]::text[];
                rec_set_parts := ARRAY[]::text[];
                PERFORM set_config('lock_timeout', p.lock_timeout_ms::text || 'ms', true);
                FOR rec_option_name IN
                    SELECT key
                    FROM (SELECT jsonb_object_keys(pv_managed_values) AS key
                          UNION
                          SELECT jsonb_object_keys(apply_desired) AS key) keys
                    ORDER BY key
                LOOP
                    IF rec_option_name NOT IN (
                        'autovacuum_vacuum_threshold',
                        'autovacuum_vacuum_scale_factor',
                        'autovacuum_vacuum_max_threshold',
                        'autovacuum_vacuum_insert_threshold',
                        'autovacuum_vacuum_insert_scale_factor',
                        'autovacuum_vacuum_cost_limit',
                        'autovacuum_vacuum_cost_delay') THEN
                        RAISE EXCEPTION 'unsupported managed reloption: %', rec_option_name;
                    END IF;
                    IF apply_desired ? rec_option_name THEN
                        rec_option_value := apply_desired ->> rec_option_name;
                        IF rec_option_value !~ '^-?[0-9]+([.][0-9]+)?$' THEN
                            RAISE EXCEPTION 'invalid numeric reloption value for %: %', rec_option_name, rec_option_value;
                        END IF;
                        rec_set_parts := array_append(rec_set_parts, format('%I = %s', rec_option_name, rec_option_value));
                    ELSE
                        SELECT split_part(o, '=', 2) INTO rec_original_value
                        FROM unnest(pv_original_reloptions) AS o
                        WHERE split_part(o, '=', 1) = rec_option_name
                        LIMIT 1;
                        IF rec_original_value IS NULL THEN
                            rec_reset_names := array_append(rec_reset_names, rec_option_name);
                        ELSE
                            rec_set_parts := array_append(rec_set_parts, format('%I = %s', rec_option_name, rec_original_value));
                        END IF;
                    END IF;
                END LOOP;
                IF cardinality(rec_reset_names) > 0 THEN
                    EXECUTE format('ALTER TABLE %s RESET (%s)', r.fqname,
                                   (SELECT string_agg(format('%I', v), ', ') FROM unnest(rec_reset_names) AS v));
                END IF;
                IF cardinality(rec_set_parts) > 0 THEN
                    EXECUTE format('ALTER TABLE %s SET (%s)', r.fqname, array_to_string(rec_set_parts, ', '));
                END IF;
                applied := true;
                change_count := change_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
            END;
        END IF;

        IF should_apply THEN
            /* Transition log: attempted changes always, repeated dry-run proposals once per (state, action). */
            IF applied
               OR action_error IS NOT NULL
               OR pv_state IS DISTINCT FROM relation_state
               OR pv_last_action IS DISTINCT FROM action_name THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                    'action', action_name, 'reason', reason, 'host_metrics', host_json,
                    'relation_metrics', relation_json, 'proposed_reloptions', desired_values,
                    'applied', applied, 'error', action_error);
            END IF;
            IF applied THEN
                IF NOT pv_original_captured THEN
                    pv_original_reloptions := r.reloptions;
                    pv_original_captured := true;
                END IF;
                pv_managed_values := desired_values;
            END IF;
        ELSIF apply_kind = 'restore' OR action_name IN ('propose_restore') THEN
            /* Same transition rule: real restores always, repeated dry-run proposals once. */
            IF applied
               OR action_error IS NOT NULL
               OR pv_state IS DISTINCT FROM relation_state
               OR pv_last_action IS DISTINCT FROM action_name THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                    'action', action_name,
                    'reason', 'Relation remained healthy for the configured restore window.',
                    'host_metrics', host_json, 'relation_metrics', relation_json,
                    'proposed_reloptions', pv_managed_values, 'applied', applied, 'error', action_error);
            END IF;
            IF applied THEN
                pv_original_reloptions := NULL;
                pv_original_captured := false;
                pv_managed_values := '{}'::jsonb;
            END IF;
        ELSIF relation_state <> 'normal' OR pv_ownership_conflict THEN
            action_name := CASE
                WHEN pv_ownership_conflict THEN 'ownership_conflict'
                WHEN relation_state = 'horizon_blocked' THEN 'horizon_blocked'
                WHEN relation_state LIKE 'backlog_%' AND NOT r.normal_autovacuum_enabled THEN 'autovacuum_disabled'
                WHEN r.vacuum_pid IS NOT NULL THEN 'vacuum_already_running'
                WHEN NOT cooldown_ok THEN 'cooldown'
                ELSE 'observe'
            END;

            /* Observation-only: logged on entering this (state, action) pair. */
            IF pv_state IS DISTINCT FROM relation_state
               OR pv_last_action IS DISTINCT FROM action_name THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                    'action', action_name, 'reason', reason, 'host_metrics', host_json,
                    'relation_metrics', relation_json, 'proposed_reloptions', desired_values,
                    'applied', false,
                    'error', CASE WHEN pv_ownership_conflict
                                  THEN 'A managed reloption changed outside the controller; automatic writes are suspended.'
                                  ELSE NULL END);
            END IF;
        ELSIF pv_state <> 'normal' THEN
            /* Return to normal closes the episode. */
            action_name := 'recovered';
            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                'action', action_name,
                'reason', format('Relation returned to normal (was %s).', pv_state),
                'host_metrics', host_json, 'relation_metrics', relation_json,
                'proposed_reloptions', NULL, 'applied', false, 'error', NULL);
        END IF;

        emergency_gate := COALESCE(input -> 'emergency' -> r.relid::text, '{}'::jsonb);
        IF emergency_due
           AND p.emergency_vacuum_enabled
           AND NOT p.dry_run
           AND (r.vacuum_pid IS NULL OR emergency_takeover)
           AND NOT COALESCE((emergency_gate ->> 'active')::boolean, false)
           AND NOT COALESCE((emergency_gate ->> 'retry_blocked')::boolean, false)
           /* Hard daily cap against any remaining retry-storm shape. */
           AND COALESCE((emergency_gate ->> 'failed_24h')::integer, 0) < 8
        THEN
            emergency_work_mem_mb := CASE
                WHEN host_metrics_available THEN
                    LEAST(
                        p.emergency_work_mem_max_mb,
                        GREATEST(
                            p.emergency_work_mem_min_mb,
                            floor((host_mem_available_bytes / 1048576.0)
                                  * p.work_mem_available_fraction)::integer
                        )
                    )
                ELSE p.emergency_work_mem_min_mb
            END;

            /* Takeover: cancel the stuck autovacuum (never a manual vacuum). */
            IF emergency_takeover THEN
                PERFORM pg_catalog.pg_cancel_backend(r.vacuum_pid);
            END IF;

            out_emergency := out_emergency || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'reason', reason,
                /* Deadline first (claim order), then age in millions of XIDs. */
                'priority', 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                'work_mem_mb', emergency_work_mem_mb,
                'cost_limit', CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                                   ELSE p.emergency_cost_limit END,
                'cost_delay_ms', CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                                      ELSE p.emergency_cost_delay_ms END,
                'lock_timeout_ms', p.emergency_lock_timeout_ms,
                'is_wraparound', true,
                'deadline_seconds', seconds_until_readonly,
                'takeover', emergency_takeover);

            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'state', relation_state,
                'action', CASE WHEN emergency_takeover THEN 'queue_emergency_takeover'
                               ELSE 'queue_emergency_vacuum' END,
                'reason', reason, 'host_metrics', host_json, 'relation_metrics', relation_json,
                'proposed_reloptions', NULL, 'applied', true, 'error', NULL);
        END IF;

        new_last_change_at := CASE WHEN applied THEN clock_timestamp()
                                   ELSE pv_last_change_at END;

        /* Persist only what a later cycle needs; rewrite on control change or hourly heartbeat. */
        state_needed := relation_state <> 'normal'
                        OR pv_managed_values <> '{}'::jsonb
                        OR pv_ownership_conflict
                        OR pv_original_captured
                        OR r.vacuum_pid IS NOT NULL
                        OR action_error IS NOT NULL
                        OR (new_last_change_at IS NOT NULL
                            AND clock_timestamp() - new_last_change_at
                                < make_interval(secs => p.change_cooldown_seconds));

        IF NOT state_needed THEN
            IF r.state_exists THEN
                out_state_delete := out_state_delete || to_jsonb(r.relid);
            END IF;
        ELSIF NOT r.state_exists
              OR r.prev_relation_name IS DISTINCT FROM r.fqname
              OR r.prev_original_reloptions IS DISTINCT FROM pv_original_reloptions
              OR r.prev_original_captured IS DISTINCT FROM pv_original_captured
              OR r.prev_managed_values IS DISTINCT FROM pv_managed_values
              OR r.prev_ownership_conflict IS DISTINCT FROM pv_ownership_conflict
              OR r.prev_state IS DISTINCT FROM relation_state
              OR r.prev_consecutive_overdue IS DISTINCT FROM overdue_cycles
              OR r.prev_consecutive_healthy IS DISTINCT FROM healthy_cycles
              OR r.prev_last_change_at IS DISTINCT FROM new_last_change_at
              OR r.prev_last_vacuum_pid IS DISTINCT FROM r.vacuum_pid
              OR r.prev_last_vacuum_progress IS DISTINCT FROM cur_vacuum_progress
              OR r.prev_vacuum_stalled_cycles IS DISTINCT FROM vacuum_stalled_cycles
              OR r.prev_last_error IS DISTINCT FROM action_error
              OR r.prev_last_action IS DISTINCT FROM action_name
              OR r.prev_last_seen_at < clock_timestamp() - interval '1 hour'
        THEN
            out_state := out_state || jsonb_build_object(
                'relation_oid', r.relid, 'relation_name', r.fqname,
                'original_reloptions', pv_original_reloptions,
                'original_captured', pv_original_captured,
                'managed_values', pv_managed_values,
                'ownership_conflict', pv_ownership_conflict,
                'state', relation_state,
                'consecutive_overdue', overdue_cycles,
                'consecutive_healthy', healthy_cycles,
                'last_change_at', new_last_change_at,
                'last_dead_tuples', r.dead_tuples, 'last_live_tuples', r.live_tuples,
                'last_trigger', vacuum_trigger, 'last_backlog_ratio', backlog_ratio,
                'last_inserts_since_vacuum', r.inserts_since_vacuum,
                'last_insert_backlog_ratio', insert_ratio,
                'last_xid_age', r.xid_age, 'last_mxid_age', r.mxid_age,
                'last_vacuum_pid', r.vacuum_pid, 'last_vacuum_progress', cur_vacuum_progress,
                'vacuum_stalled_cycles', vacuum_stalled_cycles,
                'last_error', action_error, 'last_action', action_name);
        END IF;
    END LOOP;

    /* Safety scan: relations the performance scan skipped; emergency branch only, never cancels. */
    FOR r IN
        WITH tpol AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
                   AS x(schema_name name, relation_name name, enabled boolean)
        ),
        active_vacuum AS
        (
            SELECT pv.relid, pv.pid AS vacuum_pid
            FROM pg_stat_progress_vacuum pv
            WHERE pv.datid = (SELECT d.oid
                              FROM pg_catalog.pg_database d
                              WHERE d.datname = pg_catalog.current_database())
        ),
        base AS
        (
            SELECT
                c.oid AS relid,
                format('%I.%I', n.nspname, c.relname) AS fqname,
                n.nspname,
                c.relkind,
                c.relpages,
                GREATEST(age(c.relfrozenxid),
                         COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
                GREATEST(mxid_age(c.relminmxid),
                         COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
                CASE
                    WHEN opt.ro_freeze_max_age IS NULL OR opt.ro_freeze_max_age::bigint < 0
                    THEN freeze_max_age
                    ELSE LEAST(freeze_max_age, opt.ro_freeze_max_age::bigint)
                END AS effective_xid_freeze_max_age,
                CASE
                    WHEN opt.ro_multixact_freeze_max_age IS NULL OR opt.ro_multixact_freeze_max_age::bigint < 0
                    THEN multixact_freeze_max_age
                    ELSE LEAST(multixact_freeze_max_age, opt.ro_multixact_freeze_max_age::bigint)
                END AS effective_mxid_freeze_max_age,
                av.vacuum_pid,
                COALESCE(tp.enabled, true) AS tp_enabled,
                CASE
                    WHEN c.relpages > 0 THEN c.relpages::bigint * block_size
                    WHEN pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)
                         >= p.min_table_bytes / block_size THEN pg_total_relation_size(c.oid)
                    ELSE 0::bigint
                END AS total_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
            LEFT JOIN active_vacuum av ON av.relid = c.oid
            LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
            CROSS JOIN LATERAL (
                SELECT
                    max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_freeze_max_age') AS ro_freeze_max_age,
                    max(split_part(o, '=', 2)) FILTER (WHERE split_part(o, '=', 1) = 'autovacuum_multixact_freeze_max_age') AS ro_multixact_freeze_max_age
                FROM unnest(c.reloptions) AS o
            ) opt
            WHERE c.relkind IN ('r', 'm')
              AND c.relpersistence <> 't'
              AND n.nspname <> 'pg_toast'
        )
        SELECT base.*
        FROM base
        /* only relations the performance scan above did NOT evaluate */
        WHERE NOT (base.relkind = 'r'
                   AND NOT (base.nspname = ANY (p.excluded_schemas))
                   AND base.tp_enabled
                   AND base.total_bytes >= p.min_table_bytes)
          /* age already past this relation's stall line */
          AND (base.xid_age >= LEAST(p.emergency_xid_age,
                                     ceil(p.emergency_stall_multiplier * base.effective_xid_freeze_max_age)::bigint)
               OR base.mxid_age >= LEAST(p.emergency_mxid_age,
                                         ceil(p.emergency_stall_multiplier * base.effective_mxid_freeze_max_age)::bigint))
    LOOP
        stall_xid_age := LEAST(p.emergency_xid_age,
                               ceil(p.emergency_stall_multiplier
                                    * COALESCE(NULLIF(r.effective_xid_freeze_max_age, 0),
                                               freeze_max_age))::bigint);
        stall_mxid_age := LEAST(p.emergency_mxid_age,
                                ceil(p.emergency_stall_multiplier
                                     * COALESCE(NULLIF(r.effective_mxid_freeze_max_age, 0),
                                                multixact_freeze_max_age))::bigint);

        xid_horizon_blocked := horizon_age IS NOT NULL
                               AND horizon_age >= stall_xid_age;

        /* No per-relation progress state here, so never take over a running vacuum. */
        emergency_due := r.vacuum_pid IS NULL
            AND (r.mxid_age >= stall_mxid_age
                 OR (NOT xid_horizon_blocked
                     AND r.xid_age >= stall_xid_age));

        IF NOT emergency_due THEN
            IF xid_horizon_blocked AND r.xid_age >= stall_xid_age THEN
                out_decisions := out_decisions || jsonb_build_object(
                    'relid', r.relid, 'relation_name', r.fqname,
                    'state', 'horizon_blocked', 'action', 'horizon_blocked',
                    'reason', format('Safety scan: XID age %s is past the stall line %s, but the cleanup horizon is held at age %s by a %s (%s); emergency escalation is suppressed until the blocker goes away.',
                                     r.xid_age, stall_xid_age, horizon_age, horizon_kind, horizon_detail),
                    'host_metrics', host_json,
                    'relation_metrics', jsonb_build_object('xid_age', r.xid_age, 'mxid_age', r.mxid_age, 'safety_scan', true),
                    'proposed_reloptions', NULL, 'applied', false, 'error', NULL);
            END IF;
            CONTINUE;
        END IF;

        reason := format('Safety scan: no autovacuum is running although XID age %s / MXID age %s is past the stall line (%s / %s); the relation was invisible to the performance scan (size/schema/table-policy filters).',
                         r.xid_age, r.mxid_age, stall_xid_age, stall_mxid_age);
        critical_seen := true;
        emergency_relation_count := emergency_relation_count + 1;

        IF p.dry_run OR NOT p.emergency_vacuum_enabled THEN
            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname,
                'state', 'wraparound_critical', 'action', 'propose_emergency_vacuum',
                'reason', reason, 'host_metrics', host_json,
                'relation_metrics', jsonb_build_object('xid_age', r.xid_age, 'mxid_age', r.mxid_age, 'safety_scan', true),
                'proposed_reloptions', NULL, 'applied', false, 'error', NULL);
            CONTINUE;
        END IF;

        emergency_gate := COALESCE(input -> 'emergency' -> r.relid::text, '{}'::jsonb);
        IF NOT COALESCE((emergency_gate ->> 'active')::boolean, false)
           AND NOT COALESCE((emergency_gate ->> 'retry_blocked')::boolean, false)
           AND COALESCE((emergency_gate ->> 'failed_24h')::integer, 0) < 8
        THEN
            emergency_work_mem_mb := CASE
                WHEN host_metrics_available THEN
                    LEAST(
                        p.emergency_work_mem_max_mb,
                        GREATEST(
                            p.emergency_work_mem_min_mb,
                            floor((host_mem_available_bytes / 1048576.0)
                                  * p.work_mem_available_fraction)::integer
                        )
                    )
                ELSE p.emergency_work_mem_min_mb
            END;

            out_emergency := out_emergency || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname, 'reason', reason,
                'priority', 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                'work_mem_mb', emergency_work_mem_mb,
                'cost_limit', CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                                   ELSE p.emergency_cost_limit END,
                'cost_delay_ms', CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                                      ELSE p.emergency_cost_delay_ms END,
                'lock_timeout_ms', p.emergency_lock_timeout_ms,
                'is_wraparound', true,
                'deadline_seconds', CASE WHEN xid_rate IS NOT NULL AND xid_rate > 0
                                         THEN GREATEST(2147483648 - 3000000 - r.xid_age, 0)::double precision / xid_rate
                                    END,
                'takeover', false);

            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname,
                'state', 'wraparound_critical', 'action', 'queue_emergency_vacuum',
                'reason', reason, 'host_metrics', host_json,
                'relation_metrics', jsonb_build_object('xid_age', r.xid_age, 'mxid_age', r.mxid_age, 'safety_scan', true),
                'proposed_reloptions', NULL, 'applied', true, 'error', NULL);
        END IF;
    END LOOP;

    /* Local medians of the desired trigger settings (the global controller weights them by count). */
    IF dead_overdue_count > 0 THEN
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_scale
        FROM unnest(overdue_scale_factors) AS v;
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_thresh
        FROM unnest(overdue_thresholds) AS v;
    END IF;
    IF insert_overdue_count > 0 THEN
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_ins_scale
        FROM unnest(overdue_insert_scale_factors) AS v;
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO local_median_ins_thresh
        FROM unnest(overdue_insert_thresholds) AS v;
    END IF;

    /* Never-analyzed tables: largest first within a time budget; graduated under host pressure. */
    analyze_budget_ms := CASE WHEN host_pressure THEN 0
                              WHEN moderate_pressure THEN p.analyze_missing_stats_budget_ms / 4
                              ELSE p.analyze_missing_stats_budget_ms END;
    analyze_started_at := clock_timestamp();
    IF p.analyze_missing_stats AND analyze_budget_ms > 0 THEN
        FOR r IN
            WITH tpol AS MATERIALIZED (
                SELECT * FROM jsonb_to_recordset(COALESCE(input -> 'table_policy', '[]'::jsonb))
                       AS x(schema_name name, relation_name name, enabled boolean)
            ),
            proposed AS (
                SELECT (v #>> '{}')::oid AS relid
                FROM jsonb_array_elements(COALESCE(input -> 'proposed_analyze', '[]'::jsonb)) AS v
            )
            SELECT c.oid AS relid,
                   format('%I.%I', n.nspname, c.relname) AS fqname,
                   pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN tpol tp ON tp.schema_name = n.nspname AND tp.relation_name = c.relname
            WHERE c.relkind = 'r'
              AND c.relpersistence <> 't'
              AND NOT (n.nspname = ANY (p.excluded_schemas))
              AND COALESCE(tp.enabled, true)
              AND pg_stat_get_live_tuples(c.oid) > 0
              AND pg_stat_get_last_analyze_time(c.oid) IS NULL
              AND pg_stat_get_last_autoanalyze_time(c.oid) IS NULL
              /* Dry run proposes each table once; the transition log must not repeat per check. */
              AND (NOT p.dry_run
                   OR NOT EXISTS (SELECT 1 FROM proposed pr WHERE pr.relid = c.oid))
            ORDER BY pg_stat_get_live_tuples(c.oid) DESC
        LOOP
            /* Budget is checked between statements; a running ANALYZE is never interrupted. */
            EXIT WHEN analyze_count > 0
                      AND extract(epoch FROM clock_timestamp() - analyze_started_at) * 1000
                          >= analyze_budget_ms;
            analyze_count := analyze_count + 1;
            applied := false;
            action_error := NULL;
            action_name := CASE WHEN p.dry_run THEN 'propose_analyze' ELSE 'analyze' END;
            reason := format('Table has %s live rows but has never been analyzed (manually or by autoanalyze); the planner is working from default estimates.',
                             r.live_tuples);

            IF NOT p.dry_run THEN
                BEGIN
                    PERFORM set_config('lock_timeout', p.lock_timeout_ms::text || 'ms', true);
                    EXECUTE format('ANALYZE %s', r.fqname);
                    applied := true;
                EXCEPTION
                    WHEN OTHERS THEN
                        GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
                END;
            END IF;

            out_decisions := out_decisions || jsonb_build_object(
                'relid', r.relid, 'relation_name', r.fqname,
                'state', 'statistics_missing', 'action', action_name, 'reason', reason,
                'host_metrics', host_json,
                'relation_metrics', jsonb_build_object('live_tuples', r.live_tuples),
                'proposed_reloptions', NULL, 'applied', applied, 'error', action_error);
        END LOOP;
    END IF;

    PERFORM pg_catalog.set_config('adaptive_autovacuum.worker_output', jsonb_build_object(
        'ok', true,
        'extension_installed', extension_installed,
        'summary', jsonb_build_object(
            'table_count', table_count,
            'eligible', scanned_relation_count,
            'overdue', overdue_relation_count,
            'dead_overdue', dead_overdue_count,
            'insert_overdue', insert_overdue_count,
            'fleet_max_target', fleet_max_target,
            'median_scale', local_median_scale,
            'median_thresh', local_median_thresh,
            'median_ins_scale', local_median_ins_scale,
            'median_ins_thresh', local_median_ins_thresh,
            'debt_tuples', total_debt_tuples,
            'emergency_relations', emergency_relation_count,
            'critical_seen', critical_seen,
            'max_xid_age', db_max_xid_age,
            'max_mxid_age', db_max_mxid_age,
            'changes_applied', change_count,
            'analyzed', analyze_count,
            'scan_seconds', extract(epoch FROM clock_timestamp() - scan_started_at)),
        'table_state', out_state,
        'table_state_delete', out_state_delete,
        'decisions', out_decisions,
        'emergency_requests', out_emergency)::text, false);
END
$aav_body$;

COMMENT ON FUNCTION adaptive_autovacuum._database_program() IS
'Body of the anonymous PL/pgSQL block the database worker runs inside each managed database. It reads adaptive_autovacuum.worker_input (policy, previous table state, gates) and leaves its result in adaptive_autovacuum.worker_output; it uses no extension objects, so managed databases need no CREATE EXTENSION.';

/* ---------- control plane: functions the controller process calls in the control database ---------- */

/* Sweep bookkeeping: a new generation starts; returns its number. */
CREATE FUNCTION adaptive_autovacuum._begin_generation()
RETURNS bigint
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    UPDATE adaptive_autovacuum.controller_state
    SET cluster_generation = cluster_generation + 1,
        last_sweep_started_at = clock_timestamp()
    WHERE only_row
    RETURNING cluster_generation
$$;

/* Discovery: every connectable non-template database, policy include/exclude applied; oldest first. */
CREATE FUNCTION adaptive_autovacuum._discover_databases()
RETURNS TABLE (database_oid oid, database_name name, excluded boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    inc text[];
    exc text[];
BEGIN
    SELECT p.included_databases, p.excluded_databases INTO inc, exc
    FROM adaptive_autovacuum.policy p WHERE p.singleton;

    /* Dropped databases take their state with them. */
    DELETE FROM adaptive_autovacuum.table_state ts
    WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database d WHERE d.oid = ts.database_oid);
    DELETE FROM adaptive_autovacuum.database_state ds
    WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database d WHERE d.oid = ds.database_oid);

    RETURN QUERY
    WITH found AS (
        SELECT d.oid, d.datname,
               ((inc IS NOT NULL AND NOT (d.datname LIKE ANY (inc)))
                OR d.datname LIKE ANY (COALESCE(exc, ARRAY[]::text[]))) AS is_excluded,
               GREATEST(age(d.datfrozenxid), mxid_age(d.datminmxid)) AS dat_age
        FROM pg_catalog.pg_database d
        WHERE d.datallowconn
          AND NOT d.datistemplate
    ),
    upsert AS (
        INSERT INTO adaptive_autovacuum.database_state AS ds
            (database_oid, database_name, status)
        SELECT f.oid, f.datname, CASE WHEN f.is_excluded THEN 'excluded' ELSE 'pending' END
        FROM found f
        ON CONFLICT ON CONSTRAINT database_state_pkey DO UPDATE
        SET database_name = EXCLUDED.database_name,
            last_seen_at = clock_timestamp(),
            status = CASE WHEN EXCLUDED.status = 'excluded' THEN 'excluded'
                          WHEN ds.status = 'excluded' THEN 'pending'
                          ELSE ds.status END
        RETURNING ds.database_oid
    )
    SELECT f.oid, f.datname, f.is_excluded
    FROM found f
    ORDER BY f.dat_age DESC, f.oid;
END
$$;

/* Everything one database worker needs, as one JSON document; also stamps the scan start. */
CREATE FUNCTION adaptive_autovacuum._worker_input(
    dboid oid,
    dbname name,
    generation bigint,
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    p adaptive_autovacuum.policy%ROWTYPE;
    cs adaptive_autovacuum.controller_state%ROWTYPE;
    host_memory_percent double precision;
    host_load_per_cpu double precision;
    host_metrics_available boolean;
    host_pressure boolean;
    moderate_pressure boolean;
    host_json jsonb;
    doc jsonb;
BEGIN
    SELECT * INTO p FROM adaptive_autovacuum.policy WHERE singleton;
    SELECT * INTO cs FROM adaptive_autovacuum.controller_state WHERE only_row;

    host_metrics_available := COALESCE(host_mem_total_bytes, 0) > 0
                              AND COALESCE(host_mem_available_bytes, -1) >= 0;
    host_cpu_count := GREATEST(COALESCE(host_cpu_count, 1), 1);
    host_load1 := GREATEST(COALESCE(host_load1, 0), 0);
    host_mem_available_bytes := GREATEST(COALESCE(host_mem_available_bytes, 0), 0);
    host_mem_total_bytes := GREATEST(COALESCE(host_mem_total_bytes, 0), 0);
    host_memory_percent := CASE WHEN host_mem_total_bytes > 0
                                THEN 100.0 * host_mem_available_bytes / host_mem_total_bytes
                                ELSE 100.0 END;
    host_load_per_cpu := host_load1 / host_cpu_count;

    /* CPU and memory pressure are fresh; the WAL-rate flag comes from the previous sweep's sample. */
    host_pressure := host_memory_percent < p.low_memory_percent
                     OR host_load_per_cpu > p.high_load_per_cpu
                     OR cs.storage_pressure;
    moderate_pressure := host_load_per_cpu > p.high_load_per_cpu / 2
                         OR host_memory_percent < 2 * p.low_memory_percent
                         OR (p.high_wal_mbps > 0 AND cs.wal_rate_mbps IS NOT NULL
                             AND cs.wal_rate_mbps >= p.high_wal_mbps / 2);

    host_json := jsonb_build_object(
        'load1', host_load1,
        'cpu_count', host_cpu_count,
        'load_per_cpu', host_load_per_cpu,
        'mem_available_bytes', host_mem_available_bytes,
        'mem_total_bytes', host_mem_total_bytes,
        'mem_available_percent', host_memory_percent,
        'memory_metrics_available', host_metrics_available,
        'wal_rate_mbps', cs.wal_rate_mbps,
        'storage_pressure', cs.storage_pressure,
        'pressure', host_pressure,
        'moderate_pressure', moderate_pressure);

    UPDATE adaptive_autovacuum.database_state
    SET last_scan_started_at = clock_timestamp(),
        last_seen_at = clock_timestamp()
    WHERE database_oid = dboid;

    doc := jsonb_build_object(
        'generation', generation,
        'database_oid', dboid,
        'database_name', dbname,
        'policy', to_jsonb(p) - 'singleton' - 'updated_at' - 'updated_by',
        'host', host_json,
        'cluster', jsonb_build_object(
            'xid_rate', cs.xid_rate,
            'boosted_relations_elsewhere',
                (SELECT count(*) FROM adaptive_autovacuum.table_state ts
                 WHERE ts.database_oid <> dboid
                   AND ts.managed_values ? 'autovacuum_vacuum_cost_limit'
                   AND NOT ts.ownership_conflict),
            'boost_budget_used_elsewhere',
                (SELECT COALESCE(sum((ts.managed_values ->> 'autovacuum_vacuum_cost_limit')::numeric), 0)::integer
                 FROM adaptive_autovacuum.table_state ts
                 WHERE ts.database_oid <> dboid
                   AND ts.managed_values ? 'autovacuum_vacuum_cost_limit'
                   AND NOT ts.ownership_conflict)),
        'table_policy',
            (SELECT COALESCE(jsonb_agg(to_jsonb(tp) - 'database_name' - 'note' - 'updated_at' - 'updated_by'), '[]'::jsonb)
             FROM adaptive_autovacuum.table_policy tp
             WHERE tp.database_name = dbname),
        'table_state',
            (SELECT COALESCE(jsonb_agg(to_jsonb(ts) - 'database_oid' - 'database_name'), '[]'::jsonb)
             FROM adaptive_autovacuum.table_state ts
             WHERE ts.database_oid = dboid),
        'emergency',
            (SELECT COALESCE(jsonb_object_agg(g.relid::text, g.gate), '{}'::jsonb)
             FROM (SELECT q.relid,
                          jsonb_build_object(
                              'active', bool_or(q.status IN ('pending', 'running')),
                              'retry_blocked', bool_or(q.status = 'failed' AND q.next_retry_at > clock_timestamp()),
                              'failed_24h', count(*) FILTER (WHERE q.status = 'failed'
                                                               AND q.finished_at > clock_timestamp() - interval '24 hours')) AS gate
                   FROM adaptive_autovacuum.emergency_queue q
                   WHERE q.database_oid = dboid
                   GROUP BY q.relid) g),
        'proposed_analyze',
            (SELECT COALESCE(jsonb_agg(DISTINCT d.relid), '[]'::jsonb)
             FROM adaptive_autovacuum.decisions d
             WHERE d.database_oid = dboid AND d.action = 'propose_analyze'));

    RETURN doc::text;
END
$$;

/* A worker that crashed, timed out or reported an error: the database keeps its old summary, marked failed. */
CREATE FUNCTION adaptive_autovacuum._record_database_failure(
    dboid oid, dbname name, generation bigint, error_text text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    INSERT INTO adaptive_autovacuum.database_state AS ds
        (database_oid, database_name, status, last_error, last_seen_at)
    VALUES (dboid, dbname, 'failed', error_text, clock_timestamp())
    ON CONFLICT ON CONSTRAINT database_state_pkey DO UPDATE
    SET status = 'failed',
        last_error = EXCLUDED.last_error,
        last_seen_at = clock_timestamp()
$$;

/* Persist one worker's result centrally: table state, decisions, emergency requests, database summary. */
CREATE FUNCTION adaptive_autovacuum._absorb_database_result(
    dboid oid,
    dbname name,
    generation bigint,
    doc jsonb)
RETURNS TABLE (
    ok boolean,
    eligible integer,
    overdue integer,
    emergency_relations integer,
    extension_installed boolean,
    emergency_pending boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    s jsonb;
    prev_debt bigint;
    prev_velocity double precision;
    prev_completed_at timestamptz;
    interval_seconds double precision;
    velocity double precision;
    debt bigint;
    n_emergency integer;
    n_overdue integer;
BEGIN
    IF NOT COALESCE((doc ->> 'ok')::boolean, false) THEN
        PERFORM adaptive_autovacuum._record_database_failure(
            dboid, dbname, generation, COALESCE(doc ->> 'error', 'worker returned no result'));
        RETURN QUERY SELECT false, 0, 0, 0, false, false;
        RETURN;
    END IF;

    s := doc -> 'summary';

    DELETE FROM adaptive_autovacuum.table_state ts
    WHERE ts.database_oid = dboid
      AND ts.relation_oid IN (SELECT (v #>> '{}')::oid
                              FROM jsonb_array_elements(COALESCE(doc -> 'table_state_delete', '[]'::jsonb)) AS v);

    INSERT INTO adaptive_autovacuum.table_state AS target
        (database_oid, relation_oid, database_name, relation_name,
         original_reloptions, original_captured, managed_values, ownership_conflict,
         state, consecutive_overdue, consecutive_healthy, last_seen_at, last_change_at,
         last_dead_tuples, last_live_tuples, last_trigger, last_backlog_ratio,
         last_inserts_since_vacuum, last_insert_backlog_ratio, last_xid_age, last_mxid_age,
         last_vacuum_pid, last_vacuum_progress, vacuum_stalled_cycles, last_error, last_action)
    SELECT dboid, x.relation_oid, dbname, x.relation_name,
           x.original_reloptions, COALESCE(x.original_captured, false),
           COALESCE(x.managed_values, '{}'::jsonb), COALESCE(x.ownership_conflict, false),
           COALESCE(x.state, 'normal'), COALESCE(x.consecutive_overdue, 0),
           COALESCE(x.consecutive_healthy, 0), clock_timestamp(), x.last_change_at,
           x.last_dead_tuples, x.last_live_tuples, x.last_trigger, x.last_backlog_ratio,
           x.last_inserts_since_vacuum, x.last_insert_backlog_ratio, x.last_xid_age, x.last_mxid_age,
           x.last_vacuum_pid, x.last_vacuum_progress, COALESCE(x.vacuum_stalled_cycles, 0),
           x.last_error, x.last_action
    FROM jsonb_to_recordset(COALESCE(doc -> 'table_state', '[]'::jsonb)) AS x(
        relation_oid oid, relation_name text, original_reloptions text[], original_captured boolean,
        managed_values jsonb, ownership_conflict boolean, state text, consecutive_overdue integer,
        consecutive_healthy integer, last_change_at timestamptz, last_dead_tuples bigint,
        last_live_tuples bigint, last_trigger double precision, last_backlog_ratio double precision,
        last_inserts_since_vacuum bigint, last_insert_backlog_ratio double precision,
        last_xid_age bigint, last_mxid_age bigint, last_vacuum_pid integer,
        last_vacuum_progress text, vacuum_stalled_cycles integer, last_error text, last_action text)
    ON CONFLICT (database_oid, relation_oid) DO UPDATE
    SET database_name = EXCLUDED.database_name,
        relation_name = EXCLUDED.relation_name,
        original_reloptions = EXCLUDED.original_reloptions,
        original_captured = EXCLUDED.original_captured,
        managed_values = EXCLUDED.managed_values,
        ownership_conflict = EXCLUDED.ownership_conflict,
        state = EXCLUDED.state,
        consecutive_overdue = EXCLUDED.consecutive_overdue,
        consecutive_healthy = EXCLUDED.consecutive_healthy,
        last_seen_at = EXCLUDED.last_seen_at,
        last_change_at = EXCLUDED.last_change_at,
        last_dead_tuples = EXCLUDED.last_dead_tuples,
        last_live_tuples = EXCLUDED.last_live_tuples,
        last_trigger = EXCLUDED.last_trigger,
        last_backlog_ratio = EXCLUDED.last_backlog_ratio,
        last_inserts_since_vacuum = EXCLUDED.last_inserts_since_vacuum,
        last_insert_backlog_ratio = EXCLUDED.last_insert_backlog_ratio,
        last_xid_age = EXCLUDED.last_xid_age,
        last_mxid_age = EXCLUDED.last_mxid_age,
        last_vacuum_pid = EXCLUDED.last_vacuum_pid,
        last_vacuum_progress = EXCLUDED.last_vacuum_progress,
        vacuum_stalled_cycles = EXCLUDED.vacuum_stalled_cycles,
        last_error = EXCLUDED.last_error,
        last_action = EXCLUDED.last_action;

    INSERT INTO adaptive_autovacuum.decisions
        (generation, database_oid, database_name, relid, relation_name, state, action, reason,
         host_metrics, relation_metrics, proposed_reloptions, applied, error)
    SELECT generation, dboid, dbname, x.relid, x.relation_name, x.state, x.action, x.reason,
           COALESCE(x.host_metrics, '{}'::jsonb), x.relation_metrics, x.proposed_reloptions,
           COALESCE(x.applied, false), x.error
    FROM jsonb_to_recordset(COALESCE(doc -> 'decisions', '[]'::jsonb)) AS x(
        relid oid, relation_name text, state text, action text, reason text,
        host_metrics jsonb, relation_metrics jsonb, proposed_reloptions jsonb,
        applied boolean, error text);

    INSERT INTO adaptive_autovacuum.emergency_queue
        (database_oid, database_name, relid, relation_name, reason, priority, work_mem_mb,
         cost_limit, cost_delay_ms, lock_timeout_ms, is_wraparound, deadline_seconds)
    SELECT dboid, dbname, x.relid, x.relation_name, x.reason, x.priority, x.work_mem_mb,
           x.cost_limit, x.cost_delay_ms, x.lock_timeout_ms, COALESCE(x.is_wraparound, true),
           x.deadline_seconds
    FROM jsonb_to_recordset(COALESCE(doc -> 'emergency_requests', '[]'::jsonb)) AS x(
        relid oid, relation_name text, reason text, priority integer, work_mem_mb integer,
        cost_limit integer, cost_delay_ms integer, lock_timeout_ms integer,
        is_wraparound boolean, deadline_seconds double precision)
    ON CONFLICT (database_oid, relid) WHERE status IN ('pending', 'running') DO NOTHING;

    /* Debt velocity: tuples/s since this database's previous scan, halved into the previous EMA. */
    SELECT ds.debt_tuples, ds.debt_velocity, ds.last_scan_completed_at
    INTO prev_debt, prev_velocity, prev_completed_at
    FROM adaptive_autovacuum.database_state ds
    WHERE ds.database_oid = dboid;
    debt := COALESCE((s ->> 'debt_tuples')::bigint, 0);
    velocity := NULL;
    IF prev_completed_at IS NOT NULL
       AND clock_timestamp() > prev_completed_at + interval '1 second'
       AND prev_debt IS NOT NULL THEN
        interval_seconds := extract(epoch FROM clock_timestamp() - prev_completed_at);
        velocity := (debt - prev_debt)::double precision / interval_seconds;
        IF prev_velocity IS NOT NULL THEN
            velocity := 0.5 * velocity + 0.5 * prev_velocity;
        END IF;
    END IF;

    n_emergency := COALESCE((s ->> 'emergency_relations')::integer, 0);
    n_overdue := COALESCE((s ->> 'overdue')::integer, 0);

    INSERT INTO adaptive_autovacuum.database_state AS ds
        (database_oid, database_name, last_seen_at, last_scan_completed_at, scan_generation,
         scan_seconds, status, last_error, extension_installed, table_count, eligible_relations,
         overdue_relations, dead_overdue, insert_overdue, emergency_relations, fleet_max_target,
         median_scale, median_thresh, median_ins_scale, median_ins_thresh, debt_tuples,
         debt_velocity, max_xid_age, max_mxid_age, changes_applied, analyzed_relations)
    VALUES
        (dboid, dbname, clock_timestamp(), clock_timestamp(), generation,
         (s ->> 'scan_seconds')::double precision,
         CASE WHEN n_emergency > 0 THEN 'emergency'
              WHEN n_overdue > 0 THEN 'backlog'
              ELSE 'healthy' END,
         NULL, COALESCE((doc ->> 'extension_installed')::boolean, false),
         (s ->> 'table_count')::integer, (s ->> 'eligible')::integer,
         n_overdue, (s ->> 'dead_overdue')::integer, (s ->> 'insert_overdue')::integer,
         n_emergency, (s ->> 'fleet_max_target')::bigint,
         (s ->> 'median_scale')::double precision, (s ->> 'median_thresh')::double precision,
         (s ->> 'median_ins_scale')::double precision, (s ->> 'median_ins_thresh')::double precision,
         debt, velocity, (s ->> 'max_xid_age')::bigint, (s ->> 'max_mxid_age')::bigint,
         (s ->> 'changes_applied')::integer, (s ->> 'analyzed')::integer)
    ON CONFLICT ON CONSTRAINT database_state_pkey DO UPDATE
    SET database_name = EXCLUDED.database_name,
        last_seen_at = EXCLUDED.last_seen_at,
        last_scan_completed_at = EXCLUDED.last_scan_completed_at,
        scan_generation = EXCLUDED.scan_generation,
        scan_seconds = EXCLUDED.scan_seconds,
        status = EXCLUDED.status,
        last_error = NULL,
        extension_installed = EXCLUDED.extension_installed,
        table_count = EXCLUDED.table_count,
        eligible_relations = EXCLUDED.eligible_relations,
        overdue_relations = EXCLUDED.overdue_relations,
        dead_overdue = EXCLUDED.dead_overdue,
        insert_overdue = EXCLUDED.insert_overdue,
        emergency_relations = EXCLUDED.emergency_relations,
        fleet_max_target = EXCLUDED.fleet_max_target,
        median_scale = EXCLUDED.median_scale,
        median_thresh = EXCLUDED.median_thresh,
        median_ins_scale = EXCLUDED.median_ins_scale,
        median_ins_thresh = EXCLUDED.median_ins_thresh,
        debt_tuples = EXCLUDED.debt_tuples,
        debt_velocity = EXCLUDED.debt_velocity,
        max_xid_age = EXCLUDED.max_xid_age,
        max_mxid_age = EXCLUDED.max_mxid_age,
        changes_applied = EXCLUDED.changes_applied,
        analyzed_relations = EXCLUDED.analyzed_relations;

    RETURN QUERY
    SELECT true, (s ->> 'eligible')::integer, n_overdue, n_emergency,
           COALESCE((doc ->> 'extension_installed')::boolean, false),
           EXISTS (SELECT 1 FROM adaptive_autovacuum.emergency_queue q
                   WHERE q.status = 'pending' AND q.next_retry_at <= clock_timestamp());
END
$$;

/* Recover requests whose worker is gone (controller restart, crash); PID-reuse guarded. */
CREATE FUNCTION adaptive_autovacuum._recover_stale_emergencies()
RETURNS integer
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    WITH recovered AS (
        UPDATE adaptive_autovacuum.emergency_queue q
        SET status = 'failed',
            finished_at = clock_timestamp(),
            next_retry_at = clock_timestamp() + interval '5 minutes',
            last_error = 'Recovered stale running request: worker PID is no longer active.'
        WHERE q.status = 'running'
          AND (q.worker_pid IS NULL
               OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stat_activity a
                              WHERE a.pid = q.worker_pid
                                AND a.backend_start <= q.started_at))
        RETURNING 1)
    SELECT count(*)::integer FROM recovered
$$;

/* Claim the most urgent pending request cluster-wide: shortest deadline first, then age. */
CREATE FUNCTION adaptive_autovacuum._claim_emergency_request()
RETURNS TABLE (
    id bigint, database_oid oid, database_name name, relid oid, relation_name text,
    work_mem_mb integer, cost_limit integer, cost_delay_ms integer,
    lock_timeout_ms integer, is_wraparound boolean)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    WITH candidate AS (
        SELECT q.id
        FROM adaptive_autovacuum.emergency_queue q
        WHERE q.status = 'pending'
          AND q.next_retry_at <= clock_timestamp()
          AND EXISTS (SELECT 1 FROM pg_catalog.pg_database d
                      WHERE d.oid = q.database_oid AND d.datallowconn)
        ORDER BY q.deadline_seconds ASC NULLS LAST, q.priority DESC, q.requested_at
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    UPDATE adaptive_autovacuum.emergency_queue q
    SET status = 'running',
        started_at = clock_timestamp(),
        worker_pid = NULL,
        attempts = attempts + 1
    FROM candidate
    WHERE q.id = candidate.id
    RETURNING q.id, q.database_oid, q.database_name, q.relid, q.relation_name,
              q.work_mem_mb, q.cost_limit, q.cost_delay_ms, q.lock_timeout_ms, q.is_wraparound
$$;

CREATE FUNCTION adaptive_autovacuum._set_emergency_worker_pid(request_id bigint, pid integer)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    UPDATE adaptive_autovacuum.emergency_queue
    SET worker_pid = pid
    WHERE id = request_id
$$;

/* Completion or failure; the Nth recent failure of a relation waits N x 5 min (cap 2 h). */
CREATE FUNCTION adaptive_autovacuum._finish_emergency_request(
    request_id bigint, new_status text, error_text text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
    UPDATE adaptive_autovacuum.emergency_queue q
    SET status = new_status,
        finished_at = clock_timestamp(),
        last_error = error_text,
        next_retry_at = CASE WHEN new_status = 'failed'
                             THEN clock_timestamp()
                                  + LEAST(24, 1 + (SELECT count(*)
                                                   FROM adaptive_autovacuum.emergency_queue f
                                                   WHERE f.database_oid = q.database_oid
                                                     AND f.relid = q.relid
                                                     AND f.id <> q.id
                                                     AND f.status = 'failed'
                                                     AND f.finished_at > clock_timestamp() - interval '24 hours'))
                                    * interval '5 minutes'
                             ELSE q.next_retry_at END
    WHERE q.id = request_id
$$;

/* The one global controller step, run once per completed sweep in the control database. */
CREATE FUNCTION adaptive_autovacuum._global_controller(
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint,
    generation bigint,
    evidence_complete boolean,
    cluster_xid8 bigint DEFAULT NULL,
    extra_summary jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    p adaptive_autovacuum.policy%ROWTYPE;

    server_vnum integer := current_setting('server_version_num')::integer;
    block_size bigint := current_setting('block_size')::bigint;

    host_memory_percent double precision;
    host_load_per_cpu double precision;
    host_metrics_available boolean;
    cur_host_pressure boolean;
    cur_storage_pressure boolean;
    cur_moderate_pressure boolean;
    host_json jsonb;

    autovacuum_enabled_global boolean;
    freeze_max_age bigint;
    current_global_cost_limit integer;
    current_global_cost_delay double precision;
    current_autovacuum_work_mem_kb integer;
    current_autovacuum_workers integer;
    current_vacuum_threshold double precision;
    current_vacuum_scale_factor double precision;
    current_vacuum_max_threshold double precision;
    current_insert_threshold double precision;
    current_insert_scale_factor double precision;
    autovacuum_worker_slots_cfg integer;
    av_workers_running integer := 0;
    recommended_workers integer;
    recommended_scale double precision;
    recommended_thresh integer;
    recommended_max_thresh integer;
    recommended_ins_scale double precision;
    recommended_ins_thresh integer;
    recommended_an_scale double precision;
    recommended_an_thresh integer;
    current_analyze_scale double precision;
    current_analyze_threshold double precision;

    cluster_db_count integer := 0;
    cl_eligible integer;
    cl_overdue integer;
    cl_dead_overdue integer;
    cl_insert_overdue integer;
    cl_w_scale double precision;
    cl_w_thresh double precision;
    cl_w_ins_scale double precision;
    cl_w_ins_thresh double precision;
    cl_fleet_max bigint;
    cl_debt_tuples bigint;
    cl_debt_velocity double precision;
    cl_velocity_known boolean;
    critical_seen boolean := false;
    backlog_growth double precision;
    backlog_trend text := 'unknown';
    free_cycles integer := 0;
    av_off_cycles integer := 0;
    baseline_json jsonb;
    baseline_cost_limit integer;
    baseline_cost_delay double precision;
    last_applied_cost_limit text;
    last_applied_cost_delay text;
    workers_saturated boolean;
    worker_queue_pressure boolean;
    worker_mem_cap integer;

    cur_xid8 bigint;
    prev_xid8 bigint;
    prev_sample_at timestamptz;
    sample_interval double precision;
    cur_xid_rate double precision;
    cur_wal_bytes bigint;
    prev_wal_bytes bigint;
    cur_wal_rate_mbps double precision;
    page_hit_cost double precision;
    page_miss_cost double precision;
    page_dirty_cost double precision;
    io_hits double precision;
    io_reads double precision;
    io_writes double precision;
    io_extends double precision;
    cur_activity_units double precision;
    prev_activity_units double precision;
    cur_activity_rate double precision;
    activity_detail jsonb;
    raise_at timestamptz;
    raise_limit integer;
    raise_delay double precision;
    rate_before_raise double precision;
    raise_applied_at timestamptz;
    cost_raise boolean := false;
    capped_limit integer;
    drain_seconds double precision;
    backlog_under_control boolean := false;
    globals_applied_here boolean;
    sweep_started_at timestamptz;
    prev_sweep_seconds double precision;
    sweep_seconds double precision;

    long_vacuum_count integer := 0;
    delay_bound_count integer := 0;
    repeated_index_cycle_count integer := 0;

    recommended_cost_limit integer;
    recommended_cost_delay double precision;
    recommended_work_mem_kb integer;
    current_buffer_usage_limit_kb integer;
    recommended_buffer_usage_limit_kb integer;
    buffer_ring_cap_kb bigint;
    shared_buffers_kb bigint;
    recommendation_reason text;
BEGIN
    SELECT * INTO p FROM adaptive_autovacuum.policy WHERE singleton;
    IF NOT FOUND OR NOT p.enabled THEN
        RETURN;
    END IF;

    host_metrics_available := COALESCE(host_mem_total_bytes, 0) > 0
                              AND COALESCE(host_mem_available_bytes, -1) >= 0;
    host_cpu_count := GREATEST(COALESCE(host_cpu_count, 1), 1);
    host_load1 := GREATEST(COALESCE(host_load1, 0), 0);
    host_mem_available_bytes := GREATEST(COALESCE(host_mem_available_bytes, 0), 0);
    host_mem_total_bytes := GREATEST(COALESCE(host_mem_total_bytes, 0), 0);
    host_memory_percent := CASE WHEN host_mem_total_bytes > 0
                                THEN 100.0 * host_mem_available_bytes / host_mem_total_bytes
                                ELSE 100.0 END;
    host_load_per_cpu := host_load1 / host_cpu_count;

    /* Cluster-wide counters since the previous sweep; the XID counter is read without assigning one. */
    cur_xid8 := COALESCE(cluster_xid8,
                         pg_catalog.pg_snapshot_xmax(pg_catalog.pg_current_snapshot())::text::bigint);
    SELECT w.wal_bytes::bigint INTO cur_wal_bytes FROM pg_catalog.pg_stat_wal w;
    SELECT setting::double precision INTO page_hit_cost FROM pg_settings WHERE name = 'vacuum_cost_page_hit';
    SELECT setting::double precision INTO page_miss_cost FROM pg_settings WHERE name = 'vacuum_cost_page_miss';
    SELECT setting::double precision INTO page_dirty_cost FROM pg_settings WHERE name = 'vacuum_cost_page_dirty';
    /* Autovacuum-worker page operations weighted by the vacuum cost model: the activity the budget throttles. */
    SELECT COALESCE(sum(io.hits), 0), COALESCE(sum(io.reads), 0),
           COALESCE(sum(io.writes), 0), COALESCE(sum(io.extends), 0)
    INTO io_hits, io_reads, io_writes, io_extends
    FROM pg_catalog.pg_stat_io io
    WHERE io.backend_type = 'autovacuum worker' AND io.object = 'relation';
    cur_activity_units := io_hits * page_hit_cost + io_reads * page_miss_cost
                          + (io_writes + io_extends) * page_dirty_cost;

    SELECT cs.last_xid8, cs.last_sample_at, cs.last_wal_bytes,
           cs.backlog_free_cycles, cs.autovacuum_off_cycles, cs.baseline_settings,
           cs.last_vacuum_activity_units, cs.last_cost_raise_at, cs.last_raise_cost_limit,
           cs.last_raise_cost_delay, cs.activity_before_raise,
           cs.last_sweep_started_at, cs.observed_sweep_seconds
    INTO prev_xid8, prev_sample_at, prev_wal_bytes,
         free_cycles, av_off_cycles, baseline_json,
         prev_activity_units, raise_at, raise_limit,
         raise_delay, rate_before_raise,
         sweep_started_at, prev_sweep_seconds
    FROM adaptive_autovacuum.controller_state cs;

    cur_xid_rate := NULL;
    cur_wal_rate_mbps := NULL;
    cur_activity_rate := NULL;
    activity_detail := NULL;
    sample_interval := NULL;
    IF prev_sample_at IS NOT NULL
       AND clock_timestamp() > prev_sample_at + interval '1 second' THEN
        sample_interval := extract(epoch FROM clock_timestamp() - prev_sample_at);
        IF prev_xid8 IS NOT NULL AND cur_xid8 > prev_xid8 THEN
            cur_xid_rate := (cur_xid8 - prev_xid8)::double precision / sample_interval;
        END IF;
        IF prev_wal_bytes IS NOT NULL AND cur_wal_bytes >= prev_wal_bytes THEN
            cur_wal_rate_mbps := (cur_wal_bytes - prev_wal_bytes) / 1048576.0 / sample_interval;
        END IF;
        IF prev_activity_units IS NOT NULL AND cur_activity_units >= prev_activity_units THEN
            cur_activity_rate := (cur_activity_units - prev_activity_units) / sample_interval;
            activity_detail := jsonb_build_object(
                'hits_per_sec', io_hits / sample_interval,
                'reads_per_sec', io_reads / sample_interval,
                'writes_per_sec', io_writes / sample_interval,
                'extends_per_sec', io_extends / sample_interval,
                'unit', 'cumulative counters divided by the sample interval; see cost weights',
                'weights', jsonb_build_object('hit', page_hit_cost, 'miss', page_miss_cost, 'dirty', page_dirty_cost));
        END IF;
    END IF;

    /* Sweep duration EMA drives the freshness window of database_status. */
    sweep_seconds := CASE WHEN sweep_started_at IS NOT NULL
                          THEN extract(epoch FROM clock_timestamp() - sweep_started_at) END;
    IF sweep_seconds IS NOT NULL AND prev_sweep_seconds IS NOT NULL THEN
        sweep_seconds := 0.5 * sweep_seconds + 0.5 * prev_sweep_seconds;
    END IF;

    SELECT setting::boolean INTO autovacuum_enabled_global FROM pg_settings WHERE name = 'autovacuum';
    av_off_cycles := CASE WHEN autovacuum_enabled_global THEN 0
                          ELSE LEAST(av_off_cycles + 1, p.repair_disabled_autovacuum_cycles) END;

    /* Storage guardrail: WAL rate above high_wal_mbps is treated as host pressure. */
    cur_storage_pressure := p.high_wal_mbps > 0
                        AND cur_wal_rate_mbps IS NOT NULL
                        AND cur_wal_rate_mbps >= p.high_wal_mbps;
    cur_host_pressure := host_memory_percent < p.low_memory_percent
                     OR host_load_per_cpu > p.high_load_per_cpu
                     OR cur_storage_pressure;
    cur_moderate_pressure := host_load_per_cpu > p.high_load_per_cpu / 2
                         OR host_memory_percent < 2 * p.low_memory_percent
                         OR (p.high_wal_mbps > 0 AND cur_wal_rate_mbps IS NOT NULL
                             AND cur_wal_rate_mbps >= p.high_wal_mbps / 2);

    host_json := jsonb_build_object(
        'load1', host_load1,
        'cpu_count', host_cpu_count,
        'load_per_cpu', host_load_per_cpu,
        'mem_available_bytes', host_mem_available_bytes,
        'mem_total_bytes', host_mem_total_bytes,
        'mem_available_percent', host_memory_percent,
        'memory_metrics_available', host_metrics_available,
        'cur_wal_rate_mbps', cur_wal_rate_mbps,
        'cur_storage_pressure', cur_storage_pressure,
        'pressure', cur_host_pressure);

    SELECT setting::bigint INTO freeze_max_age FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    SELECT setting::integer INTO current_global_cost_limit FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_limit';
    IF current_global_cost_limit < 0 THEN
        SELECT setting::integer INTO current_global_cost_limit FROM pg_settings WHERE name = 'vacuum_cost_limit';
    END IF;
    SELECT setting::double precision INTO current_global_cost_delay FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay';
    SELECT setting::integer INTO current_autovacuum_work_mem_kb FROM pg_settings WHERE name = 'autovacuum_work_mem';
    SELECT GREATEST(setting::integer, 1) INTO current_autovacuum_workers FROM pg_settings WHERE name = 'autovacuum_max_workers';
    SELECT setting::double precision INTO current_vacuum_threshold FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold';
    SELECT setting::double precision INTO current_vacuum_scale_factor FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor';
    SELECT setting::double precision INTO current_vacuum_max_threshold FROM pg_settings WHERE name = 'autovacuum_vacuum_max_threshold';
    SELECT setting::double precision INTO current_insert_threshold FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_threshold';
    SELECT setting::double precision INTO current_insert_scale_factor FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_scale_factor';
    SELECT setting::integer INTO autovacuum_worker_slots_cfg FROM pg_settings WHERE name = 'autovacuum_worker_slots';
    SELECT setting::integer INTO current_buffer_usage_limit_kb FROM pg_settings WHERE name = 'vacuum_buffer_usage_limit';
    SELECT s.setting::bigint * block_size / 1024 INTO shared_buffers_kb FROM pg_settings s WHERE s.name = 'shared_buffers';
    SELECT setting::double precision INTO current_analyze_scale FROM pg_settings WHERE name = 'autovacuum_analyze_scale_factor';
    SELECT setting::double precision INTO current_analyze_threshold FROM pg_settings WHERE name = 'autovacuum_analyze_threshold';

    /* Cluster-wide vacuum progress: every autovacuum worker in every database. */
    SELECT
        count(*) FILTER (
            WHERE clock_timestamp() - a.query_start >= make_interval(secs => p.long_vacuum_seconds)),
        count(*) FILTER (
            WHERE clock_timestamp() - a.query_start >= make_interval(secs => p.long_vacuum_seconds)
              /* delay_time is PG18+; the jsonb detour keeps PG17 parsing (filter never true there). */
              AND ((to_jsonb(pv) ->> 'delay_time'))::double precision >=
                  extract(epoch FROM clock_timestamp() - a.query_start) * 1000.0 * p.high_delay_fraction),
        count(*) FILTER (WHERE pv.index_vacuum_count > 1)
    INTO long_vacuum_count, delay_bound_count, repeated_index_cycle_count
    FROM pg_stat_progress_vacuum pv
    JOIN pg_stat_activity a ON a.pid = pv.pid
    WHERE a.backend_type = 'autovacuum worker';
    long_vacuum_count := COALESCE(long_vacuum_count, 0);
    delay_bound_count := COALESCE(delay_bound_count, 0);
    repeated_index_cycle_count := COALESCE(repeated_index_cycle_count, 0);

    SELECT count(*) INTO av_workers_running
    FROM pg_stat_activity WHERE backend_type = 'autovacuum worker';

    /* Cluster evidence: the summaries of every database scanned in this generation. */
    SELECT count(*),
           COALESCE(sum(ds.eligible_relations), 0),
           COALESCE(sum(ds.overdue_relations), 0),
           COALESCE(sum(ds.dead_overdue), 0),
           COALESCE(sum(ds.insert_overdue), 0),
           COALESCE(sum(ds.median_scale * ds.dead_overdue), 0),
           COALESCE(sum(ds.median_thresh * ds.dead_overdue), 0),
           COALESCE(sum(ds.median_ins_scale * ds.insert_overdue), 0),
           COALESCE(sum(ds.median_ins_thresh * ds.insert_overdue), 0),
           COALESCE(max(ds.fleet_max_target), 0),
           COALESCE(sum(ds.debt_tuples), 0),
           COALESCE(sum(ds.debt_velocity), 0),
           bool_or(ds.debt_velocity IS NOT NULL),
           COALESCE(bool_or(ds.emergency_relations > 0), false)
    INTO cluster_db_count, cl_eligible, cl_overdue, cl_dead_overdue, cl_insert_overdue,
         cl_w_scale, cl_w_thresh, cl_w_ins_scale, cl_w_ins_thresh, cl_fleet_max,
         cl_debt_tuples, cl_debt_velocity, cl_velocity_known, critical_seen
    FROM adaptive_autovacuum.database_state ds
    WHERE ds.scan_generation = generation;

    /* Diagnostic/test hook: an extra pre-aggregated summary is folded in as more databases. */
    IF extra_summary IS NOT NULL THEN
        cluster_db_count := cluster_db_count + COALESCE((extra_summary ->> 'db_count')::integer, 0);
        cl_eligible := cl_eligible + COALESCE((extra_summary ->> 'eligible')::integer, 0);
        cl_overdue := cl_overdue + COALESCE((extra_summary ->> 'overdue')::integer, 0);
        cl_dead_overdue := cl_dead_overdue + COALESCE((extra_summary ->> 'dead_overdue')::integer, 0);
        cl_insert_overdue := cl_insert_overdue + COALESCE((extra_summary ->> 'insert_overdue')::integer, 0);
        cl_w_scale := cl_w_scale + COALESCE((extra_summary ->> 'w_scale_sum')::double precision, 0);
        cl_w_thresh := cl_w_thresh + COALESCE((extra_summary ->> 'w_thresh_sum')::double precision, 0);
        cl_w_ins_scale := cl_w_ins_scale + COALESCE((extra_summary ->> 'w_ins_scale_sum')::double precision, 0);
        cl_w_ins_thresh := cl_w_ins_thresh + COALESCE((extra_summary ->> 'w_ins_thresh_sum')::double precision, 0);
        cl_fleet_max := GREATEST(cl_fleet_max, COALESCE((extra_summary ->> 'fleet_max_target')::bigint, 0));
        cl_debt_tuples := cl_debt_tuples + COALESCE((extra_summary ->> 'debt_tuples')::bigint, 0);
        cl_debt_velocity := cl_debt_velocity + COALESCE((extra_summary ->> 'debt_velocity')::double precision, 0);
        critical_seen := critical_seen OR COALESCE((extra_summary ->> 'critical_seen')::boolean, false);
    END IF;
    cl_velocity_known := COALESCE(cl_velocity_known, false);

    IF NOT autovacuum_enabled_global THEN
        recommended_cost_limit := current_global_cost_limit;
        recommended_cost_delay := current_global_cost_delay;
        recommendation_reason := 'Autovacuum is disabled globally; enable it before applying adaptive throughput recommendations. Core wraparound protection still remains active.';
        IF NOT p.repair_disabled_autovacuum THEN
            recommendation_reason := recommendation_reason
                || ' Automatic repair is off (repair_disabled_autovacuum = false).';
        ELSIF av_off_cycles >= p.repair_disabled_autovacuum_cycles THEN
            recommendation_reason := recommendation_reason || format(
                ' autovacuum has been off for %s consecutive checks: re-enabling it'
                || ' (repair_disabled_autovacuum).', av_off_cycles);
        ELSE
            recommendation_reason := recommendation_reason || format(
                ' autovacuum has been off for %s of the %s consecutive checks required'
                || ' before automatic repair.', av_off_cycles,
                p.repair_disabled_autovacuum_cycles);
        END IF;
    ELSIF cur_host_pressure THEN
        recommended_cost_limit := GREATEST(200, floor(current_global_cost_limit * 0.75)::integer);
        recommended_cost_delay := LEAST(p.recommendation_delay_max_ms,
                                        GREATEST(current_global_cost_delay, 2.0) * 1.5);
        recommendation_reason := CASE
            WHEN cur_storage_pressure THEN format(
                'WAL generation rate (%s MB/s) exceeds high_wal_mbps (%s); reduce vacuum I/O aggression.',
                trim(trailing '.' from to_char(cur_wal_rate_mbps, 'FM999999990.9999')),
                trim(trailing '.' from to_char(p.high_wal_mbps, 'FM999999990.9999')))
            ELSE 'Host pressure is high; reduce vacuum I/O aggression.'
        END;
    ELSIF delay_bound_count > 0 THEN
        recommended_cost_limit := LEAST(p.recommendation_cost_limit_max,
                                        GREATEST(200, current_global_cost_limit * 2));
        /* Halve toward the policy floor; an operator delay already below it is respected. */
        recommended_cost_delay := GREATEST(
            LEAST(p.recommendation_delay_min_ms, GREATEST(current_global_cost_delay, 0)),
            GREATEST(current_global_cost_delay, 0) / 2.0);
        cost_raise := true;
        recommendation_reason := 'Long-running vacuums are spending a material fraction of time in cost delay.';
    ELSE
        recommended_cost_limit := current_global_cost_limit;
        recommended_cost_delay := current_global_cost_delay;
        recommendation_reason := 'No cluster-level cost change is currently justified.';
    END IF;

    IF current_autovacuum_work_mem_kb < 0 THEN
        SELECT setting::integer INTO current_autovacuum_work_mem_kb
        FROM pg_settings WHERE name = 'maintenance_work_mem';
    END IF;

    IF NOT host_metrics_available THEN
        recommended_work_mem_kb := current_autovacuum_work_mem_kb;
    ELSE
        recommended_work_mem_kb := LEAST(
            p.recommendation_work_mem_max_mb * 1024,
            GREATEST(
                65536,
                floor((host_mem_available_bytes / 1024.0)
                      * p.work_mem_available_fraction
                      / current_autovacuum_workers)::integer));

        IF cur_host_pressure THEN
            recommended_work_mem_kb := LEAST(current_autovacuum_work_mem_kb, recommended_work_mem_kb);
        ELSIF repeated_index_cycle_count = 0 THEN
            /* No memory-pressure evidence: raise opportunistically only while workers run; never lower. */
            IF av_workers_running > 0 THEN
                recommended_work_mem_kb := GREATEST(current_autovacuum_work_mem_kb, recommended_work_mem_kb);
            ELSE
                recommended_work_mem_kb := current_autovacuum_work_mem_kb;
            END IF;
        END IF;
    END IF;

    /* Debt trend: growth per sample interval relative to the cluster debt, with a deadband. */
    backlog_growth := NULL;
    backlog_trend := 'unknown';
    IF sample_interval IS NOT NULL AND cl_velocity_known THEN
        backlog_growth := cl_debt_velocity * sample_interval / GREATEST(cl_debt_tuples, 1)::double precision;
        backlog_trend := CASE WHEN backlog_growth > p.backlog_trend_deadband THEN 'growing'
                              WHEN backlog_growth < -p.backlog_trend_deadband THEN 'shrinking'
                              ELSE 'flat' END;
    END IF;
    /* Shrinking is only "under control" if the debt is projected to clear within the target. */
    drain_seconds := CASE WHEN cl_debt_velocity < 0 THEN cl_debt_tuples / -cl_debt_velocity END;
    backlog_under_control := backlog_trend = 'shrinking'
                             AND drain_seconds <= p.max_backlog_drain_seconds;

    /* Baseline = operator value: refreshed when the live value is not the one last applied here. */
    SELECT q.desired_value INTO last_applied_cost_limit
    FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.guc_name = 'autovacuum_vacuum_cost_limit' AND q.status = 'applied'
    ORDER BY q.applied_at DESC LIMIT 1;
    SELECT q.desired_value INTO last_applied_cost_delay
    FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.guc_name = 'autovacuum_vacuum_cost_delay' AND q.status = 'applied'
    ORDER BY q.applied_at DESC LIMIT 1;
    baseline_json := COALESCE(baseline_json, '{}'::jsonb);
    IF last_applied_cost_limit IS NULL
       OR last_applied_cost_limit::numeric IS DISTINCT FROM current_global_cost_limit::numeric
       OR NOT baseline_json ? 'autovacuum_vacuum_cost_limit' THEN
        baseline_json := baseline_json
                         || jsonb_build_object('autovacuum_vacuum_cost_limit', current_global_cost_limit);
    END IF;
    IF last_applied_cost_delay IS NULL
       OR last_applied_cost_delay::numeric IS DISTINCT FROM current_global_cost_delay::numeric
       OR NOT baseline_json ? 'autovacuum_vacuum_cost_delay' THEN
        baseline_json := baseline_json
                         || jsonb_build_object('autovacuum_vacuum_cost_delay', current_global_cost_delay);
    END IF;
    baseline_cost_limit := (baseline_json ->> 'autovacuum_vacuum_cost_limit')::integer;
    baseline_cost_delay := (baseline_json ->> 'autovacuum_vacuum_cost_delay')::double precision;

    /* Closed loop: growing/flat/unknown raises, shrinking holds, no backlog decays to baseline. */
    free_cycles := CASE WHEN cl_overdue = 0
                        THEN LEAST(free_cycles + 1, p.recovery_cycles_before_decay)
                        ELSE 0 END;
    IF NOT cur_host_pressure AND cl_overdue > 0
       AND recommendation_reason = 'No cluster-level cost change is currently justified.'
    THEN
        IF backlog_under_control THEN
            recommendation_reason := format(
                '%s overdue relations, but cluster maintenance debt is shrinking'
                || ' (%s%% per check, clear in about %s s): holding the current cost settings.',
                cl_overdue, to_char(-100.0 * backlog_growth, 'FM9990.0'), round(drain_seconds));
        ELSE
            cost_raise := true;
            recommended_cost_limit := LEAST(p.recommendation_cost_limit_max,
                                            GREATEST(200, current_global_cost_limit * 2));
            /* Same floored walk-down as the delay-bound branch above. */
            recommended_cost_delay := GREATEST(
                LEAST(p.recommendation_delay_min_ms, GREATEST(current_global_cost_delay, 0)),
                GREATEST(current_global_cost_delay, 0) / 2.0);
            recommendation_reason := format(
                '%s overdue relations were found without host pressure; cluster maintenance'
                || ' debt is %s%s%s.',
                cl_overdue, backlog_trend,
                CASE WHEN backlog_growth IS NOT NULL
                     THEN format(' (%s%% per check)', to_char(100.0 * backlog_growth, 'FMS9990.0'))
                     ELSE '' END,
                CASE WHEN backlog_trend = 'shrinking'
                     THEN format(' but would take about %s s to clear (max_backlog_drain_seconds = %s)',
                                 round(drain_seconds), p.max_backlog_drain_seconds)
                     ELSE '' END);
        END IF;
    ELSIF cl_overdue = 0 AND NOT cur_host_pressure AND autovacuum_enabled_global
          AND free_cycles >= p.recovery_cycles_before_decay
          AND recommendation_reason = 'No cluster-level cost change is currently justified.'
          AND (current_global_cost_limit <> baseline_cost_limit
               OR current_global_cost_delay <> baseline_cost_delay) THEN
        IF current_global_cost_limit > baseline_cost_limit THEN
            recommended_cost_limit := GREATEST(baseline_cost_limit, current_global_cost_limit / 2);
        ELSIF current_global_cost_limit < baseline_cost_limit THEN
            recommended_cost_limit := LEAST(baseline_cost_limit, current_global_cost_limit * 2);
        END IF;
        IF current_global_cost_delay < baseline_cost_delay THEN
            recommended_cost_delay := LEAST(baseline_cost_delay,
                                            GREATEST(current_global_cost_delay * 2, 0.5));
        ELSIF current_global_cost_delay > baseline_cost_delay THEN
            recommended_cost_delay := GREATEST(baseline_cost_delay, current_global_cost_delay / 2);
        END IF;
        free_cycles := 0;
        recommendation_reason := format(
            'No overdue relations for %s consecutive checks: stepping the cost settings back'
            || ' toward the pre-incident baseline (cost_limit %s, cost_delay %s ms).',
            p.recovery_cycles_before_decay, baseline_cost_limit,
            trim(trailing '.' from to_char(baseline_cost_delay, 'FM999990.99')));
    END IF;

    /* A raise must first prove itself: the previous applied raise has to show more activity. */
    IF cost_raise AND raise_at IS NOT NULL
       AND raise_limit = current_global_cost_limit
       AND abs(raise_delay - current_global_cost_delay) < 0.001 THEN
        /* The interval counts as post-raise when the raise was applied within its first tenth. */
        SELECT max(q.applied_at) INTO raise_applied_at
        FROM adaptive_autovacuum.global_apply_queue q
        WHERE ((q.guc_name = 'autovacuum_vacuum_cost_limit'
                AND q.desired_value = raise_limit::text)
               OR (q.guc_name = 'autovacuum_vacuum_cost_delay'
                   AND q.desired_value::double precision = raise_delay))
          AND q.status = 'applied'
          AND q.requested_at >= raise_at - interval '1 second';
        IF prev_sample_at IS NULL OR cur_activity_rate IS NULL OR raise_applied_at IS NULL
           OR raise_applied_at > prev_sample_at + sample_interval * interval '0.1 second' THEN
            recommended_cost_limit := current_global_cost_limit;
            recommended_cost_delay := current_global_cost_delay;
            recommendation_reason := recommendation_reason || format(
                ' The last cost raise (to %s / %s ms) has not yet been observed over a full'
                || ' check interval: holding.',
                raise_limit, trim(trailing '.' from to_char(raise_delay, 'FM999990.99')));
        ELSIF cur_activity_rate <= rate_before_raise
                                 * (1 + p.cost_raise_min_activity_gain_percent / 100.0) THEN
            recommended_cost_limit := current_global_cost_limit;
            recommended_cost_delay := current_global_cost_delay;
            recommendation_reason := recommendation_reason || format(
                ' The last cost raise (to %s / %s ms) did not produce a meaningful increase in'
                || ' autovacuum activity (%s -> %s cost units/s, less than %s%% more): the extra'
                || ' budget is not being used yet, so another raise would not help; holding.'
                || ' Possible causes include storage limits, lock waits, vacuum phase changes,'
                || ' worker turnover or sampling timing.',
                raise_limit, trim(trailing '.' from to_char(raise_delay, 'FM999990.99')),
                round(rate_before_raise::numeric), round(cur_activity_rate::numeric),
                p.cost_raise_min_activity_gain_percent);
        END IF;
    END IF;
    /* Page-rate cap: keep the delay (it smooths I/O), take only the limit raise that fits. */
    IF cost_raise AND p.recommendation_max_vacuum_mbps > 0
       AND (recommended_cost_limit > current_global_cost_limit
            OR recommended_cost_delay < current_global_cost_delay)
       AND adaptive_autovacuum.vacuum_cost_ceiling_mbps(recommended_cost_limit,
                                                        recommended_cost_delay,
                                                        page_hit_cost, block_size)
           > p.recommendation_max_vacuum_mbps THEN
        capped_limit := CASE
            WHEN current_global_cost_delay > 0
            THEN floor(p.recommendation_max_vacuum_mbps * 1048576.0 * page_hit_cost
                       * current_global_cost_delay / 1000.0 / block_size)::integer
            ELSE current_global_cost_limit END;
        recommended_cost_delay := current_global_cost_delay;
        recommended_cost_limit := LEAST(recommended_cost_limit,
                                        GREATEST(capped_limit, current_global_cost_limit));
        recommendation_reason := recommendation_reason || format(
            ' Throughput cap %s MB/s (recommendation_max_vacuum_mbps, theoretical page-hit rate): %s.',
            p.recommendation_max_vacuum_mbps,
            CASE WHEN recommended_cost_limit > current_global_cost_limit
                 THEN format('the delay stays at %s ms and cost_limit goes to %s (%s MB/s)',
                             trim(trailing '.' from to_char(current_global_cost_delay, 'FM999990.99')),
                             recommended_cost_limit,
                             round(adaptive_autovacuum.vacuum_cost_ceiling_mbps(
                                       recommended_cost_limit, recommended_cost_delay,
                                       page_hit_cost, block_size)::numeric))
                 ELSE format('the current %s / %s ms (%s MB/s) is held',
                             current_global_cost_limit,
                             trim(trailing '.' from to_char(current_global_cost_delay, 'FM999990.99')),
                             round(adaptive_autovacuum.vacuum_cost_ceiling_mbps(
                                       current_global_cost_limit, current_global_cost_delay,
                                       page_hit_cost, block_size)::numeric))
            END);
    END IF;

    /* Workers: busy pool or a queue far longer than the pool, with non-shrinking debt. */
    workers_saturated := av_workers_running >= current_autovacuum_workers;
    /* One pg_stat_activity sample misses saturation; a long overdue queue is the same evidence. */
    worker_queue_pressure := cl_overdue >= GREATEST(current_autovacuum_workers * 2,
                                                    current_autovacuum_workers + 2);
    IF NOT autovacuum_enabled_global
       OR cl_overdue = 0
       OR (NOT workers_saturated AND NOT worker_queue_pressure)
       OR backlog_under_control
       OR (cur_host_pressure AND NOT critical_seen) THEN
        recommended_workers := current_autovacuum_workers;
    ELSE
        /* Bounded doubling per step, toward the overdue count; independent of the cost budget. */
        recommended_workers := LEAST(GREATEST(cl_overdue, current_autovacuum_workers + 1),
                                     current_autovacuum_workers * 2);
        /* Extra workers must fit in half the free memory at autovacuum_work_mem each. */
        worker_mem_cap := CASE
            WHEN host_metrics_available AND current_autovacuum_work_mem_kb > 0
            THEN current_autovacuum_workers
                 + floor(host_mem_available_bytes / 2.0
                         / (current_autovacuum_work_mem_kb::double precision * 1024))::integer
            ELSE recommended_workers END;
        /* CPU count only gates via load per CPU; no 1-worker-per-CPU ceiling. */
        /* PG18 caps at autovacuum_worker_slots; PG17 stays record-only (restart GUC). */
        recommended_workers := LEAST(recommended_workers,
                                     worker_mem_cap,
                                     p.recommendation_workers_max,
                                     CASE WHEN server_vnum >= 180000
                                          THEN COALESCE(autovacuum_worker_slots_cfg,
                                                        current_autovacuum_workers)
                                          ELSE p.recommendation_workers_max END);
        recommended_workers := GREATEST(recommended_workers, current_autovacuum_workers);

        IF recommended_workers > current_autovacuum_workers THEN
            IF server_vnum >= 180000 THEN
                recommendation_reason := recommendation_reason || format(
                    ' %s of %s autovacuum workers are busy while %s relations are'
                    || ' overdue and maintenance debt is %s; raise autovacuum_max_workers'
                    || ' to %s (reloadable; the shared vacuum_cost_limit is split across'
                    || ' workers, so this does not raise total un-boosted vacuum I/O;'
                    || ' capped by autovacuum_worker_slots=%s which needs a restart to raise).',
                    av_workers_running, current_autovacuum_workers, cl_overdue, backlog_trend,
                    recommended_workers, autovacuum_worker_slots_cfg);
            ELSE
                recommendation_reason := recommendation_reason || format(
                    ' %s of %s autovacuum workers are busy while %s relations are'
                    || ' overdue and maintenance debt is %s; raise autovacuum_max_workers'
                    || ' to %s (on PostgreSQL 17 this requires a server restart, so it is'
                    || ' recorded here and never applied automatically).',
                    av_workers_running, current_autovacuum_workers, cl_overdue, backlog_trend,
                    recommended_workers);
            END IF;
        END IF;
    END IF;

    /* Mistuned baseline: many overdue relations = wrong global triggers; recommend the median. */
    recommended_scale := NULL;
    recommended_thresh := NULL;
    recommended_max_thresh := NULL;
    recommended_an_scale := NULL;
    recommended_an_thresh := NULL;
    IF cl_dead_overdue >= 3
       AND cl_dead_overdue * 4 >= cl_eligible
       AND cl_w_scale > 0
       AND cl_w_thresh > 0 THEN
        recommended_scale := cl_w_scale / cl_dead_overdue;
        recommended_thresh := round(cl_w_thresh / cl_dead_overdue)::integer;

        /* Analyze at half the vacuum scale factor (PostgreSQL's default ratio). */
        recommended_an_scale := GREATEST(0.005, recommended_scale * 0.5);
        recommended_an_thresh := GREATEST(50, recommended_thresh / 2);

        recommendation_reason := recommendation_reason || format(
            ' The global baseline appears mistuned: %s of %s eligible relations'
            || ' are overdue on dead-tuple backlog; setting cluster-wide'
            || ' autovacuum_vacuum_scale_factor ~ %s, autovacuum_vacuum_threshold ~ %s'
            || ' (analyze baseline in proportion: %s / %s)'
            || ' so that per-table overrides remain the exception.',
            cl_dead_overdue, cl_eligible,
            trim(trailing '.' from to_char(recommended_scale, 'FM0.9999')),
            recommended_thresh,
            trim(trailing '.' from to_char(recommended_an_scale, 'FM0.9999')),
            recommended_an_thresh);
    END IF;

    /* PG18 trigger ceiling derived from the largest relation's dead-tuple target, with hysteresis. */
    IF server_vnum >= 180000
       AND cl_fleet_max > 0
       AND (current_vacuum_max_threshold < 0
            OR current_vacuum_max_threshold > cl_fleet_max * 1.10
            OR current_vacuum_max_threshold < cl_fleet_max * 0.50) THEN
        recommended_max_thresh := cl_fleet_max::integer;
        recommendation_reason := recommendation_reason || format(
            ' Dead-tuple trigger ceiling autovacuum_vacuum_max_threshold -> %s,'
            || ' derived from the largest eligible relation'
            || ' (target ratio %s of its rows, policy bounds %s..%s):'
            || ' large tables never wait longer than their policy target while'
            || ' the percentage scale factor keeps governing smaller tables.',
            recommended_max_thresh,
            trim(trailing '.' from to_char(p.target_dead_tuple_ratio, 'FM0.9999')),
            p.target_dead_tuple_min, p.target_dead_tuple_max);
    END IF;

    recommended_ins_scale := NULL;
    recommended_ins_thresh := NULL;
    IF cl_insert_overdue >= 3
       AND cl_insert_overdue * 4 >= cl_eligible
       AND cl_w_ins_scale > 0
       AND cl_w_ins_thresh > 0 THEN
        recommended_ins_scale := cl_w_ins_scale / cl_insert_overdue;
        recommended_ins_thresh := round(cl_w_ins_thresh / cl_insert_overdue)::integer;

        recommendation_reason := recommendation_reason || format(
            ' The insert-vacuum baseline appears mistuned: %s of %s eligible'
            || ' relations are overdue on insert backlog; setting cluster-wide'
            || ' autovacuum_vacuum_insert_scale_factor ~ %s and'
            || ' autovacuum_vacuum_insert_threshold ~ %s.',
            cl_insert_overdue, cl_eligible,
            trim(trailing '.' from to_char(recommended_ins_scale, 'FM0.9999')),
            recommended_ins_thresh);
    END IF;

    /* autovacuum_freeze_max_age sanity check; record-only (postmaster GUC). */
    IF freeze_max_age < 50000000 THEN
        recommendation_reason := recommendation_reason || format(
            ' WARNING: autovacuum_freeze_max_age is abnormally low (%s);'
            || ' forced anti-wraparound vacuums will fire near-constantly.'
            || ' Raise it toward the 200M default (requires a restart; not'
            || ' applied automatically).', freeze_max_age);
    ELSIF freeze_max_age > 1200000000 THEN
        recommendation_reason := recommendation_reason || format(
            ' WARNING: autovacuum_freeze_max_age is dangerously high (%s);'
            || ' little headroom remains before the vacuum failsafe'
            || ' (vacuum_failsafe_age, default 1.6B) and the ~2.1B read-only'
            || ' cutoff. Lower it (requires a restart; not applied'
            || ' automatically).', freeze_max_age);
    END IF;

    /* vacuum_buffer_usage_limit: cautious raise while workers run; policy and shared_buffers/8 caps. */
    recommended_buffer_usage_limit_kb := current_buffer_usage_limit_kb;
    IF current_buffer_usage_limit_kb > 0 THEN
        buffer_ring_cap_kb := LEAST(
            p.recommendation_buffer_usage_limit_max_mb::bigint * 1024,
            shared_buffers_kb / 8 / GREATEST(current_autovacuum_workers, 1));
        IF cur_host_pressure THEN
            SELECT GREATEST(s.boot_val::integer, current_buffer_usage_limit_kb / 2)
            INTO recommended_buffer_usage_limit_kb
            FROM pg_settings s WHERE s.name = 'vacuum_buffer_usage_limit';
        ELSIF av_workers_running > 0
              AND host_metrics_available
              AND current_buffer_usage_limit_kb < buffer_ring_cap_kb THEN
            recommended_buffer_usage_limit_kb := LEAST(
                buffer_ring_cap_kb,
                current_buffer_usage_limit_kb::bigint * 2)::integer;
        END IF;
    END IF;

    IF recommended_buffer_usage_limit_kb <> current_buffer_usage_limit_kb THEN
        IF recommended_buffer_usage_limit_kb > current_buffer_usage_limit_kb THEN
            recommendation_reason := recommendation_reason || format(
                ' %s autovacuum worker(s) are running with free host memory:'
                || ' raising vacuum_buffer_usage_limit %s -> %s kB so'
                || ' maintenance keeps its pages cached across passes'
                || ' (cap %s kB = LEAST(policy %s MB, shared_buffers/8 per'
                || ' worker)).',
                av_workers_running,
                current_buffer_usage_limit_kb, recommended_buffer_usage_limit_kb,
                buffer_ring_cap_kb, p.recommendation_buffer_usage_limit_max_mb);
        ELSE
            recommendation_reason := recommendation_reason || format(
                ' Host pressure: walking vacuum_buffer_usage_limit back'
                || ' %s -> %s kB.',
                current_buffer_usage_limit_kb, recommended_buffer_usage_limit_kb);
        END IF;
    END IF;

    recommendation_reason := recommendation_reason || format(
        ' Cluster-wide evidence (sweep %s): %s databases, %s eligible relations, %s overdue.',
        generation, cluster_db_count, cl_eligible, cl_overdue);

    /* Incomplete cluster evidence (a database failed or timed out this sweep): record the advice only. */
    IF NOT evidence_complete THEN
        recommendation_reason := recommendation_reason
            || ' Cluster evidence is incomplete (not every database was scanned in this sweep): recorded only, not applied.';
    END IF;

    INSERT INTO adaptive_autovacuum.global_recommendations
        (generation, databases, evidence_complete, host_metrics, overdue_relations, long_vacuums,
         delay_bound_long_vacuums, repeated_index_vacuum_cycles,
         recommended_cost_limit, recommended_cost_delay_ms,
         recommended_autovacuum_work_mem_kb, recommended_buffer_usage_limit_kb,
         recommended_autovacuum_workers,
         recommended_vacuum_scale_factor, recommended_vacuum_threshold,
         recommended_vacuum_max_threshold,
         recommended_insert_scale_factor, recommended_insert_threshold,
         recommended_analyze_scale_factor, recommended_analyze_threshold,
         maintenance_debt_tuples, maintenance_debt_velocity, backlog_trend,
         vacuum_activity_rate, vacuum_activity_detail, cost_budget_rate, cost_ceiling_mbps,
         reason)
    VALUES
        (generation, cluster_db_count, evidence_complete, host_json, cl_overdue, long_vacuum_count,
         delay_bound_count, repeated_index_cycle_count,
         recommended_cost_limit, recommended_cost_delay,
         recommended_work_mem_kb, recommended_buffer_usage_limit_kb,
         recommended_workers,
         recommended_scale, recommended_thresh,
         recommended_max_thresh,
         recommended_ins_scale, recommended_ins_thresh,
         recommended_an_scale, recommended_an_thresh,
         cl_debt_tuples, cl_debt_velocity, backlog_trend,
         cur_activity_rate, activity_detail,
         adaptive_autovacuum.cost_budget_rate(current_global_cost_limit, current_global_cost_delay),
         adaptive_autovacuum.vacuum_cost_ceiling_mbps(recommended_cost_limit, recommended_cost_delay,
                                                      page_hit_cost, block_size),
         recommendation_reason);

    /* autovacuum=off repair: the one non-numeric change; queued separately, only ever 'on'. */
    IF p.manage_global_settings AND NOT p.dry_run
       AND NOT autovacuum_enabled_global
       AND p.repair_disabled_autovacuum
       AND av_off_cycles >= p.repair_disabled_autovacuum_cycles
       AND NOT EXISTS (SELECT 1
                       FROM adaptive_autovacuum.global_apply_queue q
                       WHERE q.guc_name = 'autovacuum'
                         AND q.status = 'pending') THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue(generation, guc_name, desired_value, reason)
        VALUES (generation, 'autovacuum', 'on', recommendation_reason);
    END IF;

    /* Cluster-first: queue ALTER SYSTEM changes for the controller process (deduplicated, audited). */
    globals_applied_here := p.manage_global_settings AND NOT p.dry_run AND autovacuum_enabled_global
                            AND evidence_complete;
    IF globals_applied_here THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue(generation, guc_name, desired_value, reason)
        SELECT generation, cand.guc_name, cand.desired_value, recommendation_reason
        FROM (VALUES
            ('autovacuum_vacuum_cost_limit',
             recommended_cost_limit::text,
             current_global_cost_limit::text),
            ('autovacuum_vacuum_cost_delay',
             trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99')),
             trim(trailing '.' from to_char(current_global_cost_delay, 'FM999990.99'))),
            ('autovacuum_max_workers',
             /* Reloadable only on PG18+; on PG17 it stays a recorded recommendation. */
             CASE WHEN server_vnum >= 180000
                       AND recommended_workers > current_autovacuum_workers
                  THEN recommended_workers::text END,
             current_autovacuum_workers::text),
            ('autovacuum_work_mem',
             recommended_work_mem_kb::text,
             current_autovacuum_work_mem_kb::text),
            ('vacuum_buffer_usage_limit',
             recommended_buffer_usage_limit_kb::text,
             current_buffer_usage_limit_kb::text),
            ('autovacuum_vacuum_scale_factor',
             CASE WHEN recommended_scale IS NOT NULL
                  THEN trim(trailing '.' from to_char(recommended_scale, 'FM0.9999')) END,
             trim(trailing '.' from to_char(current_vacuum_scale_factor, 'FM999990.9999'))),
            ('autovacuum_vacuum_threshold',
             CASE WHEN recommended_thresh IS NOT NULL
                  THEN recommended_thresh::text END,
             current_vacuum_threshold::text),
            ('autovacuum_vacuum_max_threshold',
             CASE WHEN recommended_max_thresh IS NOT NULL
                  THEN recommended_max_thresh::text END,
             current_vacuum_max_threshold::text),
            ('autovacuum_vacuum_insert_scale_factor',
             CASE WHEN recommended_ins_scale IS NOT NULL
                  THEN trim(trailing '.' from to_char(recommended_ins_scale, 'FM0.9999')) END,
             trim(trailing '.' from to_char(current_insert_scale_factor, 'FM999990.9999'))),
            ('autovacuum_vacuum_insert_threshold',
             CASE WHEN recommended_ins_thresh IS NOT NULL
                  THEN recommended_ins_thresh::text END,
             current_insert_threshold::text),
            ('autovacuum_analyze_scale_factor',
             CASE WHEN recommended_an_scale IS NOT NULL
                  THEN trim(trailing '.' from to_char(recommended_an_scale, 'FM0.9999')) END,
             trim(trailing '.' from to_char(current_analyze_scale, 'FM999990.9999'))),
            ('autovacuum_analyze_threshold',
             CASE WHEN recommended_an_thresh IS NOT NULL
                  THEN recommended_an_thresh::text END,
             current_analyze_threshold::text)
        ) AS cand(guc_name, desired_value, current_value)
        WHERE cand.desired_value IS NOT NULL
          AND cand.desired_value::numeric IS DISTINCT FROM cand.current_value::numeric
          /* Never enqueue outside pg_settings min/max (also drops GUCs this version lacks). */
          AND EXISTS (SELECT 1
                      FROM pg_settings s
                      WHERE s.name = cand.guc_name
                        AND (s.min_val IS NULL
                             OR cand.desired_value::numeric >= s.min_val::numeric)
                        AND (s.max_val IS NULL
                             OR cand.desired_value::numeric <= s.max_val::numeric))
          AND NOT EXISTS (SELECT 1
                          FROM adaptive_autovacuum.global_apply_queue q
                          WHERE q.guc_name = cand.guc_name
                            AND q.status = 'pending');
    END IF;

    /* Remember a queued raise with the activity seen before it; the next sweep judges it. */
    /* A pair still waiting in the queue is re-recommended each sweep: keep its first record. */
    IF globals_applied_here AND cost_raise
       AND (recommended_cost_limit > current_global_cost_limit
            OR recommended_cost_delay < current_global_cost_delay)
       AND (raise_limit IS DISTINCT FROM recommended_cost_limit
            OR raise_delay IS DISTINCT FROM
               trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99'))::double precision) THEN
        raise_at := clock_timestamp();
        raise_limit := recommended_cost_limit;
        raise_delay := trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99'))::double precision;
        rate_before_raise := COALESCE(cur_activity_rate, 0);
    END IF;
    /* A backlog-free sweep closes the episode: the next incident's first raise is judged fresh. */
    IF cl_overdue = 0 AND raise_at IS NOT NULL THEN
        raise_at := NULL;
        raise_limit := NULL;
        raise_delay := NULL;
        rate_before_raise := NULL;
    END IF;

    UPDATE adaptive_autovacuum.controller_state
    SET last_sweep_completed_at = clock_timestamp(),
        last_complete_generation = CASE WHEN evidence_complete THEN generation ELSE last_complete_generation END,
        observed_sweep_seconds = COALESCE(sweep_seconds, observed_sweep_seconds),
        last_xid8 = cur_xid8,
        xid_rate = cur_xid_rate,
        last_sample_at = clock_timestamp(),
        last_wal_bytes = cur_wal_bytes,
        wal_rate_mbps = cur_wal_rate_mbps,
        host_pressure = cur_host_pressure,
        storage_pressure = cur_storage_pressure,
        moderate_pressure = cur_moderate_pressure,
        last_debt_tuples = cl_debt_tuples,
        debt_velocity = CASE WHEN cl_velocity_known THEN cl_debt_velocity END,
        backlog_free_cycles = free_cycles,
        autovacuum_off_cycles = av_off_cycles,
        baseline_settings = baseline_json,
        last_vacuum_activity_units = cur_activity_units,
        vacuum_activity_rate = cur_activity_rate,
        last_cost_raise_at = raise_at,
        last_raise_cost_limit = raise_limit,
        last_raise_cost_delay = raise_delay,
        activity_before_raise = rate_before_raise
    WHERE only_row;

    UPDATE adaptive_autovacuum.global_apply_queue
    SET status = 'failed',
        error = 'Expired before the controller applied it.'
    WHERE status = 'pending'
      AND requested_at < clock_timestamp() - interval '1 hour';

    /* Retention. */
    DELETE FROM adaptive_autovacuum.table_state ts
    WHERE ts.last_seen_at < clock_timestamp() - interval '7 days';

    DELETE FROM adaptive_autovacuum.decisions
    WHERE decided_at < clock_timestamp() - make_interval(days => p.history_retention_days);

    DELETE FROM adaptive_autovacuum.global_recommendations
    WHERE created_at < clock_timestamp() - make_interval(days => p.history_retention_days);

    DELETE FROM adaptive_autovacuum.emergency_queue
    WHERE finished_at < clock_timestamp() - make_interval(days => p.history_retention_days)
      AND status IN ('completed', 'cancelled', 'failed');

    /* The newest applied row per setting survives retention: it anchors the baseline tracking. */
    DELETE FROM adaptive_autovacuum.global_apply_queue q
    WHERE q.status IN ('applied', 'failed')
      AND coalesce(q.applied_at, q.requested_at)
          < clock_timestamp() - make_interval(days => p.history_retention_days)
      AND q.id NOT IN (SELECT max(k.id)
                       FROM adaptive_autovacuum.global_apply_queue k
                       WHERE k.status = 'applied'
                       GROUP BY k.guc_name);
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum._global_controller(double precision, integer, bigint, bigint, bigint, boolean, bigint, jsonb) IS
'The single cluster-level decision step, run by the controller process once per completed sweep: aggregates database_state for the generation, samples cluster counters (next XID read without assigning one, WAL, cost-weighted autovacuum activity), records one recommendation and queues the allow-listed ALTER SYSTEM changes. extra_summary is a diagnostic hook that folds a pre-aggregated summary in as additional databases.';

/* Run the database program in the current database the way a worker would, and absorb the result. */
CREATE FUNCTION adaptive_autovacuum._scan_this_database(
    generation bigint,
    host_load1 double precision DEFAULT 0,
    host_cpu_count integer DEFAULT 1,
    host_mem_available_bytes bigint DEFAULT 0,
    host_mem_total_bytes bigint DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    dboid oid := (SELECT d.oid FROM pg_catalog.pg_database d WHERE d.datname = current_database());
    dbname name := current_database();
    doc jsonb;
BEGIN
    PERFORM set_config('adaptive_autovacuum.worker_input',
                       adaptive_autovacuum._worker_input(dboid, dbname, generation, host_load1, host_cpu_count,
                                                         host_mem_available_bytes, host_mem_total_bytes),
                       true);
    PERFORM set_config('adaptive_autovacuum.worker_output', '', true);
    EXECUTE format('DO %L', adaptive_autovacuum._database_program());
    doc := current_setting('adaptive_autovacuum.worker_output')::jsonb;
    PERFORM adaptive_autovacuum._absorb_database_result(dboid, dbname, generation, doc);
    RETURN doc;
END
$$;

/* Diagnostic/test harness: one full controller cycle for the current database in one call. */
CREATE FUNCTION adaptive_autovacuum._run_cycle(
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint,
    others_summary jsonb DEFAULT NULL)
RETURNS TABLE(
    o_eligible integer,
    o_overdue integer,
    o_dead_overdue integer,
    o_insert_overdue integer,
    o_fleet_max_target bigint,
    o_median_scale double precision,
    o_median_thresh double precision,
    o_median_ins_scale double precision,
    o_median_ins_thresh double precision,
    o_debt_tuples bigint,
    o_debt_velocity double precision)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    gen bigint;
    doc jsonb;
    s jsonb;
BEGIN
    IF NOT COALESCE((SELECT p.enabled FROM adaptive_autovacuum.policy p WHERE p.singleton), false) THEN
        RETURN;
    END IF;
    gen := adaptive_autovacuum._begin_generation();
    PERFORM adaptive_autovacuum._recover_stale_emergencies();
    PERFORM adaptive_autovacuum._discover_databases();
    doc := adaptive_autovacuum._scan_this_database(gen, host_load1, host_cpu_count,
                                                   host_mem_available_bytes, host_mem_total_bytes);
    PERFORM adaptive_autovacuum._global_controller(host_load1, host_cpu_count, host_mem_available_bytes,
                                                   host_mem_total_bytes, gen, true, NULL, others_summary);
    s := doc -> 'summary';
    o_eligible := (s ->> 'eligible')::integer;
    o_overdue := (s ->> 'overdue')::integer;
    o_dead_overdue := (s ->> 'dead_overdue')::integer;
    o_insert_overdue := (s ->> 'insert_overdue')::integer;
    o_fleet_max_target := (s ->> 'fleet_max_target')::bigint;
    o_median_scale := (s ->> 'median_scale')::double precision;
    o_median_thresh := (s ->> 'median_thresh')::double precision;
    o_median_ins_scale := (s ->> 'median_ins_scale')::double precision;
    o_median_ins_thresh := (s ->> 'median_ins_thresh')::double precision;
    o_debt_tuples := (s ->> 'debt_tuples')::bigint;
    SELECT ds.debt_velocity INTO o_debt_velocity
    FROM adaptive_autovacuum.database_state ds
    WHERE ds.database_name = current_database();
    RETURN NEXT;
END
$$;

COMMENT ON FUNCTION adaptive_autovacuum._run_cycle(double precision, integer, bigint, bigint, jsonb) IS
'Diagnostic harness: begins a generation, scans the current database with the worker program, absorbs the result and runs the global controller, as the controller process does for every database. others_summary is folded into the cluster evidence as additional databases.';

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
    state.last_change_at,
    state.last_dead_tuples,
    state.last_live_tuples,
    state.last_trigger,
    state.last_backlog_ratio,
    state.last_inserts_since_vacuum,
    state.last_insert_backlog_ratio,
    state.last_xid_age,
    state.last_mxid_age,
    state.original_captured,
    state.managed_values,
    state.ownership_conflict,
    state.last_error,
    state.last_action
FROM adaptive_autovacuum.table_state state;

COMMENT ON VIEW adaptive_autovacuum.table_status IS
'Relations in any managed database the controller currently has state for: non-normal, managed, in conflict, being vacuumed, cooling down, or with a failed action. Healthy unmanaged relations are absent by design. The last_* metric columns are as of the last row write (control change or hourly heartbeat), not of the last scan.';

CREATE VIEW adaptive_autovacuum.changed_tables AS
SELECT
    state.database_name,
    state.relation_name,
    change.option_name,
    adaptive_autovacuum._option_value(state.original_reloptions,
                                      change.option_name) AS original_value,
    change.option_value AS current_value,
    state.state,
    state.ownership_conflict,
    state.last_change_at
FROM adaptive_autovacuum.table_state state,
     jsonb_each_text(state.managed_values) AS change(option_name, option_value)
WHERE state.managed_values <> '{}'::jsonb;

COMMENT ON VIEW adaptive_autovacuum.changed_tables IS
'One row per (database, relation, reloption) currently set by the controller: original value (NULL = was inherited from the global default) vs controller-set value.';

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

CREATE VIEW adaptive_autovacuum.latest_global_recommendation AS
SELECT recommendation.*
FROM adaptive_autovacuum.global_recommendations recommendation
ORDER BY recommendation.created_at DESC
LIMIT 1;

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
'One place for everything the extension did: cluster settings applied (scope cluster), per-table changes and their failures (scope table), and emergency vacuums (scope emergency), newest first.';

COMMENT ON TABLE adaptive_autovacuum.policy IS
'One-row cluster policy. enabled and dry_run are independent safety gates; included_databases / excluded_databases (LIKE patterns) choose the managed databases.';
COMMENT ON TABLE adaptive_autovacuum.table_state IS
'Controller ownership, hysteresis counters, and reversible reloption state for relations in every managed database, keyed by database OID + relation OID. Rows exist only for relations with something to remember and are rewritten only on a control change or hourly.';
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
                adaptive_autovacuum.changed_tables,
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
    maintenance_debt_tuples   bigint,
    maintenance_debt_velocity double precision,
    backlog_trend             text,
    autovacuum_workers_running bigint,
    autovacuum_max_workers    integer,
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
        (SELECT c.last_debt_tuples FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT c.debt_velocity FROM adaptive_autovacuum.controller_state c WHERE c.only_row),
        (SELECT r.backlog_trend FROM adaptive_autovacuum.latest_global_recommendation r),
        (SELECT count(*) FROM pg_stat_activity a WHERE a.backend_type = 'autovacuum worker'),
        (SELECT g.setting::integer FROM pg_settings g WHERE g.name = 'autovacuum_max_workers'),
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
'Installer/operator API: one row describing the whole cluster installation - library, launcher and controller, cluster policy, sweep progress, managed databases, backlog and emergency state. Readable by pg_monitor; meaningful in the control database.';

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
            'active (enabled, applying changes'
                || CASE WHEN s.manage_global_settings THEN ', managing cluster settings)' ELSE ', per-table only)' END,
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

    /* 14. emergency_vacuum */
    IF s.extension_version IS NULL THEN
        RETURN QUERY SELECT 'emergency_vacuum', 'WARN', 'not applicable: the extension is not created here', NULL::text;
    ELSIF coalesce(s.active_emergencies, 0) > 0 THEN
        RETURN QUERY SELECT 'emergency_vacuum', 'WARN',
            s.active_emergencies::text || ' emergency VACUUM request(s) pending or running',
            'SELECT * FROM adaptive_autovacuum.emergency_queue WHERE status IN (''pending'', ''running'');';
    ELSE
        RETURN QUERY SELECT 'emergency_vacuum', 'OK', 'no emergency VACUUM pending or running', NULL::text;
    END IF;

    /* 15. wraparound */
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

    /* 16. autovacuum */
    autovacuum_on := current_setting('autovacuum')::boolean;
    IF autovacuum_on THEN
        RETURN QUERY SELECT 'autovacuum', 'OK', 'autovacuum = on', NULL::text;
    ELSE
        RETURN QUERY SELECT 'autovacuum', 'WARN',
            'autovacuum = off; the controller turns it back on after repair_disabled_autovacuum_cycles consecutive sweeps',
            'ALTER SYSTEM SET autovacuum = on; SELECT pg_reload_conf();';
    END IF;

    /* 17. track_cost_delay_timing (PG18+) */
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

    /* 18. recovery */
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
