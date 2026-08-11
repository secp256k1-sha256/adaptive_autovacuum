\echo Use "CREATE EXTENSION adaptive_autovacuum" to load this file. \quit

CREATE SCHEMA adaptive_autovacuum;
REVOKE ALL ON SCHEMA adaptive_autovacuum FROM PUBLIC;

CREATE FUNCTION adaptive_autovacuum.host_metrics()
RETURNS jsonb
AS 'MODULE_PATHNAME', 'adaptive_autovacuum_host_metrics'
LANGUAGE C
VOLATILE
PARALLEL UNSAFE;

CREATE TABLE adaptive_autovacuum.policy
(
    singleton                       boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    enabled                         boolean NOT NULL DEFAULT false,
    dry_run                         boolean NOT NULL DEFAULT true,
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
    max_scale_factor                double precision NOT NULL DEFAULT 0.20 CHECK (max_scale_factor >= min_scale_factor),

    backlog_elevated_ratio          double precision NOT NULL DEFAULT 1.50 CHECK (backlog_elevated_ratio >= 1),
    backlog_urgent_ratio            double precision NOT NULL DEFAULT 3.00 CHECK (backlog_urgent_ratio >= backlog_elevated_ratio),
    backlog_critical_ratio          double precision NOT NULL DEFAULT 6.00 CHECK (backlog_critical_ratio >= backlog_urgent_ratio),
    overdue_cycles_before_change    integer NOT NULL DEFAULT 2 CHECK (overdue_cycles_before_change >= 1),
    healthy_cycles_before_restore   integer NOT NULL DEFAULT 6 CHECK (healthy_cycles_before_restore >= 1),
    change_cooldown_seconds         integer NOT NULL DEFAULT 1800 CHECK (change_cooldown_seconds >= 0),
    lock_timeout_ms                 integer NOT NULL DEFAULT 250 CHECK (lock_timeout_ms >= 1),
    max_changes_per_cycle           integer NOT NULL DEFAULT 5 CHECK (max_changes_per_cycle >= 0),

    /* A table with live rows that was never analyzed (neither manually nor by
       autoanalyze) leaves the planner estimating from hardcoded defaults;
       each cycle the largest few such tables are analyzed one at a time. */
    analyze_missing_stats           boolean NOT NULL DEFAULT true,
    analyze_missing_stats_per_cycle integer NOT NULL DEFAULT 3 CHECK (analyze_missing_stats_per_cycle >= 0),

    manage_table_costs              boolean NOT NULL DEFAULT false,
    max_boosted_relations           integer NOT NULL DEFAULT 2 CHECK (max_boosted_relations >= 0),
    elevated_cost_limit             integer NOT NULL DEFAULT 1000 CHECK (elevated_cost_limit >= 200),
    urgent_cost_limit               integer NOT NULL DEFAULT 3000 CHECK (urgent_cost_limit >= elevated_cost_limit),
    critical_cost_limit             integer NOT NULL DEFAULT 6000 CHECK (critical_cost_limit >= urgent_cost_limit),
    elevated_cost_delay_ms          double precision NOT NULL DEFAULT 2.0 CHECK (elevated_cost_delay_ms >= 0),
    urgent_cost_delay_ms            double precision NOT NULL DEFAULT 1.0 CHECK (urgent_cost_delay_ms >= 0 AND urgent_cost_delay_ms <= elevated_cost_delay_ms),
    critical_cost_delay_ms          double precision NOT NULL DEFAULT 0.0 CHECK (critical_cost_delay_ms >= 0 AND critical_cost_delay_ms <= urgent_cost_delay_ms),
    boost_ramp_factor               double precision NOT NULL DEFAULT 2.0 CHECK (boost_ramp_factor >= 1.1 AND boost_ramp_factor <= 10),
    boost_total_cost_limit_budget   integer NOT NULL DEFAULT 10000 CHECK (boost_total_cost_limit_budget >= 1000),

    xid_warning_ratio               double precision NOT NULL DEFAULT 0.70 CHECK (xid_warning_ratio > 0 AND xid_warning_ratio < 1),
    mxid_warning_ratio              double precision NOT NULL DEFAULT 0.70 CHECK (mxid_warning_ratio > 0 AND mxid_warning_ratio < 1),
    /* Absolute table ages (in transactions) at which the emergency vacuum may
       fire.  Modeled on the AWS RDS early-warning guidance: reaching 1 billion
       while autovacuum_freeze_max_age (default 200M) is in force means the
       built-in forced autovacuum is failing to control the age, and there is
       still >1.1 billion transactions of headroom before the cluster goes
       read-only (~2.1 billion).  Ratio-of-freeze_max_age triggers were
       rejected: they would fire an unthrottled manual VACUUM in territory the
       cost-limited built-in anti-wraparound autovacuum handles routinely. */
    emergency_xid_age               bigint NOT NULL DEFAULT 1000000000 CHECK (emergency_xid_age >= 100000),
    emergency_mxid_age              bigint NOT NULL DEFAULT 1000000000 CHECK (emergency_mxid_age >= 100000),
    /* The operative "built-in never started" line is
       LEAST(emergency_xid_age, emergency_stall_multiplier x effective
       freeze_max_age): 1.5x means the forced autovacuum is 50% of its own
       trigger overdue and has still not appeared.  Must stay > 1.0 so the
       emergency can never fire before the built-in trigger point. */
    emergency_stall_multiplier      double precision NOT NULL DEFAULT 1.5 CHECK (emergency_stall_multiplier > 1.0),
    /* Minimum runtime of an anti-wraparound autovacuum before the controller
       may judge it hopeless (index-bound, projected to finish after the
       read-only cutoff) and take it over with the index-skipping profile. */
    emergency_takeover_min_runtime_seconds integer NOT NULL DEFAULT 3600 CHECK (emergency_takeover_min_runtime_seconds >= 60),

    long_vacuum_seconds             integer NOT NULL DEFAULT 1800 CHECK (long_vacuum_seconds >= 60),
    high_delay_fraction             double precision NOT NULL DEFAULT 0.25 CHECK (high_delay_fraction >= 0 AND high_delay_fraction <= 1),
    high_load_per_cpu               double precision NOT NULL DEFAULT 1.50 CHECK (high_load_per_cpu > 0),
    low_memory_percent              double precision NOT NULL DEFAULT 15.0 CHECK (low_memory_percent > 0 AND low_memory_percent < 100),

    recommendation_cost_limit_max   integer NOT NULL DEFAULT 10000 CHECK (recommendation_cost_limit_max >= 200),
    recommendation_delay_max_ms     integer NOT NULL DEFAULT 20 CHECK (recommendation_delay_max_ms >= 0),
    recommendation_work_mem_max_mb  integer NOT NULL DEFAULT 4096 CHECK (recommendation_work_mem_max_mb >= 64),
    work_mem_available_fraction     double precision NOT NULL DEFAULT 0.10 CHECK (work_mem_available_fraction > 0 AND work_mem_available_fraction <= 0.50),
    recommendation_workers_max      integer NOT NULL DEFAULT 8 CHECK (recommendation_workers_max BETWEEN 1 AND 64),

    emergency_vacuum_enabled        boolean NOT NULL DEFAULT true,
    emergency_work_mem_min_mb       integer NOT NULL DEFAULT 128 CHECK (emergency_work_mem_min_mb >= 64),
    emergency_work_mem_max_mb       integer NOT NULL DEFAULT 2048 CHECK (emergency_work_mem_max_mb >= emergency_work_mem_min_mb),
    emergency_cost_limit            integer NOT NULL DEFAULT 10000 CHECK (emergency_cost_limit >= 200),
    emergency_cost_delay_ms         integer NOT NULL DEFAULT 0 CHECK (emergency_cost_delay_ms >= 0),
    emergency_lock_timeout_ms       integer NOT NULL DEFAULT 5000 CHECK (emergency_lock_timeout_ms >= 1),

    history_retention_days          integer NOT NULL DEFAULT 30 CHECK (history_retention_days >= 1),
    updated_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by                      name NOT NULL DEFAULT current_user
);

