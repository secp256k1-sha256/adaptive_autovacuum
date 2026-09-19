\echo Use "CREATE EXTENSION adaptive_autovacuum" to load this file. \quit

CREATE SCHEMA adaptive_autovacuum;
REVOKE ALL ON SCHEMA adaptive_autovacuum FROM PUBLIC;

CREATE FUNCTION adaptive_autovacuum.host_metrics()
RETURNS jsonb
AS 'MODULE_PATHNAME', 'adaptive_autovacuum_host_metrics'
LANGUAGE C
VOLATILE
PARALLEL UNSAFE;

/* Shared-memory summary capacity: available=false when the library is not preloaded. */
CREATE FUNCTION adaptive_autovacuum.cluster_summary_status(
    OUT available boolean,
    OUT capacity integer,
    OUT used integer,
    OUT overflow boolean,
    OUT overflow_count bigint,
    OUT last_overflow_at timestamptz,
    OUT oldest_summary_at timestamptz)
RETURNS record
AS 'MODULE_PATHNAME', 'adaptive_autovacuum_cluster_summary_status'
LANGUAGE C
VOLATILE
PARALLEL UNSAFE;

CREATE TABLE adaptive_autovacuum.policy
(
    singleton                       boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    enabled                         boolean NOT NULL DEFAULT true,
    dry_run                         boolean NOT NULL DEFAULT false,
    manage_global_settings          boolean NOT NULL DEFAULT true,

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
    /* Ceiling for automatic cost raises, in MB/s of vacuum_cost_ceiling_mbps(); 0 = no cap. */
    recommendation_max_vacuum_mbps  integer NOT NULL DEFAULT 3200 CHECK (recommendation_max_vacuum_mbps >= 0),
    /* Observed throughput gain a raise must show before the next raise is allowed. */
    cost_raise_min_io_gain_percent  integer NOT NULL DEFAULT 10 CHECK (cost_raise_min_io_gain_percent BETWEEN 0 AND 1000),
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

CREATE TABLE adaptive_autovacuum.table_policy
(
    relid                 oid PRIMARY KEY,
    /* Fingerprint against OID reuse; trigger-filled, mismatched rows are ignored until re-adopted. */
    schema_name           name,
    relation_name         name,
    enabled               boolean NOT NULL DEFAULT true,
    target_dead_tuple_ratio double precision,
    target_dead_tuple_min bigint,
    target_dead_tuple_max bigint,
    min_scale_factor      double precision,
    max_scale_factor      double precision,
    note                  text,
    updated_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by            name NOT NULL DEFAULT current_user,
    CHECK (target_dead_tuple_ratio IS NULL OR (target_dead_tuple_ratio > 0 AND target_dead_tuple_ratio <= 1)),
    CHECK (target_dead_tuple_min IS NULL OR target_dead_tuple_min >= 0),
    CHECK (target_dead_tuple_max IS NULL OR (target_dead_tuple_max >= 0 AND target_dead_tuple_max <= 2147483647)),
    CHECK (target_dead_tuple_min IS NULL OR target_dead_tuple_max IS NULL OR target_dead_tuple_max >= target_dead_tuple_min),
    CHECK (min_scale_factor IS NULL OR (min_scale_factor >= 0 AND min_scale_factor <= 100)),
    CHECK (max_scale_factor IS NULL OR (max_scale_factor >= 0 AND max_scale_factor <= 100)),
    CHECK (min_scale_factor IS NULL OR max_scale_factor IS NULL OR max_scale_factor >= min_scale_factor)
);

CREATE FUNCTION adaptive_autovacuum._table_policy_fill_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT n.nspname, c.relname
    INTO NEW.schema_name, NEW.relation_name
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = NEW.relid;
    RETURN NEW;
END
$$;

CREATE TRIGGER table_policy_fill_identity
    BEFORE INSERT OR UPDATE ON adaptive_autovacuum.table_policy
    FOR EACH ROW
    EXECUTE FUNCTION adaptive_autovacuum._table_policy_fill_identity();

COMMENT ON TABLE adaptive_autovacuum.table_policy IS
'Per-relation operator overrides. schema_name/relation_name fingerprint the relid against OID reuse: rows whose fingerprint no longer matches pg_class are ignored (touch the row with UPDATE to re-adopt after a rename); rows whose relation was dropped are removed each cycle.';

/* Rows only for relations with control state; rewritten on change or hourly, never per cycle. */
CREATE TABLE adaptive_autovacuum.relation_state
(
    relid                 oid PRIMARY KEY,
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
    last_action           text
);

/* UNLOGGED: audit history only, never read back for control; unreadable on a hot standby. */
CREATE UNLOGGED TABLE adaptive_autovacuum.decisions
(
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decided_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
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
CREATE INDEX decisions_relid_decided_at_idx
    ON adaptive_autovacuum.decisions(relid, decided_at DESC);

/* UNLOGGED: advisory history only, never read back for control. */
CREATE UNLOGGED TABLE adaptive_autovacuum.global_recommendations
(
    id                              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
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
    /* Observed autovacuum-worker MB/s (pg_stat_io) and the ceiling of the recommended pair. */
    autovacuum_io_mbps              double precision,
    cost_ceiling_mbps               double precision,
    reason                          text NOT NULL
);

CREATE INDEX global_recommendations_created_at_idx
    ON adaptive_autovacuum.global_recommendations(created_at DESC);

CREATE TABLE adaptive_autovacuum.global_apply_queue
(
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
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
'Cluster-wide setting changes decided by the policy and applied by the C worker via ALTER SYSTEM + reload. old_value records the pre-change setting for rollback.';

CREATE TABLE adaptive_autovacuum.emergency_queue
(
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
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
    ON adaptive_autovacuum.emergency_queue(relid)
    WHERE status IN ('pending', 'running');

/* Per-cycle samples: XID and WAL counters give rates; debt totals give the backlog trend. */
/* Theoretical vacuum throughput of a cost pair: pages/s at page-hit cost times the block size. */
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
'Upper bound on vacuum I/O for a cost_limit / cost_delay pair: (1000 / delay ms) * (limit / vacuum_cost_page_hit) * block size, in MiB/s. PostgreSQL defaults (200 / 2 ms) give 781.25 (the familiar 800 uses 8 KB x 1000).';

CREATE TABLE adaptive_autovacuum.controller_state
(
    only_row        boolean PRIMARY KEY DEFAULT true CHECK (only_row),
    last_xid8       bigint,
    last_sample_at  timestamptz,
    /* pg_stat_wal.wal_bytes at the previous cycle, for the high_wal_mbps guardrail. */
    last_wal_bytes  bigint,
    /* Dead + inserted-since-vacuum tuples over eligible relations, and the smoothed tuples/s rate. */
    last_debt_tuples bigint,
    debt_velocity   double precision,
    /* Consecutive checks with no overdue relation cluster-wide (drives the cost decay). */
    backlog_free_cycles integer NOT NULL DEFAULT 0,
    /* Consecutive checks that saw autovacuum = off (drives the repair). */
    autovacuum_off_cycles integer NOT NULL DEFAULT 0,
    /* Operator values of the cost settings before the first automatic change; the decay target. */
    baseline_settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    /* Autovacuum-worker bytes touched (pg_stat_io, cumulative) and bytes/s over the last interval. */
    last_vacuum_io_bytes bigint,
    vacuum_io_rate  double precision,
    /* The last applied cost raise and the throughput before it; the next raise must beat it. */
    last_cost_raise_at timestamptz,
    last_raise_cost_limit integer,
    last_raise_cost_delay double precision,
    io_rate_before_raise double precision
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

/* others_summary: the other databases' aggregated cycle summaries; returns this one's. */
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
SECURITY DEFINER
SET search_path = pg_catalog, adaptive_autovacuum
AS $$
DECLARE
    p adaptive_autovacuum.policy%ROWTYPE;
    r record;
    previous adaptive_autovacuum.relation_state%ROWTYPE;

    /* PG17 compatibility switch; PG18-only surface is skipped below it. */
    server_vnum integer := current_setting('server_version_num')::integer;
    block_size bigint := current_setting('block_size')::bigint;
    evidence_complete boolean := true;

    host_memory_percent double precision;
    host_load_per_cpu double precision;
    host_metrics_available boolean;
    host_pressure boolean;
    storage_pressure boolean;
    host_json jsonb;

    autovacuum_enabled_global boolean;
    freeze_max_age bigint;
    multixact_freeze_max_age bigint;
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
    scanned_relation_count integer := 0;
    fleet_max_target bigint := 0;
    dead_overdue_count integer := 0;
    overdue_scale_factors double precision[] := '{}';
    overdue_thresholds integer[] := '{}';
    recommended_scale double precision;
    recommended_thresh integer;
    recommended_max_thresh integer;
    insert_overdue_count integer := 0;
    overdue_insert_scale_factors double precision[] := '{}';
    overdue_insert_thresholds integer[] := '{}';
    recommended_ins_scale double precision;
    recommended_ins_thresh integer;
    local_median_scale double precision;
    local_median_thresh double precision;
    local_median_ins_scale double precision;
    local_median_ins_thresh double precision;
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
    /* Maintenance debt = dead + inserted-since-vacuum tuples; velocity = EMA-smoothed tuples/s. */
    total_debt_tuples bigint := 0;
    prev_debt_tuples bigint;
    prev_debt_velocity double precision;
    cur_debt_velocity double precision;
    sample_interval double precision;
    cl_debt_tuples bigint;
    cl_debt_velocity double precision;
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
    cur_vac_io_bytes bigint;
    prev_vac_io_bytes bigint;
    cur_vac_io_rate double precision;
    raise_at timestamptz;
    raise_limit integer;
    raise_delay double precision;
    rate_before_raise double precision;
    page_hit_cost double precision;
    cost_raise boolean := false;
    drain_seconds double precision;
    backlog_under_control boolean := false;
    raise_applied_at timestamptz;
    capped_limit integer;
    globals_applied_here boolean;
    worker_mem_cap integer;
    critical_seen boolean := false;
    moderate_pressure boolean;
    analyze_budget_ms integer;
    analyze_started_at timestamptz;
    analyze_count integer := 0;
    recommended_an_scale double precision;
    recommended_an_thresh integer;
    current_analyze_scale double precision;
    current_analyze_threshold double precision;

    long_vacuum_count integer := 0;
    delay_bound_count integer := 0;
    repeated_index_cycle_count integer := 0;
    overdue_relation_count integer := 0;

    recommended_cost_limit integer;
    recommended_cost_delay double precision;
    recommended_work_mem_kb integer;
    current_buffer_usage_limit_kb integer;
    recommended_buffer_usage_limit_kb integer;
    buffer_ring_cap_kb bigint;
    shared_buffers_kb bigint;
    recommendation_reason text;

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
    cur_xid8 bigint;
    prev_xid8 bigint;
    prev_sample_at timestamptz;
    xid_rate double precision;
    cur_wal_bytes bigint;
    prev_wal_bytes bigint;
    wal_rate_mbps double precision;
    stall_xid_age bigint;
    stall_mxid_age bigint;
    av_wraparound_running boolean;
    av_elapsed_seconds double precision;
    seconds_until_readonly double precision;
    cur_vacuum_progress text;
    vacuum_stalled_cycles integer;
    emergency_due boolean;
    emergency_takeover boolean;
    relation_state text;
    reason text;
    overdue_cycles integer;
    healthy_cycles integer;

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
    state_needed boolean;
    new_last_change_at timestamptz;

    emergency_work_mem_mb integer;
BEGIN
    SELECT * INTO p
    FROM adaptive_autovacuum.policy
    WHERE singleton;

    IF NOT FOUND OR NOT p.enabled THEN
        RETURN;
    END IF;

    host_metrics_available := COALESCE(host_mem_total_bytes, 0) > 0
                              AND COALESCE(host_mem_available_bytes, -1) >= 0;

    host_cpu_count := GREATEST(COALESCE(host_cpu_count, 1), 1);
    host_load1 := GREATEST(COALESCE(host_load1, 0), 0);
    host_mem_available_bytes := GREATEST(COALESCE(host_mem_available_bytes, 0), 0);
    host_mem_total_bytes := GREATEST(COALESCE(host_mem_total_bytes, 0), 0);

    host_memory_percent := CASE
        WHEN host_mem_total_bytes > 0
        THEN 100.0 * host_mem_available_bytes / host_mem_total_bytes
        ELSE 100.0
    END;
    host_load_per_cpu := host_load1 / host_cpu_count;

    /* XID/s and WAL MB/s since the previous cycle; NULL on the first cycle or a tiny window. */
    cur_xid8 := pg_catalog.pg_current_xact_id()::text::bigint;
    SELECT w.wal_bytes::bigint INTO cur_wal_bytes
    FROM pg_catalog.pg_stat_wal w;
    /* Autovacuum-worker pages touched (physical I/O plus cache hits): the observed throughput. */
    IF server_vnum >= 180000 THEN
        SELECT COALESCE(sum(COALESCE(io.read_bytes, 0) + COALESCE(io.write_bytes, 0)
                            + COALESCE(io.extend_bytes, 0)
                            + COALESCE(io.hits, 0) * block_size), 0)::bigint
        INTO cur_vac_io_bytes
        FROM pg_catalog.pg_stat_io io
        WHERE io.backend_type = 'autovacuum worker' AND io.object = 'relation';
    ELSE
        SELECT COALESCE(sum((COALESCE(io.reads, 0) + COALESCE(io.writes, 0)
                             + COALESCE(io.extends, 0) + COALESCE(io.hits, 0))
                            * COALESCE(io.op_bytes, block_size)), 0)::bigint
        INTO cur_vac_io_bytes
        FROM pg_catalog.pg_stat_io io
        WHERE io.backend_type = 'autovacuum worker' AND io.object = 'relation';
    END IF;
    SELECT cs.last_xid8, cs.last_sample_at, cs.last_wal_bytes,
           cs.last_debt_tuples, cs.debt_velocity, cs.backlog_free_cycles,
           cs.autovacuum_off_cycles, cs.baseline_settings,
           cs.last_vacuum_io_bytes, cs.last_cost_raise_at, cs.last_raise_cost_limit,
           cs.last_raise_cost_delay, cs.io_rate_before_raise
    INTO prev_xid8, prev_sample_at, prev_wal_bytes,
         prev_debt_tuples, prev_debt_velocity, free_cycles,
         av_off_cycles, baseline_json,
         prev_vac_io_bytes, raise_at, raise_limit,
         raise_delay, rate_before_raise
    FROM adaptive_autovacuum.controller_state cs;
    xid_rate := NULL;
    wal_rate_mbps := NULL;
    cur_vac_io_rate := NULL;
    sample_interval := NULL;
    IF prev_sample_at IS NOT NULL
       AND clock_timestamp() > prev_sample_at + interval '1 second' THEN
        sample_interval := extract(epoch FROM clock_timestamp() - prev_sample_at);
        IF prev_xid8 IS NOT NULL AND cur_xid8 > prev_xid8 THEN
            xid_rate := (cur_xid8 - prev_xid8)::double precision / sample_interval;
        END IF;
        IF prev_wal_bytes IS NOT NULL AND cur_wal_bytes >= prev_wal_bytes THEN
            wal_rate_mbps := (cur_wal_bytes - prev_wal_bytes) / 1048576.0 / sample_interval;
        END IF;
        IF prev_vac_io_bytes IS NOT NULL AND cur_vac_io_bytes >= prev_vac_io_bytes THEN
            cur_vac_io_rate := (cur_vac_io_bytes - prev_vac_io_bytes) / sample_interval;
        END IF;
    END IF;

    SELECT setting::boolean INTO autovacuum_enabled_global
    FROM pg_settings WHERE name = 'autovacuum';
    av_off_cycles := CASE WHEN autovacuum_enabled_global THEN 0
                          ELSE LEAST(av_off_cycles + 1,
                                     p.repair_disabled_autovacuum_cycles) END;

    /* Storage guardrail: WAL rate above high_wal_mbps is treated as host pressure. */
    storage_pressure := p.high_wal_mbps > 0
                        AND wal_rate_mbps IS NOT NULL
                        AND wal_rate_mbps >= p.high_wal_mbps;

    host_pressure := host_memory_percent < p.low_memory_percent
                     OR host_load_per_cpu > p.high_load_per_cpu
                     OR storage_pressure;

    host_json := jsonb_build_object(
        'load1', host_load1,
        'cpu_count', host_cpu_count,
        'load_per_cpu', host_load_per_cpu,
        'mem_available_bytes', host_mem_available_bytes,
        'mem_total_bytes', host_mem_total_bytes,
        'mem_available_percent', host_memory_percent,
        'memory_metrics_available', host_metrics_available,
        'wal_rate_mbps', wal_rate_mbps,
        'storage_pressure', storage_pressure,
        'pressure', host_pressure
    );

    SELECT setting::bigint INTO freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';

    SELECT setting::bigint INTO multixact_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_multixact_freeze_max_age';

    /* Oldest cleanup-horizon blocker, fetched once per cycle. */
    SELECT b.blocker_age, b.blocker_kind, b.blocker_detail
    INTO horizon_age, horizon_kind, horizon_detail
    FROM adaptive_autovacuum.horizon_blocker() b;

    SELECT setting::integer INTO current_global_cost_limit
    FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_limit';
    IF current_global_cost_limit < 0 THEN
        SELECT setting::integer INTO current_global_cost_limit
        FROM pg_settings WHERE name = 'vacuum_cost_limit';
    END IF;

    SELECT setting::double precision INTO current_global_cost_delay
    FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay';

    SELECT setting::integer INTO current_autovacuum_work_mem_kb
    FROM pg_settings WHERE name = 'autovacuum_work_mem';

    SELECT GREATEST(setting::integer, 1) INTO current_autovacuum_workers
    FROM pg_settings WHERE name = 'autovacuum_max_workers';

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

    SELECT setting::integer INTO autovacuum_worker_slots_cfg
    FROM pg_settings WHERE name = 'autovacuum_worker_slots';

    SELECT setting::double precision INTO page_hit_cost
    FROM pg_settings WHERE name = 'vacuum_cost_page_hit';

    SELECT setting::integer INTO current_buffer_usage_limit_kb
    FROM pg_settings WHERE name = 'vacuum_buffer_usage_limit';

    SELECT s.setting::bigint * pg_catalog.current_setting('block_size')::bigint / 1024
    INTO shared_buffers_kb
    FROM pg_settings s WHERE s.name = 'shared_buffers';

    SELECT setting::double precision INTO current_analyze_scale
    FROM pg_settings WHERE name = 'autovacuum_analyze_scale_factor';

    SELECT setting::double precision INTO current_analyze_threshold
    FROM pg_settings WHERE name = 'autovacuum_analyze_threshold';

    SELECT
        count(*) FILTER (
            WHERE clock_timestamp() - a.query_start
                  >= make_interval(secs => p.long_vacuum_seconds)
        ),
        count(*) FILTER (
            WHERE clock_timestamp() - a.query_start
                  >= make_interval(secs => p.long_vacuum_seconds)
              /* delay_time is PG18+; the jsonb detour keeps PG17 parsing (filter never true there). */
              AND ((to_jsonb(pv) ->> 'delay_time'))::double precision >=
                  extract(epoch FROM clock_timestamp() - a.query_start) * 1000.0
                  * p.high_delay_fraction
        ),
        count(*) FILTER (WHERE pv.index_vacuum_count > 1)
    INTO long_vacuum_count, delay_bound_count, repeated_index_cycle_count
    FROM pg_stat_progress_vacuum pv
    JOIN pg_stat_activity a ON a.pid = pv.pid
    WHERE a.backend_type = 'autovacuum worker';

    long_vacuum_count := COALESCE(long_vacuum_count, 0);
    delay_bound_count := COALESCE(delay_bound_count, 0);
    repeated_index_cycle_count := COALESCE(repeated_index_cycle_count, 0);

    SELECT count(*) INTO av_workers_running
    FROM pg_stat_activity
    WHERE backend_type = 'autovacuum worker';

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
    ELSIF host_pressure THEN
        recommended_cost_limit := GREATEST(200, floor(current_global_cost_limit * 0.75)::integer);
        recommended_cost_delay := LEAST(p.recommendation_delay_max_ms,
                                        GREATEST(current_global_cost_delay, 2.0) * 1.5);
        recommendation_reason := CASE
            WHEN storage_pressure THEN format(
                'WAL generation rate (%s MB/s) exceeds high_wal_mbps (%s); reduce vacuum I/O aggression.',
                trim(trailing '.' from to_char(wal_rate_mbps, 'FM999999990.9999')),
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
                      / current_autovacuum_workers)::integer
            )
        );

        IF host_pressure THEN
            recommended_work_mem_kb := LEAST(current_autovacuum_work_mem_kb,
                                             recommended_work_mem_kb);
        ELSIF repeated_index_cycle_count = 0 THEN
            /* No memory-pressure evidence: raise opportunistically only while workers run; never lower. */
            IF av_workers_running > 0 THEN
                recommended_work_mem_kb := GREATEST(current_autovacuum_work_mem_kb,
                                                    recommended_work_mem_kb);
            ELSE
                recommended_work_mem_kb := current_autovacuum_work_mem_kb;
            END IF;
        END IF;
    END IF;

    UPDATE adaptive_autovacuum.emergency_queue q
    SET status = 'failed',
        finished_at = clock_timestamp(),
        next_retry_at = clock_timestamp() + interval '5 minutes',
        last_error = 'Recovered stale running request: worker PID is no longer active.'
    WHERE q.status = 'running'
      AND (q.worker_pid IS NULL
           OR NOT EXISTS (SELECT 1 FROM pg_stat_activity a
                          WHERE a.pid = q.worker_pid
                            AND a.backend_start <= q.started_at));

    SELECT count(*),
           COALESCE(sum((state.managed_values ->> 'autovacuum_vacuum_cost_limit')::numeric), 0)::integer
    INTO cost_boost_count, cost_budget_used
    FROM adaptive_autovacuum.relation_state state
    WHERE state.managed_values ? 'autovacuum_vacuum_cost_limit'
      AND NOT state.ownership_conflict;

    /* Fleet aggregates over every eligible relation; the loop below only sees the interesting ones. */
    SELECT count(*),
           COALESCE(max(LEAST(COALESCE(tp.target_dead_tuple_max, p.target_dead_tuple_max),
                              GREATEST(COALESCE(tp.target_dead_tuple_min, p.target_dead_tuple_min),
                                       ceil(GREATEST(pg_stat_get_live_tuples(c.oid)::double precision,
                                                     c.reltuples::double precision, 1)
                                            * COALESCE(tp.target_dead_tuple_ratio, p.target_dead_tuple_ratio))::bigint))),
                    0),
           COALESCE(sum(pg_stat_get_dead_tuples(c.oid)::bigint
                        + pg_stat_get_ins_since_vacuum(c.oid)::bigint), 0)
    INTO scanned_relation_count, fleet_max_target, total_debt_tuples
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN adaptive_autovacuum.table_policy tp
           ON tp.relid = c.oid
          AND tp.schema_name = n.nspname
          AND tp.relation_name = c.relname
    WHERE c.relkind = 'r'
      AND c.relpersistence <> 't'
      AND NOT (n.nspname = ANY (p.excluded_schemas))
      AND COALESCE(tp.enabled, true)
      AND adaptive_autovacuum._relation_bytes(c.relpages, pg_stat_get_live_tuples(c.oid),
                                              pg_stat_get_dead_tuples(c.oid), p.min_table_bytes,
                                              block_size, c.oid) >= p.min_table_bytes;

    /* Debt velocity: tuples/s since the previous sample, halved into the previous EMA. */
    cur_debt_velocity := NULL;
    IF sample_interval IS NOT NULL AND prev_debt_tuples IS NOT NULL THEN
        cur_debt_velocity := (total_debt_tuples - prev_debt_tuples)::double precision
                             / sample_interval;
        IF prev_debt_velocity IS NOT NULL THEN
            cur_debt_velocity := 0.5 * cur_debt_velocity + 0.5 * prev_debt_velocity;
        END IF;
    END IF;

    UPDATE adaptive_autovacuum.controller_state
    SET last_xid8 = cur_xid8,
        last_sample_at = clock_timestamp(),
        last_wal_bytes = cur_wal_bytes,
        last_debt_tuples = total_debt_tuples,
        debt_velocity = cur_debt_velocity,
        autovacuum_off_cycles = av_off_cycles,
        last_vacuum_io_bytes = cur_vac_io_bytes,
        vacuum_io_rate = cur_vac_io_rate;

    FOR r IN
        WITH active_vacuum AS
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
                /* PG18+ column; NULL on PG17 (see the jsonb note above). */
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
            /* Previous state joined once here instead of a per-relation lookup; NULL = never persisted. */
            rs.relid IS NOT NULL AS state_exists,
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
        LEFT JOIN adaptive_autovacuum.relation_state rs ON rs.relid = c.oid
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
            SELECT adaptive_autovacuum._relation_bytes(c.relpages, pg_stat_get_live_tuples(c.oid),
                                                       pg_stat_get_dead_tuples(c.oid), p.min_table_bytes,
                                                       block_size, c.oid) AS total_bytes
        ) sz
        LEFT JOIN active_vacuum av ON av.relid = c.oid
        /* Identity-checked: fingerprint mismatch (OID reuse / rename) is ignored. */
        LEFT JOIN adaptive_autovacuum.table_policy tp
               ON tp.relid = c.oid
              AND tp.schema_name = n.nspname
              AND tp.relation_name = c.relname
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

        /* r.prev_* is the before-image for the write-on-change test; previous.* is mutated this cycle. */
        previous := NULL;
        previous.relid := r.relid;
        previous.original_reloptions := r.prev_original_reloptions;
        previous.original_captured := COALESCE(r.prev_original_captured, false);
        previous.managed_values := COALESCE(r.prev_managed_values, '{}'::jsonb);
        previous.ownership_conflict := COALESCE(r.prev_ownership_conflict, false);
        previous.state := COALESCE(r.prev_state, 'normal');
        previous.consecutive_overdue := COALESCE(r.prev_consecutive_overdue, 0);
        previous.consecutive_healthy := COALESCE(r.prev_consecutive_healthy, 0);
        previous.last_change_at := r.prev_last_change_at;
        previous.last_vacuum_pid := r.prev_last_vacuum_pid;
        previous.last_vacuum_progress := r.prev_last_vacuum_progress;
        previous.vacuum_stalled_cycles := COALESCE(r.prev_vacuum_stalled_cycles, 0);
        previous.last_action := r.prev_last_action;

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
            IF previous.last_vacuum_pid IS NOT DISTINCT FROM r.vacuum_pid
               AND previous.last_vacuum_progress IS NOT DISTINCT FROM cur_vacuum_progress THEN
                vacuum_stalled_cycles := COALESCE(previous.vacuum_stalled_cycles, 0) + 1;
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
            healthy_cycles := LEAST(previous.consecutive_healthy + 1,
                                    p.healthy_cycles_before_restore);
        ELSE
            overdue_cycles := LEAST(previous.consecutive_overdue + 1,
                                    p.overdue_cycles_before_change);
            healthy_cycles := 0;
            overdue_relation_count := overdue_relation_count + 1;
        END IF;

        current_matches_managed := adaptive_autovacuum._managed_values_match(
            r.reloptions,
            previous.managed_values
        );

        IF previous.managed_values <> '{}'::jsonb AND NOT current_matches_managed THEN
            previous.ownership_conflict := true;
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
            desired_values := previous.managed_values;
        ELSIF relation_state LIKE 'wraparound_%' THEN
            desired_values := previous.managed_values
                              - 'autovacuum_vacuum_cost_limit'
                              - 'autovacuum_vacuum_cost_delay';
        ELSIF relation_state = 'horizon_blocked' THEN
            /* Horizon blocked: hold as-is, aggression cannot help and a restore would flap. */
            desired_values := previous.managed_values;
        ELSE
            desired_values := '{}'::jsonb;
        END IF;

        has_existing_cost_boost := previous.managed_values ? 'autovacuum_vacuum_cost_limit';
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
            prev_boost := NULLIF(previous.managed_values ->> 'autovacuum_vacuum_cost_limit', '')::integer;
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
           OR previous.state <> 'normal'
           OR previous.managed_values <> '{}'::jsonb
           OR previous.ownership_conflict THEN
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

        cooldown_ok := previous.last_change_at IS NULL
                       OR clock_timestamp() - previous.last_change_at
                          >= make_interval(secs => p.change_cooldown_seconds);

        should_apply := relation_state <> 'normal'
                        AND overdue_cycles >= p.overdue_cycles_before_change
                        AND cooldown_ok
                        AND r.vacuum_pid IS NULL
                        AND NOT previous.ownership_conflict
                        AND change_count < p.max_changes_per_cycle
                        AND desired_values IS DISTINCT FROM previous.managed_values;

        applied := false;
        action_error := NULL;
        action_name := 'observe';

        IF should_apply THEN
            action_name := CASE WHEN p.dry_run THEN 'propose_reloptions' ELSE 'set_reloptions' END;

            IF NOT p.dry_run THEN
                BEGIN
                    PERFORM adaptive_autovacuum._reconcile_relation_options(
                        r.fqname,
                        previous.original_reloptions,
                        previous.managed_values,
                        desired_values,
                        p.lock_timeout_ms
                    );
                    applied := true;
                    change_count := change_count + 1;
                EXCEPTION
                    WHEN lock_not_available OR query_canceled THEN
                        GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
                    WHEN OTHERS THEN
                        GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
                END;
            END IF;

            /* Transition log: attempted changes always, repeated dry-run proposals once per (state, action). */
            IF applied
               OR action_error IS NOT NULL
               OR previous.state IS DISTINCT FROM relation_state
               OR previous.last_action IS DISTINCT FROM action_name THEN
                INSERT INTO adaptive_autovacuum.decisions
                    (relid, relation_name, state, action, reason, host_metrics,
                     relation_metrics, proposed_reloptions, applied, error)
                VALUES
                    (r.relid, r.fqname, relation_state, action_name, reason, host_json,
                     relation_json, desired_values, applied, action_error);
            END IF;
        ELSIF relation_state <> 'normal' OR previous.ownership_conflict THEN
            action_name := CASE
                WHEN previous.ownership_conflict THEN 'ownership_conflict'
                WHEN relation_state = 'horizon_blocked' THEN 'horizon_blocked'
                WHEN relation_state LIKE 'backlog_%' AND NOT r.normal_autovacuum_enabled THEN 'autovacuum_disabled'
                WHEN r.vacuum_pid IS NOT NULL THEN 'vacuum_already_running'
                WHEN NOT cooldown_ok THEN 'cooldown'
                ELSE 'observe'
            END;

            /* Observation-only: logged on entering this (state, action) pair. */
            IF previous.state IS DISTINCT FROM relation_state
               OR previous.last_action IS DISTINCT FROM action_name THEN
                INSERT INTO adaptive_autovacuum.decisions
                    (relid, relation_name, state, action, reason, host_metrics,
                     relation_metrics, proposed_reloptions, applied, error)
                VALUES
                    (r.relid, r.fqname, relation_state, action_name, reason, host_json,
                     relation_json, desired_values, false,
                     CASE WHEN previous.ownership_conflict
                          THEN 'A managed reloption changed outside the controller; automatic writes are suspended.'
                          ELSE NULL END);
            END IF;
        ELSIF previous.state <> 'normal' THEN
            /* Return to normal closes the episode. */
            action_name := 'recovered';
            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied)
            VALUES
                (r.relid, r.fqname, relation_state, action_name,
                 format('Relation returned to normal (was %s).', previous.state),
                 host_json, relation_json, NULL, false);
        END IF;

        IF relation_state = 'normal'
           AND healthy_cycles >= p.healthy_cycles_before_restore
           AND previous.managed_values <> '{}'::jsonb
           AND NOT previous.ownership_conflict
           AND current_matches_managed
           AND cooldown_ok
           AND r.vacuum_pid IS NULL
           AND change_count < p.max_changes_per_cycle
        THEN
            action_name := CASE WHEN p.dry_run THEN 'propose_restore' ELSE 'restore_reloptions' END;
            applied := false;
            action_error := NULL;

            IF NOT p.dry_run THEN
                BEGIN
                    PERFORM adaptive_autovacuum._reconcile_relation_options(
                        r.fqname,
                        previous.original_reloptions,
                        previous.managed_values,
                        '{}'::jsonb,
                        p.lock_timeout_ms
                    );
                    applied := true;
                    change_count := change_count + 1;
                EXCEPTION
                    WHEN OTHERS THEN
                        GET STACKED DIAGNOSTICS action_error = MESSAGE_TEXT;
                END;
            END IF;

            /* Same transition rule: real restores always, repeated dry-run proposals once. */
            IF applied
               OR action_error IS NOT NULL
               OR previous.state IS DISTINCT FROM relation_state
               OR previous.last_action IS DISTINCT FROM action_name THEN
                INSERT INTO adaptive_autovacuum.decisions
                    (relid, relation_name, state, action, reason, host_metrics,
                     relation_metrics, proposed_reloptions, applied, error)
                VALUES
                    (r.relid, r.fqname, relation_state, action_name,
                     'Relation remained healthy for the configured restore window.',
                     host_json, relation_json, previous.managed_values, applied, action_error);
            END IF;

            IF applied THEN
                previous.original_reloptions := NULL;
                previous.original_captured := false;
                previous.managed_values := '{}'::jsonb;
            END IF;
        ELSIF applied AND action_name = 'set_reloptions' THEN
            IF NOT previous.original_captured THEN
                previous.original_reloptions := r.reloptions;
                previous.original_captured := true;
            END IF;
            previous.managed_values := desired_values;
        END IF;

        IF emergency_due
           AND p.emergency_vacuum_enabled
           AND NOT p.dry_run
           AND (r.vacuum_pid IS NULL OR emergency_takeover)
           AND NOT EXISTS
               (SELECT 1
                FROM adaptive_autovacuum.emergency_queue q
                WHERE q.relid = r.relid
                  AND q.status IN ('pending', 'running'))
           AND NOT EXISTS
               (SELECT 1
                FROM adaptive_autovacuum.emergency_queue q
                WHERE q.relid = r.relid
                  AND q.status = 'failed'
                  AND q.next_retry_at > clock_timestamp())
           /* Hard daily cap against any remaining retry-storm shape. */
           AND (SELECT count(*)
                FROM adaptive_autovacuum.emergency_queue q
                WHERE q.relid = r.relid
                  AND q.status = 'failed'
                  AND q.finished_at > clock_timestamp() - interval '24 hours') < 8
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

            INSERT INTO adaptive_autovacuum.emergency_queue
                (relid, relation_name, reason, priority, work_mem_mb,
                 cost_limit, cost_delay_ms, lock_timeout_ms, is_wraparound,
                 deadline_seconds)
            VALUES
                (r.relid, r.fqname, reason,
                 /* Deadline first (claim order), then age in millions of XIDs. */
                 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                 emergency_work_mem_mb,
                 CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                      ELSE p.emergency_cost_limit END,
                 CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                      ELSE p.emergency_cost_delay_ms END,
                 p.emergency_lock_timeout_ms,
                 true,
                 seconds_until_readonly);

            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied)
            VALUES
                (r.relid, r.fqname, relation_state,
                 CASE WHEN emergency_takeover
                      THEN 'queue_emergency_takeover'
                      ELSE 'queue_emergency_vacuum' END,
                 reason, host_json, relation_json, NULL, true);
        END IF;

        new_last_change_at := CASE WHEN applied THEN clock_timestamp()
                                   ELSE previous.last_change_at END;

        /* Persist only what a later cycle needs; rewrite on control change or hourly heartbeat. */
        state_needed := relation_state <> 'normal'
                        OR previous.managed_values <> '{}'::jsonb
                        OR previous.ownership_conflict
                        OR previous.original_captured
                        OR r.vacuum_pid IS NOT NULL
                        OR action_error IS NOT NULL
                        OR (new_last_change_at IS NOT NULL
                            AND clock_timestamp() - new_last_change_at
                                < make_interval(secs => p.change_cooldown_seconds));

        IF NOT state_needed THEN
            IF r.state_exists THEN
                DELETE FROM adaptive_autovacuum.relation_state
                WHERE relid = r.relid;
            END IF;
        ELSIF NOT r.state_exists
              OR r.prev_relation_name IS DISTINCT FROM r.fqname
              OR r.prev_original_reloptions IS DISTINCT FROM previous.original_reloptions
              OR r.prev_original_captured IS DISTINCT FROM previous.original_captured
              OR r.prev_managed_values IS DISTINCT FROM previous.managed_values
              OR r.prev_ownership_conflict IS DISTINCT FROM previous.ownership_conflict
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
            INSERT INTO adaptive_autovacuum.relation_state AS target
                (relid, relation_name, original_reloptions, original_captured, managed_values,
                 ownership_conflict, state, consecutive_overdue, consecutive_healthy,
                 last_seen_at, last_change_at, last_dead_tuples, last_live_tuples,
                 last_trigger, last_backlog_ratio,
                 last_inserts_since_vacuum, last_insert_backlog_ratio,
                 last_xid_age, last_mxid_age,
                 last_vacuum_pid, last_vacuum_progress, vacuum_stalled_cycles,
                 last_error, last_action)
            VALUES
                (r.relid, r.fqname, previous.original_reloptions, previous.original_captured, previous.managed_values,
                 previous.ownership_conflict, relation_state, overdue_cycles, healthy_cycles,
                 clock_timestamp(),
                 new_last_change_at,
                 r.dead_tuples, r.live_tuples, vacuum_trigger, backlog_ratio,
                 r.inserts_since_vacuum, insert_ratio,
                 r.xid_age, r.mxid_age,
                 r.vacuum_pid, cur_vacuum_progress, vacuum_stalled_cycles,
                 action_error, action_name)
            ON CONFLICT (relid) DO UPDATE
            SET relation_name = EXCLUDED.relation_name,
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
        END IF;
    END LOOP;

    /* Safety scan: relations the performance scan skipped; emergency branch only, never cancels. */
    FOR r IN
        WITH active_vacuum AS
        (
            SELECT pv.relid, pv.pid AS vacuum_pid
            FROM pg_stat_progress_vacuum pv
            WHERE pv.datid = (SELECT d.oid
                              FROM pg_catalog.pg_database d
                              WHERE d.datname = pg_catalog.current_database())
        )
        SELECT
            c.oid AS relid,
            format('%I.%I', n.nspname, c.relname) AS fqname,
            n.nspname,
            GREATEST(age(c.relfrozenxid),
                     COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
            GREATEST(mxid_age(c.relminmxid),
                     COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
            CASE
                WHEN adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age') IS NULL
                  OR adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age')::bigint < 0
                THEN freeze_max_age
                ELSE LEAST(freeze_max_age,
                           adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age')::bigint)
            END AS effective_xid_freeze_max_age,
            CASE
                WHEN adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age') IS NULL
                  OR adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age')::bigint < 0
                THEN multixact_freeze_max_age
                ELSE LEAST(multixact_freeze_max_age,
                           adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age')::bigint)
            END AS effective_mxid_freeze_max_age,
            av.vacuum_pid
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
        LEFT JOIN active_vacuum av ON av.relid = c.oid
        /* Identity-checked: fingerprint mismatch (OID reuse / rename) is ignored. */
        LEFT JOIN adaptive_autovacuum.table_policy tp
               ON tp.relid = c.oid
              AND tp.schema_name = n.nspname
              AND tp.relation_name = c.relname
        WHERE c.relkind IN ('r', 'm')
          AND c.relpersistence <> 't'
          AND n.nspname <> 'pg_toast'
          /* only relations the performance scan above did NOT evaluate */
          AND NOT (c.relkind = 'r'
                   AND NOT (n.nspname = ANY (p.excluded_schemas))
                   AND COALESCE(tp.enabled, true)
                   AND adaptive_autovacuum._relation_bytes(c.relpages, pg_stat_get_live_tuples(c.oid),
                                                           pg_stat_get_dead_tuples(c.oid), p.min_table_bytes,
                                                           block_size, c.oid) >= p.min_table_bytes)
          /* age already past this relation's stall line */
          AND (GREATEST(age(c.relfrozenxid),
                        COALESCE(age(tc.relfrozenxid), 0))::bigint
                   >= LEAST(p.emergency_xid_age,
                            ceil(p.emergency_stall_multiplier *
                                 CASE
                                     WHEN adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age') IS NULL
                                       OR adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age')::bigint < 0
                                     THEN freeze_max_age
                                     ELSE LEAST(freeze_max_age,
                                                adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age')::bigint)
                                 END)::bigint)
               OR GREATEST(mxid_age(c.relminmxid),
                           COALESCE(mxid_age(tc.relminmxid), 0))::bigint
                   >= LEAST(p.emergency_mxid_age,
                            ceil(p.emergency_stall_multiplier *
                                 CASE
                                     WHEN adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age') IS NULL
                                       OR adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age')::bigint < 0
                                     THEN multixact_freeze_max_age
                                     ELSE LEAST(multixact_freeze_max_age,
                                                adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age')::bigint)
                                 END)::bigint))
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
                INSERT INTO adaptive_autovacuum.decisions
                    (relid, relation_name, state, action, reason, host_metrics,
                     relation_metrics, proposed_reloptions, applied)
                VALUES
                    (r.relid, r.fqname, 'horizon_blocked', 'horizon_blocked',
                     format('Safety scan: XID age %s is past the stall line %s, but the cleanup horizon is held at age %s by a %s (%s); emergency escalation is suppressed until the blocker goes away.',
                            r.xid_age, stall_xid_age, horizon_age, horizon_kind, horizon_detail),
                     host_json,
                     jsonb_build_object('xid_age', r.xid_age,
                                        'mxid_age', r.mxid_age,
                                        'safety_scan', true),
                     NULL, false);
            END IF;
            CONTINUE;
        END IF;

        reason := format('Safety scan: no autovacuum is running although XID age %s / MXID age %s is past the stall line (%s / %s); the relation was invisible to the performance scan (size/schema/table-policy filters).',
                         r.xid_age, r.mxid_age, stall_xid_age, stall_mxid_age);
        critical_seen := true;

        IF p.dry_run OR NOT p.emergency_vacuum_enabled THEN
            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied)
            VALUES
                (r.relid, r.fqname, 'wraparound_critical', 'propose_emergency_vacuum',
                 reason, host_json,
                 jsonb_build_object('xid_age', r.xid_age,
                                    'mxid_age', r.mxid_age,
                                    'safety_scan', true),
                 NULL, false);
            CONTINUE;
        END IF;

        IF NOT EXISTS
               (SELECT 1
                FROM adaptive_autovacuum.emergency_queue q
                WHERE q.relid = r.relid
                  AND q.status IN ('pending', 'running'))
           AND NOT EXISTS
               (SELECT 1
                FROM adaptive_autovacuum.emergency_queue q
                WHERE q.relid = r.relid
                  AND q.status = 'failed'
                  AND q.next_retry_at > clock_timestamp())
           AND (SELECT count(*)
                FROM adaptive_autovacuum.emergency_queue q
                WHERE q.relid = r.relid
                  AND q.status = 'failed'
                  AND q.finished_at > clock_timestamp() - interval '24 hours') < 8
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

            INSERT INTO adaptive_autovacuum.emergency_queue
                (relid, relation_name, reason, priority, work_mem_mb,
                 cost_limit, cost_delay_ms, lock_timeout_ms, is_wraparound,
                 deadline_seconds)
            VALUES
                (r.relid, r.fqname, reason,
                 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                 emergency_work_mem_mb,
                 CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                      ELSE p.emergency_cost_limit END,
                 CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                      ELSE p.emergency_cost_delay_ms END,
                 p.emergency_lock_timeout_ms,
                 true,
                 CASE WHEN xid_rate IS NOT NULL AND xid_rate > 0
                      THEN GREATEST(2147483648 - 3000000 - r.xid_age, 0)::double precision / xid_rate
                      END);

            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied)
            VALUES
                (r.relid, r.fqname, 'wraparound_critical', 'queue_emergency_vacuum',
                 reason, host_json,
                 jsonb_build_object('xid_age', r.xid_age,
                                    'mxid_age', r.mxid_age,
                                    'safety_scan', true),
                 NULL, true);
        END IF;
    END LOOP;

    /* Local medians of the desired trigger settings (published and used in the cluster merge). */
    local_median_scale := NULL;
    local_median_thresh := NULL;
    local_median_ins_scale := NULL;
    local_median_ins_thresh := NULL;
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

    /* Cluster merge: fold others_summary in; medians = overdue-weighted averages. */
    cluster_db_count := COALESCE((others_summary ->> 'db_count')::integer, 0);
    cl_eligible := scanned_relation_count
                   + COALESCE((others_summary ->> 'eligible')::integer, 0);
    cl_overdue := overdue_relation_count
                  + COALESCE((others_summary ->> 'overdue')::integer, 0);
    cl_dead_overdue := dead_overdue_count
                       + COALESCE((others_summary ->> 'dead_overdue')::integer, 0);
    cl_insert_overdue := insert_overdue_count
                         + COALESCE((others_summary ->> 'insert_overdue')::integer, 0);
    cl_w_scale := COALESCE((others_summary ->> 'w_scale_sum')::double precision, 0)
                  + COALESCE(local_median_scale, 0) * dead_overdue_count;
    cl_w_thresh := COALESCE((others_summary ->> 'w_thresh_sum')::double precision, 0)
                   + COALESCE(local_median_thresh, 0) * dead_overdue_count;
    cl_w_ins_scale := COALESCE((others_summary ->> 'w_ins_scale_sum')::double precision, 0)
                      + COALESCE(local_median_ins_scale, 0) * insert_overdue_count;
    cl_w_ins_thresh := COALESCE((others_summary ->> 'w_ins_thresh_sum')::double precision, 0)
                       + COALESCE(local_median_ins_thresh, 0) * insert_overdue_count;
    cl_fleet_max := GREATEST(fleet_max_target,
                             COALESCE((others_summary ->> 'fleet_max_target')::bigint, 0));

    /* Debt trend: growth per sample interval relative to the cluster debt, with a deadband. */
    cl_debt_tuples := total_debt_tuples
                      + COALESCE((others_summary ->> 'debt_tuples')::bigint, 0);
    cl_debt_velocity := COALESCE(cur_debt_velocity, 0)
                        + COALESCE((others_summary ->> 'debt_velocity')::double precision, 0);
    backlog_growth := NULL;
    backlog_trend := 'unknown';
    IF sample_interval IS NOT NULL AND cur_debt_velocity IS NOT NULL THEN
        backlog_growth := cl_debt_velocity * sample_interval / GREATEST(cl_debt_tuples, 1)::double precision;
        backlog_trend := CASE WHEN backlog_growth > p.backlog_trend_deadband THEN 'growing'
                              WHEN backlog_growth < -p.backlog_trend_deadband THEN 'shrinking'
                              ELSE 'flat' END;
    END IF;
    /* Shrinking is only "under control" if the debt is projected to clear within the target. */
    drain_seconds := CASE WHEN cl_debt_velocity < 0
                          THEN cl_debt_tuples / -cl_debt_velocity END;
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
    IF NOT host_pressure AND cl_overdue > 0
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
    ELSIF cl_overdue = 0 AND NOT host_pressure AND autovacuum_enabled_global
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

    /* A raise must first prove itself: the previous applied raise has to show more throughput. */
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
        IF prev_sample_at IS NULL OR cur_vac_io_rate IS NULL OR raise_applied_at IS NULL
           OR raise_applied_at > prev_sample_at + sample_interval * interval '0.1 second' THEN
            recommended_cost_limit := current_global_cost_limit;
            recommended_cost_delay := current_global_cost_delay;
            recommendation_reason := recommendation_reason || format(
                ' The last cost raise (to %s / %s ms) has not yet been observed over a full'
                || ' check interval: holding.',
                raise_limit, trim(trailing '.' from to_char(raise_delay, 'FM999990.99')));
        ELSIF cur_vac_io_rate <= rate_before_raise
                                 * (1 + p.cost_raise_min_io_gain_percent / 100.0) THEN
            recommended_cost_limit := current_global_cost_limit;
            recommended_cost_delay := current_global_cost_delay;
            recommendation_reason := recommendation_reason || format(
                ' The last cost raise (to %s / %s ms) did not increase observed autovacuum'
                || ' throughput (%s MB/s before, %s MB/s after): storage, not the cost budget,'
                || ' is the limit; holding.',
                raise_limit, trim(trailing '.' from to_char(raise_delay, 'FM999990.99')),
                round((rate_before_raise / 1048576.0)::numeric, 1),
                round((cur_vac_io_rate / 1048576.0)::numeric, 1));
        END IF;
    END IF;
    /* Throughput cap: keep the delay (it smooths I/O), take only the limit raise that fits. */
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
            ' Throughput cap %s MB/s (recommendation_max_vacuum_mbps): %s.',
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

    UPDATE adaptive_autovacuum.controller_state
    SET backlog_free_cycles = free_cycles,
        baseline_settings = baseline_json;
    /* A backlog-free check closes the episode: the next incident's first raise is judged fresh. */
    IF cl_overdue = 0 AND raise_at IS NOT NULL THEN
        UPDATE adaptive_autovacuum.controller_state
        SET last_cost_raise_at = NULL,
            last_raise_cost_limit = NULL,
            last_raise_cost_delay = NULL,
            io_rate_before_raise = NULL;
        raise_at := NULL;
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
       OR (host_pressure AND NOT critical_seen) THEN
        recommended_workers := current_autovacuum_workers;
    ELSE
        /* Bounded doubling per step, toward the overdue count. */
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
        recommended_workers := GREATEST(recommended_workers,
                                        current_autovacuum_workers);

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
        IF host_pressure THEN
            SELECT GREATEST(s.boot_val::integer,
                            current_buffer_usage_limit_kb / 2)
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

    IF cluster_db_count > 0 THEN
        recommendation_reason := recommendation_reason || format(
            ' Cluster-wide evidence: %s databases, %s eligible relations, %s overdue.',
            cluster_db_count + 1, cl_eligible, cl_overdue);
    END IF;

    /* Incomplete cluster evidence (summary capacity exceeded): record the advice, never apply it. */
    evidence_complete := COALESCE((others_summary ->> 'evidence_complete')::boolean, true);
    IF NOT evidence_complete THEN
        recommendation_reason := recommendation_reason
            || ' Cluster evidence is incomplete (adaptive_autovacuum.max_tracked_databases exceeded): recorded only, not applied.';
    END IF;

    INSERT INTO adaptive_autovacuum.global_recommendations
        (host_metrics, overdue_relations, long_vacuums,
         delay_bound_long_vacuums, repeated_index_vacuum_cycles,
         recommended_cost_limit, recommended_cost_delay_ms,
         recommended_autovacuum_work_mem_kb, recommended_buffer_usage_limit_kb,
         recommended_autovacuum_workers,
         recommended_vacuum_scale_factor, recommended_vacuum_threshold,
         recommended_vacuum_max_threshold,
         recommended_insert_scale_factor, recommended_insert_threshold,
         recommended_analyze_scale_factor, recommended_analyze_threshold,
         maintenance_debt_tuples, maintenance_debt_velocity, backlog_trend,
         autovacuum_io_mbps, cost_ceiling_mbps,
         reason)
    VALUES
        (host_json, overdue_relation_count, long_vacuum_count,
         delay_bound_count, repeated_index_cycle_count,
         recommended_cost_limit, recommended_cost_delay,
         recommended_work_mem_kb, recommended_buffer_usage_limit_kb,
         recommended_workers,
         recommended_scale, recommended_thresh,
         recommended_max_thresh,
         recommended_ins_scale, recommended_ins_thresh,
         recommended_an_scale, recommended_an_thresh,
         cl_debt_tuples, cl_debt_velocity, backlog_trend,
         cur_vac_io_rate / 1048576.0,
         adaptive_autovacuum.vacuum_cost_ceiling_mbps(recommended_cost_limit, recommended_cost_delay,
                                                      page_hit_cost, block_size),
         recommendation_reason);

    /* autovacuum=off repair: the one non-numeric change; queued separately, only ever 'on'. */
    IF p.manage_global_settings AND NOT p.dry_run
       AND NOT autovacuum_enabled_global
       AND p.repair_disabled_autovacuum
       AND av_off_cycles >= p.repair_disabled_autovacuum_cycles
       AND (COALESCE(current_setting('adaptive_autovacuum.global_settings_database', true), '') = ''
            OR current_setting('adaptive_autovacuum.global_settings_database', true)
               = pg_catalog.current_database()::text)
       AND NOT EXISTS (SELECT 1
                       FROM adaptive_autovacuum.global_apply_queue q
                       WHERE q.guc_name = 'autovacuum'
                         AND q.status = 'pending') THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue(guc_name, desired_value, reason)
        VALUES ('autovacuum', 'on', recommendation_reason);
    END IF;

    /* Cluster-first: queue ALTER SYSTEM changes for the C worker (deduplicated, audited). */
    globals_applied_here := p.manage_global_settings AND NOT p.dry_run AND autovacuum_enabled_global
       AND evidence_complete
       AND (COALESCE(current_setting('adaptive_autovacuum.global_settings_database', true), '') = ''
            OR current_setting('adaptive_autovacuum.global_settings_database', true)
               = pg_catalog.current_database()::text);
    IF globals_applied_here THEN
        INSERT INTO adaptive_autovacuum.global_apply_queue(guc_name, desired_value, reason)
        SELECT cand.guc_name, cand.desired_value, recommendation_reason
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

    /* Remember a queued raise with the throughput seen before it; the next check judges it. */
    /* A pair still waiting in the queue is re-recommended each check: keep its first record. */
    IF globals_applied_here AND cost_raise
       AND (recommended_cost_limit > current_global_cost_limit
            OR recommended_cost_delay < current_global_cost_delay)
       AND (raise_limit IS DISTINCT FROM recommended_cost_limit
            OR raise_delay IS DISTINCT FROM
               trim(trailing '.' from to_char(recommended_cost_delay, 'FM999990.99'))::double precision) THEN
        UPDATE adaptive_autovacuum.controller_state
        SET last_cost_raise_at = clock_timestamp(),
            last_raise_cost_limit = recommended_cost_limit,
            last_raise_cost_delay = trim(trailing '.' from
                                         to_char(recommended_cost_delay, 'FM999990.99'))::double precision,
            io_rate_before_raise = COALESCE(cur_vac_io_rate, 0);
    END IF;

    UPDATE adaptive_autovacuum.global_apply_queue
    SET status = 'failed',
        error = 'Expired before a worker applied it.'
    WHERE status = 'pending'
      AND requested_at < clock_timestamp() - interval '1 hour';

    /* Never-analyzed tables: largest first within a time budget; graduated under host pressure. */
    moderate_pressure := host_load_per_cpu > p.high_load_per_cpu / 2
                         OR host_memory_percent < 2 * p.low_memory_percent
                         OR (p.high_wal_mbps > 0 AND wal_rate_mbps IS NOT NULL
                             AND wal_rate_mbps >= p.high_wal_mbps / 2);
    analyze_budget_ms := CASE WHEN host_pressure THEN 0
                              WHEN moderate_pressure THEN p.analyze_missing_stats_budget_ms / 4
                              ELSE p.analyze_missing_stats_budget_ms END;
    analyze_started_at := clock_timestamp();
    IF p.analyze_missing_stats AND analyze_budget_ms > 0 THEN
        FOR r IN
            SELECT c.oid AS relid,
                   format('%I.%I', n.nspname, c.relname) AS fqname,
                   pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            /* Identity-checked: fingerprint mismatch (OID reuse / rename) is ignored. */
            LEFT JOIN adaptive_autovacuum.table_policy tp
                   ON tp.relid = c.oid
                  AND tp.schema_name = n.nspname
                  AND tp.relation_name = c.relname
            WHERE c.relkind = 'r'
              AND c.relpersistence <> 't'
              AND NOT (n.nspname = ANY (p.excluded_schemas))
              AND COALESCE(tp.enabled, true)
              AND pg_stat_get_live_tuples(c.oid) > 0
              AND pg_stat_get_last_analyze_time(c.oid) IS NULL
              AND pg_stat_get_last_autoanalyze_time(c.oid) IS NULL
              /* Dry run proposes each table once; the transition log must not repeat per check. */
              AND (NOT p.dry_run
                   OR NOT EXISTS (SELECT 1 FROM adaptive_autovacuum.decisions d
                                  WHERE d.relid = c.oid AND d.action = 'propose_analyze'))
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

            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied, error)
            VALUES
                (r.relid, r.fqname, 'statistics_missing', action_name, reason,
                 host_json, jsonb_build_object('live_tuples', r.live_tuples),
                 NULL, applied, action_error);
        END LOOP;
    END IF;

    DELETE FROM adaptive_autovacuum.relation_state state
    WHERE state.last_seen_at < clock_timestamp() - interval '7 days'
      AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = state.relid);

    /* Drop table_policy rows for dropped relations; mismatched rows wait for re-adoption. */
    DELETE FROM adaptive_autovacuum.table_policy tp
    WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = tp.relid);

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

    /* This database's cycle summary, published to shared memory by the C worker. */
    o_eligible := scanned_relation_count;
    o_overdue := overdue_relation_count;
    o_dead_overdue := dead_overdue_count;
    o_insert_overdue := insert_overdue_count;
    o_fleet_max_target := fleet_max_target;
    o_median_scale := local_median_scale;
    o_median_thresh := local_median_thresh;
    o_median_ins_scale := local_median_ins_scale;
    o_median_ins_thresh := local_median_ins_thresh;
    o_debt_tuples := total_debt_tuples;
    o_debt_velocity := cur_debt_velocity;
    RETURN NEXT;
END
$$;

CREATE VIEW adaptive_autovacuum.relation_status AS
SELECT
    state.relid,
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
FROM adaptive_autovacuum.relation_state state;

COMMENT ON VIEW adaptive_autovacuum.relation_status IS
'Relations the controller currently has state for: non-normal, managed, in conflict, being vacuumed, cooling down, or with a failed action. Healthy unmanaged relations are absent by design. The last_* metric columns are as of the last row write (control change or hourly heartbeat), not of the last scan.';

CREATE VIEW adaptive_autovacuum.changed_tables AS
SELECT
    state.relation_name,
    change.option_name,
    adaptive_autovacuum._option_value(state.original_reloptions,
                                      change.option_name) AS original_value,
    change.option_value AS current_value,
    state.state,
    state.ownership_conflict,
    state.last_change_at
FROM adaptive_autovacuum.relation_state state,
     jsonb_each_text(state.managed_values) AS change(option_name, option_value)
WHERE state.managed_values <> '{}'::jsonb;

COMMENT ON VIEW adaptive_autovacuum.changed_tables IS
'One row per (relation, reloption) currently set by the controller: original value (NULL = was inherited from the global default) vs controller-set value.';

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

COMMENT ON TABLE adaptive_autovacuum.policy IS
'One-row policy table. enabled and dry_run are independent safety gates.';
COMMENT ON TABLE adaptive_autovacuum.relation_state IS
'Controller ownership, hysteresis counters, and reversible reloption state. Rows exist only for relations with something to remember (non-normal, managed, conflict, vacuum fingerprint, cooldown, error) and are rewritten only on a control change or hourly.';
COMMENT ON TABLE adaptive_autovacuum.decisions IS
'Transition log (UNLOGGED): one row when a relation enters a (state, action) pair, when a change is applied or fails, and when it returns to normal. Not a per-cycle trace.';
COMMENT ON TABLE adaptive_autovacuum.global_recommendations IS
'Cluster-level ALTER SYSTEM recommendations; the extension does not apply them automatically.';
COMMENT ON TABLE adaptive_autovacuum.emergency_queue IS
'Guarded manual VACUUM requests executed serially by database workers.';
COMMENT ON FUNCTION adaptive_autovacuum._run_cycle(double precision, integer, bigint, bigint, jsonb) IS
'Internal policy evaluator invoked by the background worker. The jsonb parameter carries the aggregate of the other databases'' latest cycle summaries; the returned row is this database''s summary.';

REVOKE ALL ON ALL TABLES IN SCHEMA adaptive_autovacuum FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA adaptive_autovacuum FROM PUBLIC;
GRANT USAGE ON SCHEMA adaptive_autovacuum TO PUBLIC;
GRANT SELECT ON adaptive_autovacuum.relation_status,
                adaptive_autovacuum.changed_tables,
                adaptive_autovacuum.latest_global_recommendation,
                adaptive_autovacuum.active_vacuums,
                adaptive_autovacuum.wraparound_status
TO PUBLIC;
/* Host metrics go to pg_monitor, not PUBLIC. */
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.host_metrics() TO pg_monitor;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.cluster_summary_status() TO pg_monitor;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.horizon_blocker() TO PUBLIC;


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