INSERT INTO adaptive_autovacuum.policy(singleton) VALUES (true);

CREATE TABLE adaptive_autovacuum.table_policy
(
    relid                 oid PRIMARY KEY,
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
    CHECK (min_scale_factor IS NULL OR min_scale_factor >= 0),
    CHECK (max_scale_factor IS NULL OR max_scale_factor >= 0),
    CHECK (min_scale_factor IS NULL OR max_scale_factor IS NULL OR max_scale_factor >= min_scale_factor)
);

CREATE TABLE adaptive_autovacuum.relation_state
(
    relid                 oid PRIMARY KEY,
    relation_name         text NOT NULL,
    original_reloptions   text[],
    original_captured     boolean NOT NULL DEFAULT false,
    managed_values        jsonb NOT NULL DEFAULT '{}'::jsonb,
    ownership_conflict    boolean NOT NULL DEFAULT false,
    state                 text NOT NULL DEFAULT 'normal',
    consecutive_overdue   integer NOT NULL DEFAULT 0,
    consecutive_healthy   integer NOT NULL DEFAULT 0,
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
    last_error            text
);

CREATE TABLE adaptive_autovacuum.decisions
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

CREATE TABLE adaptive_autovacuum.global_recommendations
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
    recommended_autovacuum_workers  integer NOT NULL,
    recommended_vacuum_scale_factor double precision,
    recommended_vacuum_threshold    integer,
    recommended_vacuum_max_threshold integer,
    recommended_insert_scale_factor double precision,
    recommended_insert_threshold    integer,
    recommended_analyze_scale_factor double precision,
    recommended_analyze_threshold   integer,
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
    last_error          text
);

CREATE INDEX emergency_queue_status_idx
    ON adaptive_autovacuum.emergency_queue(status, priority DESC, requested_at);
CREATE UNIQUE INDEX emergency_queue_one_active_per_relation_idx
    ON adaptive_autovacuum.emergency_queue(relid)
    WHERE status IN ('pending', 'running');

/* One-row sample of the 64-bit transaction counter, refreshed every cycle.
   The delta between cycles gives the cluster's XID consumption rate, used to
   project whether a grinding anti-wraparound autovacuum can finish before the
   read-only cutoff. */
CREATE TABLE adaptive_autovacuum.controller_state
(
    only_row        boolean PRIMARY KEY DEFAULT true CHECK (only_row),
    last_xid8       bigint,
    last_sample_at  timestamptz
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

CREATE FUNCTION adaptive_autovacuum._run_cycle(
    host_load1 double precision,
    host_cpu_count integer,
    host_mem_available_bytes bigint,
    host_mem_total_bytes bigint)
RETURNS void
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

    host_memory_percent double precision;
    host_load_per_cpu double precision;
    host_metrics_available boolean;
    host_pressure boolean;
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
    recommendation_reason text;

    vacuum_trigger double precision;
    backlog_ratio double precision;
    insert_ratio double precision;
    pressure_ratio double precision;
    xid_ratio double precision;
    mxid_ratio double precision;
    cur_xid8 bigint;
    prev_xid8 bigint;
    prev_sample_at timestamptz;
    xid_rate double precision;
    stall_xid_age bigint;
    stall_mxid_age bigint;
    av_wraparound_running boolean;
    av_elapsed_seconds double precision;
    av_eta_seconds double precision;
    seconds_until_readonly double precision;
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
    host_pressure := host_memory_percent < p.low_memory_percent
                     OR host_load_per_cpu > p.high_load_per_cpu;

    host_json := jsonb_build_object(
        'load1', host_load1,
        'cpu_count', host_cpu_count,
        'load_per_cpu', host_load_per_cpu,
        'mem_available_bytes', host_mem_available_bytes,
        'mem_total_bytes', host_mem_total_bytes,
        'mem_available_percent', host_memory_percent,
        'memory_metrics_available', host_metrics_available,
        'pressure', host_pressure
    );

    SELECT setting::boolean INTO autovacuum_enabled_global
    FROM pg_settings WHERE name = 'autovacuum';

    SELECT setting::bigint INTO freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';

    SELECT setting::bigint INTO multixact_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_multixact_freeze_max_age';

    /* XID consumption rate (transactions/second) from the 64-bit counter
       delta since the previous cycle; NULL on the first cycle or when the
       elapsed window is too small to be meaningful. */
    cur_xid8 := pg_catalog.pg_current_xact_id()::text::bigint;
    SELECT cs.last_xid8, cs.last_sample_at
    INTO prev_xid8, prev_sample_at
    FROM adaptive_autovacuum.controller_state cs;
    xid_rate := NULL;
    IF prev_xid8 IS NOT NULL
       AND prev_sample_at IS NOT NULL
       AND cur_xid8 > prev_xid8
       AND clock_timestamp() > prev_sample_at + interval '1 second' THEN
        xid_rate := (cur_xid8 - prev_xid8)::double precision /
                    extract(epoch FROM clock_timestamp() - prev_sample_at);
    END IF;
    UPDATE adaptive_autovacuum.controller_state
    SET last_xid8 = cur_xid8, last_sample_at = clock_timestamp();

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
              /* delay_time exists only on PG18+; the jsonb detour keeps this
                 parseable on PG17, where the filter is simply never true and
                 delay-bound detection stays inactive. */
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
    ELSIF host_pressure THEN
        recommended_cost_limit := GREATEST(200, floor(current_global_cost_limit * 0.75)::integer);
        recommended_cost_delay := LEAST(p.recommendation_delay_max_ms,
                                        GREATEST(current_global_cost_delay, 2.0) * 1.5);
        recommendation_reason := 'Host pressure is high; reduce vacuum I/O aggression.';
    ELSIF delay_bound_count > 0 THEN
        recommended_cost_limit := LEAST(p.recommendation_cost_limit_max,
                                        GREATEST(200, current_global_cost_limit * 2));
        recommended_cost_delay := GREATEST(0, current_global_cost_delay / 2.0);
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
            recommended_work_mem_kb := current_autovacuum_work_mem_kb;
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

    FOR r IN
        WITH active_vacuum AS
        (
            SELECT
                pv.relid,
                pv.pid AS vacuum_pid,
                pv.phase,
                pv.heap_blks_total,
                pv.heap_blks_scanned,
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
        )
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
            /* TOAST-aware: the TOAST relation has its own relfrozenxid and
               can lag the main heap; wraparound is driven by the older one. */
            GREATEST(age(c.relfrozenxid),
                     COALESCE(age(tc.relfrozenxid), 0))::bigint AS xid_age,
            GREATEST(mxid_age(c.relminmxid),
                     COALESCE(mxid_age(tc.relminmxid), 0))::bigint AS mxid_age,
            autovacuum_enabled_global
                AND COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_enabled')::boolean, true)
                AS normal_autovacuum_enabled,
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
            COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_threshold')::double precision,
                     current_vacuum_threshold) AS vacuum_threshold,
            COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_scale_factor')::double precision,
                     current_vacuum_scale_factor) AS vacuum_scale_factor,
            COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_max_threshold')::double precision,
                     current_vacuum_max_threshold) AS vacuum_max_threshold,
            pg_stat_get_ins_since_vacuum(c.oid)::bigint AS inserts_since_vacuum,
            COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_insert_threshold')::double precision,
                     current_insert_threshold) AS insert_threshold,
            COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_insert_scale_factor')::double precision,
                     current_insert_scale_factor) AS insert_scale_factor,
            av.vacuum_pid,
            av.phase,
            av.heap_blks_total,
            av.heap_blks_scanned,
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
            tp.max_scale_factor AS table_scale_max
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
        CROSS JOIN LATERAL (
            /* relpages avoids per-relation locks of pg_total_relation_size();
               fall back to the exact size while the relation is unanalyzed. */
            SELECT CASE WHEN c.relpages > 0
                        THEN c.relpages::bigint
                             * pg_catalog.current_setting('block_size')::bigint
                        ELSE pg_total_relation_size(c.oid)
                   END AS total_bytes
        ) sz
        LEFT JOIN active_vacuum av ON av.relid = c.oid
        LEFT JOIN adaptive_autovacuum.table_policy tp ON tp.relid = c.oid
        WHERE c.relkind = 'r'
          AND c.relpersistence <> 't'
          AND NOT (n.nspname = ANY (p.excluded_schemas))
          AND COALESCE(tp.enabled, true)
          AND sz.total_bytes >= p.min_table_bytes
        ORDER BY
            GREATEST(
                GREATEST(age(c.relfrozenxid),
                         COALESCE(age(tc.relfrozenxid), 0))::double precision / NULLIF(
                    CASE
                        WHEN adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age') IS NULL
                          OR adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age')::bigint < 0
                        THEN freeze_max_age
                        ELSE LEAST(freeze_max_age, adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_freeze_max_age')::bigint)
                    END, 0),
                GREATEST(mxid_age(c.relminmxid),
                         COALESCE(mxid_age(tc.relminmxid), 0))::double precision / NULLIF(
                    CASE
                        WHEN adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age') IS NULL
                          OR adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age')::bigint < 0
                        THEN multixact_freeze_max_age
                        ELSE LEAST(multixact_freeze_max_age, adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_multixact_freeze_max_age')::bigint)
                    END, 0),
                pg_stat_get_dead_tuples(c.oid)::double precision /
                    GREATEST(
                        1,
                        COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_threshold')::double precision,
                                 current_vacuum_threshold)
                        + COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_scale_factor')::double precision,
                                   current_vacuum_scale_factor)
                          * GREATEST(c.reltuples, 0)
                    ),
                CASE
                    WHEN COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_insert_threshold')::double precision,
                                  current_insert_threshold) < 0
                    THEN 0
                    ELSE pg_stat_get_ins_since_vacuum(c.oid)::double precision /
                         GREATEST(
                             1,
                             COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_insert_threshold')::double precision,
                                      current_insert_threshold)
                             + COALESCE(adaptive_autovacuum._option_value(c.reloptions, 'autovacuum_vacuum_insert_scale_factor')::double precision,
                                        current_insert_scale_factor)
                               * GREATEST(c.reltuples, 0)
                         )
                END
            ) DESC
    LOOP
        /* On PG17 vacuum_max_threshold is NULL (the GUC and reloption do not
           exist): NULL < 0 is not true and LEAST ignores NULLs, so this
           degrades exactly to the uncapped PG17 trigger formula. */
        IF r.vacuum_max_threshold < 0 THEN
            vacuum_trigger := r.vacuum_threshold
                              + r.vacuum_scale_factor * GREATEST(r.reltuples, 0);
        ELSE
            vacuum_trigger := LEAST(r.vacuum_max_threshold,
                                    r.vacuum_threshold
                                    + r.vacuum_scale_factor * GREATEST(r.reltuples, 0));
        END IF;

        scanned_relation_count := scanned_relation_count + 1;

        vacuum_trigger := GREATEST(vacuum_trigger, 1);
        backlog_ratio := r.dead_tuples / vacuum_trigger;

        /* A negative effective insert threshold means insert-driven vacuums
           are deliberately disabled for this relation; respect that. */
        IF r.insert_threshold IS NULL OR r.insert_threshold < 0 THEN
            insert_ratio := 0;
        ELSE
            insert_ratio := r.inserts_since_vacuum /
                            GREATEST(1, r.insert_threshold
                                        + r.insert_scale_factor
                                          * GREATEST(r.reltuples, 0));
        END IF;
        pressure_ratio := GREATEST(backlog_ratio, insert_ratio);
        xid_ratio := r.xid_age::double precision / NULLIF(r.effective_xid_freeze_max_age, 0);
        mxid_ratio := r.mxid_age::double precision / NULLIF(r.effective_mxid_freeze_max_age, 0);

        /* The emergency triggers on EVIDENCE that the built-in anti-wraparound
           autovacuum is failing, judged from its own behavior; the absolute
           emergency_*_age (default 1B, ~50% of the read-only cutoff, per the
           AWS RDS early-warning model) is the backstop cap.

           never-started: no vacuum is running on the relation although its age
           is emergency_stall_multiplier x past the point where core would have
           started a forced vacuum (capped by the absolute backstop).

           takeover: an anti-wraparound autovacuum HAS been running for at
           least emergency_takeover_min_runtime_seconds and either the age
           still blew past the stall line while it ground on, or its heap
           progress projects completion after the read-only cutoff at the
           measured XID consumption rate.  Index-bound vacuums are the typical
           culprit; the takeover profile skips index cleanup entirely.
           A manual (non-autovacuum) vacuum is never judged or taken over. */
        stall_xid_age := LEAST(p.emergency_xid_age,
                               ceil(p.emergency_stall_multiplier
                                    * COALESCE(NULLIF(r.effective_xid_freeze_max_age, 0),
                                               freeze_max_age))::bigint);
        stall_mxid_age := LEAST(p.emergency_mxid_age,
                                ceil(p.emergency_stall_multiplier
                                     * COALESCE(NULLIF(r.effective_mxid_freeze_max_age, 0),
                                                multixact_freeze_max_age))::bigint);

        /* Any AUTOVACUUM worker on the relation counts: past the wraparound
           trigger point every autovacuum runs aggressively and does the
           freezing work, but a dead-tuple-triggered one is NOT tagged
           "(to prevent wraparound)" — gating on the tag would miss the common
           production shape (old age + dead tuples).  Manual vacuums are still
           excluded and are never judged or cancelled. */
        av_wraparound_running := r.vacuum_pid IS NOT NULL
                                 AND COALESCE(r.is_autovacuum, false);
        av_elapsed_seconds := extract(epoch FROM COALESCE(r.vacuum_elapsed, interval '0'));

        av_eta_seconds := NULL;
        IF av_wraparound_running AND COALESCE(r.heap_blks_scanned, 0) > 0 THEN
            av_eta_seconds := av_elapsed_seconds
                              * GREATEST(COALESCE(r.heap_blks_total, 0) - r.heap_blks_scanned, 0)::double precision
                              / r.heap_blks_scanned;
        END IF;
        seconds_until_readonly := NULL;
        IF xid_rate IS NOT NULL AND xid_rate > 0 THEN
            seconds_until_readonly :=
                GREATEST(2147483648 - 3000000 - r.xid_age, 0)::double precision / xid_rate;
        END IF;

        emergency_takeover := av_wraparound_running
            AND av_elapsed_seconds >= p.emergency_takeover_min_runtime_seconds
            AND (r.xid_age >= stall_xid_age
                 OR r.mxid_age >= stall_mxid_age
                 OR (av_eta_seconds IS NOT NULL
                     AND seconds_until_readonly IS NOT NULL
                     AND av_eta_seconds > seconds_until_readonly));

        emergency_due := emergency_takeover
            OR (r.vacuum_pid IS NULL
                AND (r.xid_age >= stall_xid_age OR r.mxid_age >= stall_mxid_age));

        IF emergency_due THEN
            relation_state := 'wraparound_critical';
            IF emergency_takeover THEN
                reason := format('Anti-wraparound autovacuum (pid %s) has been running %s s on this table (heap %s/%s blocks, %s index pass(es), phase %s) with no sign of finishing before the wraparound cutoff (age %s, stall line %s, projected remaining %s s vs %s s of XID headroom); taking over with the index-skipping profile.',
                                 r.vacuum_pid, round(av_elapsed_seconds),
                                 COALESCE(r.heap_blks_scanned, 0), COALESCE(r.heap_blks_total, 0),
                                 COALESCE(r.index_vacuum_count, 0), COALESCE(r.phase, '?'),
                                 r.xid_age, stall_xid_age,
                                 COALESCE(round(av_eta_seconds)::text, 'n/a'),
                                 COALESCE(round(seconds_until_readonly)::text, 'n/a'));
            ELSE
                reason := format('No anti-wraparound autovacuum has started on this table although its age (%s XIDs / %s MXIDs) is past the stall line (%s/%s = %s x freeze_max_age, capped at the absolute limit %s/%s); the built-in mechanism is not responding.',
                                 r.xid_age, r.mxid_age, stall_xid_age, stall_mxid_age,
                                 trim(trailing '.' from to_char(p.emergency_stall_multiplier, 'FM990.99')),
                                 p.emergency_xid_age, p.emergency_mxid_age);
            END IF;
        ELSIF xid_ratio >= p.xid_warning_ratio OR mxid_ratio >= p.mxid_warning_ratio THEN
            relation_state := 'wraparound_warning';
            reason := format('XID/MXID age ratio vs freeze_max_age is elevated (xid=%s, mxid=%s); the forced autovacuum will handle this — prioritized only.', to_char(xid_ratio, 'FM0.000'), to_char(mxid_ratio, 'FM0.000'));
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

        previous := NULL;
        SELECT * INTO previous
        FROM adaptive_autovacuum.relation_state
        WHERE relid = r.relid;

        IF NOT FOUND THEN
            previous.relid := r.relid;
            previous.original_reloptions := NULL;
            previous.original_captured := false;
            previous.managed_values := '{}'::jsonb;
            previous.ownership_conflict := false;
            previous.consecutive_overdue := 0;
            previous.consecutive_healthy := 0;
            previous.last_change_at := NULL;
        END IF;

        IF relation_state = 'normal' THEN
            overdue_cycles := 0;
            healthy_cycles := previous.consecutive_healthy + 1;
        ELSE
            overdue_cycles := previous.consecutive_overdue + 1;
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

        /* The fleet's largest per-relation dead-tuple target drives the
           cluster-wide PG18 trigger ceiling (autovacuum_vacuum_max_threshold). */
        fleet_max_target := GREATEST(fleet_max_target, target_dead_tuples);

        /* Feed the mistuned-baseline detector: what would this relation want
           as its trigger settings if the dead-tuple side is overdue? */
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
        ELSE
            desired_values := '{}'::jsonb;
        END IF;

        has_existing_cost_boost := previous.managed_values ? 'autovacuum_vacuum_cost_limit';
        wants_cost_boost := p.manage_table_costs
                            AND relation_state <> 'normal'
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

            /*
             * Ramp instead of jumping to the tier maximum: a boost enters at
             * the elevated tier and multiplies by boost_ramp_factor once per
             * change window while the relation stays overdue, capped by the
             * current severity tier (which also ramps a boost back down when
             * severity drops).
             */
            prev_boost := NULLIF(previous.managed_values ->> 'autovacuum_vacuum_cost_limit', '')::integer;
            IF prev_boost IS NULL THEN
                desired_cost_limit := LEAST(tier_cost_limit, p.elevated_cost_limit);
            ELSE
                desired_cost_limit := LEAST(tier_cost_limit,
                                            GREATEST(prev_boost,
                                                     ceil(prev_boost * p.boost_ramp_factor)::integer));
            END IF;
            desired_cost_delay := tier_cost_delay;

            /*
             * Cluster-wide admission budget: the sum of boosted per-table
             * cost limits stays within boost_total_cost_limit_budget so that
             * several simultaneous boosts cannot overwhelm the host with
             * vacuum I/O.
             */
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
            'antiwraparound', r.antiwraparound
        );

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

            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied, error)
            VALUES
                (r.relid, r.fqname, relation_state, action_name, reason, host_json,
                 relation_json, desired_values, applied, action_error);
        ELSIF relation_state <> 'normal' OR previous.ownership_conflict THEN
            action_name := CASE
                WHEN previous.ownership_conflict THEN 'ownership_conflict'
                WHEN relation_state LIKE 'backlog_%' AND NOT r.normal_autovacuum_enabled THEN 'autovacuum_disabled'
                WHEN r.vacuum_pid IS NOT NULL THEN 'vacuum_already_running'
                WHEN NOT cooldown_ok THEN 'cooldown'
                ELSE 'observe'
            END;

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

            INSERT INTO adaptive_autovacuum.decisions
                (relid, relation_name, state, action, reason, host_metrics,
                 relation_metrics, proposed_reloptions, applied, error)
            VALUES
                (r.relid, r.fqname, relation_state, action_name,
                 'Relation remained healthy for the configured restore window.',
                 host_json, relation_json, previous.managed_values, applied, action_error);

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

            /* Takeover: cancel the hopeless autovacuum so the emergency
               worker can acquire the relation lock.  Never cancels a manual
               vacuum (emergency_takeover requires is_autovacuum). */
            IF emergency_takeover THEN
                PERFORM pg_catalog.pg_cancel_backend(r.vacuum_pid);
            END IF;

            INSERT INTO adaptive_autovacuum.emergency_queue
                (relid, relation_name, reason, priority, work_mem_mb,
                 cost_limit, cost_delay_ms, lock_timeout_ms, is_wraparound)
            VALUES
                (r.relid, r.fqname, reason,
                 /* Worst tables first: priority = age in millions of
                    transactions, so a 1.8B-age table outranks a 1.0B one. */
                 1000 + (GREATEST(r.xid_age, r.mxid_age) / 1000000)::integer,
                 emergency_work_mem_mb,
                 CASE WHEN host_pressure THEN GREATEST(200, p.emergency_cost_limit / 2)
                      ELSE p.emergency_cost_limit END,
                 CASE WHEN host_pressure THEN GREATEST(1, p.emergency_cost_delay_ms)
                      ELSE p.emergency_cost_delay_ms END,
                 p.emergency_lock_timeout_ms,
                 true);

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

        INSERT INTO adaptive_autovacuum.relation_state AS target
            (relid, relation_name, original_reloptions, original_captured, managed_values,
             ownership_conflict, state, consecutive_overdue, consecutive_healthy,
             last_seen_at, last_change_at, last_dead_tuples, last_live_tuples,
             last_trigger, last_backlog_ratio,
             last_inserts_since_vacuum, last_insert_backlog_ratio,
             last_xid_age, last_mxid_age, last_error)
        VALUES
            (r.relid, r.fqname, previous.original_reloptions, previous.original_captured, previous.managed_values,
             previous.ownership_conflict, relation_state, overdue_cycles, healthy_cycles,
             clock_timestamp(),
             CASE WHEN applied THEN clock_timestamp() ELSE previous.last_change_at END,
             r.dead_tuples, r.live_tuples, vacuum_trigger, backlog_ratio,
             r.inserts_since_vacuum, insert_ratio,
             r.xid_age, r.mxid_age, action_error)
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
            last_error = EXCLUDED.last_error;
    END LOOP;

    IF NOT host_pressure AND overdue_relation_count > 0
       AND recommendation_reason = 'No cluster-level cost change is currently justified.'
    THEN
        recommended_cost_limit := LEAST(p.recommendation_cost_limit_max,
                                        GREATEST(200, current_global_cost_limit * 2));
        recommended_cost_delay := GREATEST(0, current_global_cost_delay / 2.0);
        recommendation_reason := format('%s overdue relations were found without host pressure.', overdue_relation_count);
    END IF;

    /*
     * Worker-count recommendation.  Deliberately NOT gated on host pressure:
     * PostgreSQL splits the shared vacuum_cost_limit across running workers,
     * so more workers add parallelism without raising total un-boosted vacuum
     * I/O.  When every worker slot is busy and relations are overdue, more
     * workers is the fix regardless of cost settings; cost boosts can follow
     * once a relaxed window arrives.
     */
    IF NOT autovacuum_enabled_global
       OR (overdue_relation_count <= current_autovacuum_workers
           AND NOT (av_workers_running >= current_autovacuum_workers
                    AND overdue_relation_count > 0)) THEN
        recommended_workers := current_autovacuum_workers;
    ELSE
        recommended_workers := GREATEST(overdue_relation_count,
                                        current_autovacuum_workers + 1);
        /* PG18 caps reloadable raises at autovacuum_worker_slots; PG17 has no
           slots concept (the GUC itself needs a restart there), so the
           recommendation is bounded by policy alone and stays record-only. */
        recommended_workers := LEAST(recommended_workers,
                                     GREATEST(1, host_cpu_count / 4),
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
                    || ' overdue; raise autovacuum_max_workers to %s (reloadable;'
                    || ' the shared vacuum_cost_limit is split across workers, so'
                    || ' this does not raise total un-boosted vacuum I/O; capped by'
                    || ' autovacuum_worker_slots=%s which needs a restart to raise).',
                    av_workers_running, current_autovacuum_workers,
                    overdue_relation_count, recommended_workers,
                    autovacuum_worker_slots_cfg);
            ELSE
                recommendation_reason := recommendation_reason || format(
                    ' %s of %s autovacuum workers are busy while %s relations are'
                    || ' overdue; raise autovacuum_max_workers to %s (on'
                    || ' PostgreSQL 17 this requires a server restart, so it is'
                    || ' recorded here and never applied automatically).',
                    av_workers_running, current_autovacuum_workers,
                    overdue_relation_count, recommended_workers);
            END IF;
        END IF;
    END IF;

    /*
     * Mistuned-baseline detector: per-table reloptions are meant for outlier
     * relations.  When a large share of eligible relations is overdue at once
     * the global trigger settings are wrong, and the DBA should fix the
     * baseline instead; recommend the median of the per-relation desired
     * settings as the new cluster-wide baseline.
     */
    recommended_scale := NULL;
    recommended_thresh := NULL;
    recommended_max_thresh := NULL;
    recommended_an_scale := NULL;
    recommended_an_thresh := NULL;
    IF dead_overdue_count >= 3
       AND dead_overdue_count * 4 >= scanned_relation_count THEN
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO recommended_scale
        FROM unnest(overdue_scale_factors) AS v;

        SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v))::integer
        INTO recommended_thresh
        FROM unnest(overdue_thresholds) AS v;

        /* Keep planner statistics in step with the corrected vacuum baseline:
           analyze at half the vacuum scale factor (PostgreSQL's default
           ratio), with sane floors. */
        recommended_an_scale := GREATEST(0.005, recommended_scale * 0.5);
        recommended_an_thresh := GREATEST(50, recommended_thresh / 2);

        recommendation_reason := recommendation_reason || format(
            ' The global baseline appears mistuned: %s of %s eligible relations'
            || ' are overdue on dead-tuple backlog; setting cluster-wide'
            || ' autovacuum_vacuum_scale_factor ~ %s, autovacuum_vacuum_threshold ~ %s'
            || ' (analyze baseline in proportion: %s / %s)'
            || ' so that per-table overrides remain the exception.',
            dead_overdue_count, scanned_relation_count,
            trim(trailing '.' from to_char(recommended_scale, 'FM0.9999')),
            recommended_thresh,
            trim(trailing '.' from to_char(recommended_an_scale, 'FM0.9999')),
            recommended_an_thresh);
    END IF;

    /*
     * PostgreSQL 18 trigger formula:
     *   MIN(max_threshold, threshold + scale_factor * reltuples).
     * The ceiling is what lets one sane percentage scale factor coexist with
     * very large tables, so derive it from the fleet instead of a constant:
     * the dead-tuple target of the LARGEST eligible relation
     * (target_dead_tuple_ratio x its rows, clamped to the policy bounds).
     * Smaller relations keep triggering via the scale factor because their
     * computed trigger stays below the ceiling.  Hysteresis: tighten when the
     * current ceiling is disabled or >10% looser than derived; raise only
     * when it is grossly over-tight (< half of derived); anything in between
     * is respected as operator intent.
     */
    IF server_vnum >= 180000
       AND fleet_max_target > 0
       AND (current_vacuum_max_threshold < 0
            OR current_vacuum_max_threshold > fleet_max_target * 1.10
            OR current_vacuum_max_threshold < fleet_max_target * 0.50) THEN
        recommended_max_thresh := fleet_max_target::integer;
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
    IF insert_overdue_count >= 3
       AND insert_overdue_count * 4 >= scanned_relation_count THEN
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
        INTO recommended_ins_scale
        FROM unnest(overdue_insert_scale_factors) AS v;

        SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v))::integer
        INTO recommended_ins_thresh
        FROM unnest(overdue_insert_thresholds) AS v;

        recommendation_reason := recommendation_reason || format(
            ' The insert-vacuum baseline appears mistuned: %s of %s eligible'
            || ' relations are overdue on insert backlog; setting cluster-wide'
            || ' autovacuum_vacuum_insert_scale_factor ~ %s and'
            || ' autovacuum_vacuum_insert_threshold ~ %s.',
            insert_overdue_count, scanned_relation_count,
            trim(trailing '.' from to_char(recommended_ins_scale, 'FM0.9999')),
            recommended_ins_thresh);
    END IF;

    /* autovacuum_freeze_max_age sanity check.  Record-only: the GUC has
       postmaster context, so it cannot be applied via ALTER SYSTEM + reload
       and a DBA must change it deliberately. */
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

    INSERT INTO adaptive_autovacuum.global_recommendations
        (host_metrics, overdue_relations, long_vacuums,
         delay_bound_long_vacuums, repeated_index_vacuum_cycles,
         recommended_cost_limit, recommended_cost_delay_ms,
         recommended_autovacuum_work_mem_kb, recommended_autovacuum_workers,
         recommended_vacuum_scale_factor, recommended_vacuum_threshold,
         recommended_vacuum_max_threshold,
         recommended_insert_scale_factor, recommended_insert_threshold,
         recommended_analyze_scale_factor, recommended_analyze_threshold,
         reason)
    VALUES
        (host_json, overdue_relation_count, long_vacuum_count,
         delay_bound_count, repeated_index_cycle_count,
         recommended_cost_limit, recommended_cost_delay,
         recommended_work_mem_kb, recommended_workers,
         recommended_scale, recommended_thresh,
         recommended_max_thresh,
         recommended_ins_scale, recommended_ins_thresh,
         recommended_an_scale, recommended_an_thresh,
         recommendation_reason);

    /*
     * Cluster-first management: autovacuum is a cluster-wide phenomenon (one
     * worker pool, one cost budget), so when enabled the recommendations are
     * queued for the C worker to APPLY via ALTER SYSTEM + reload.  Per-table
     * reloptions remain the tool for outlier relations only.  Changes are
     * deduplicated (one pending row per GUC, no-op values filtered) and
     * audited with their pre-change value.  There is deliberately NO per-GUC
     * cooldown: correlated settings must be able to move together — raising
     * autovacuum_max_workers alone splits the same cost_limit across more
     * workers, so the cost side has to be able to follow on the very next
     * cycle instead of starving until a timer expires.  The naptime between
     * cycles and the at-most-doubling step are the pacing.
     * autovacuum_max_workers only ratchets up automatically; lowering it is
     * left to the DBA.
     */
    IF p.manage_global_settings AND NOT p.dry_run AND autovacuum_enabled_global THEN
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
             /* Reloadable only on PG18+ (worker slots); on PG17 the GUC is
                PGC_POSTMASTER, so it stays a recorded recommendation and is
                never queued for ALTER SYSTEM. */
             CASE WHEN server_vnum >= 180000
                       AND recommended_workers > current_autovacuum_workers
                  THEN recommended_workers::text END,
             current_autovacuum_workers::text),
            ('autovacuum_work_mem',
             recommended_work_mem_kb::text,
             current_autovacuum_work_mem_kb::text),
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
          AND NOT EXISTS (SELECT 1
                          FROM adaptive_autovacuum.global_apply_queue q
                          WHERE q.guc_name = cand.guc_name
                            AND q.status = 'pending');
    END IF;

    UPDATE adaptive_autovacuum.global_apply_queue
    SET status = 'failed',
        error = 'Expired before a worker applied it.'
    WHERE status = 'pending'
      AND requested_at < clock_timestamp() - interval '1 hour';

    /*
     * Missing planner statistics: a table that has live rows but was never
     * analyzed in its whole life (no manual ANALYZE, no autoanalyze) leaves
     * the planner estimating from hardcoded defaults.  Analyze the largest
     * offenders directly, one at a time — unlike VACUUM, ANALYZE is legal
     * inside a function's transaction.  Deliberately NOT gated on
     * min_table_bytes: missing statistics mislead the planner regardless of
     * table size, and n_live_tup > 0 already proves there is something to
     * sample.  Once a table has been analyzed its last_analyze timestamp is
     * set and it never qualifies again, so the feature self-limits to new or
     * freshly stats-reset tables; a failed attempt (lock timeout) is simply
     * retried on a later cycle.  This runs LAST among the cycle's actions
     * because each ANALYZE holds a ShareUpdateExclusive lock until the cycle
     * transaction commits.  Skipped under host pressure: sampling large
     * tables is real I/O.
     */
    IF p.analyze_missing_stats
       AND p.analyze_missing_stats_per_cycle > 0
       AND NOT host_pressure THEN
        FOR r IN
            SELECT c.oid AS relid,
                   format('%I.%I', n.nspname, c.relname) AS fqname,
                   pg_stat_get_live_tuples(c.oid)::bigint AS live_tuples
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN adaptive_autovacuum.table_policy tp ON tp.relid = c.oid
            WHERE c.relkind = 'r'
              AND c.relpersistence <> 't'
              AND NOT (n.nspname = ANY (p.excluded_schemas))
              AND COALESCE(tp.enabled, true)
              AND pg_stat_get_live_tuples(c.oid) > 0
              AND pg_stat_get_last_analyze_time(c.oid) IS NULL
              AND pg_stat_get_last_autoanalyze_time(c.oid) IS NULL
            ORDER BY pg_stat_get_live_tuples(c.oid) DESC
            LIMIT p.analyze_missing_stats_per_cycle
        LOOP
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

    DELETE FROM adaptive_autovacuum.decisions
    WHERE decided_at < clock_timestamp() - make_interval(days => p.history_retention_days);

    DELETE FROM adaptive_autovacuum.global_recommendations
    WHERE created_at < clock_timestamp() - make_interval(days => p.history_retention_days);

    DELETE FROM adaptive_autovacuum.emergency_queue
    WHERE finished_at < clock_timestamp() - make_interval(days => p.history_retention_days)
      AND status IN ('completed', 'cancelled', 'failed');

    DELETE FROM adaptive_autovacuum.global_apply_queue
    WHERE status IN ('applied', 'failed')
      AND coalesce(applied_at, requested_at)
          < clock_timestamp() - make_interval(days => p.history_retention_days);
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
    state.last_error
FROM adaptive_autovacuum.relation_state state;

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

/* Cluster-wide wraparound early-warning board (one row per database),
   modeled on the AWS RDS MaximumUsedTransactionIDs alarm:
   watch at half the emergency threshold (500M by default), alarm at the
   threshold itself (1B by default).  PostgreSQL stops accepting writes
   ~3M transactions before the 2^31 wrap point. */
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
'Per-database transaction-age early warning: ok / watch (half the emergency threshold) / alarm (emergency threshold). Alarm means the built-in anti-wraparound autovacuum is not keeping up — investigate stuck replication slots, prepared transactions, or long-running queries.';

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
    /* PG18+ column, NULL on PG17; the jsonb detour lets one view definition
       parse on both versions. */
    ((to_jsonb(progress) ->> 'delay_time'))::double precision AS delay_time,
    activity.query LIKE '%(to prevent wraparound)' AS antiwraparound,
    activity.backend_type = 'autovacuum worker' AS is_autovacuum
FROM pg_stat_progress_vacuum progress
JOIN pg_stat_activity activity ON activity.pid = progress.pid;

COMMENT ON TABLE adaptive_autovacuum.policy IS
'One-row policy table. enabled and dry_run are independent safety gates.';
COMMENT ON TABLE adaptive_autovacuum.relation_state IS
'Controller ownership, hysteresis counters, and reversible reloption state.';
COMMENT ON TABLE adaptive_autovacuum.global_recommendations IS
'Cluster-level ALTER SYSTEM recommendations; the extension does not apply them automatically.';
COMMENT ON TABLE adaptive_autovacuum.emergency_queue IS
'Guarded manual VACUUM requests executed serially by database workers.';
COMMENT ON FUNCTION adaptive_autovacuum._run_cycle(double precision, integer, bigint, bigint) IS
'Internal policy evaluator invoked by the background worker.';

REVOKE ALL ON ALL TABLES IN SCHEMA adaptive_autovacuum FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA adaptive_autovacuum FROM PUBLIC;
GRANT USAGE ON SCHEMA adaptive_autovacuum TO PUBLIC;
GRANT SELECT ON adaptive_autovacuum.relation_status,
                adaptive_autovacuum.changed_tables,
                adaptive_autovacuum.latest_global_recommendation,
                adaptive_autovacuum.active_vacuums,
                adaptive_autovacuum.wraparound_status
TO PUBLIC;
GRANT EXECUTE ON FUNCTION adaptive_autovacuum.host_metrics() TO PUBLIC;
