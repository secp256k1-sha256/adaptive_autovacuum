# Adaptive Autovacuum Architecture Guide

**Target:** PostgreSQL 17 and later (full feature set on 18)
**Extension version:** 1.3.0 (1.0.0 reference implementation revised 2026-08-14, superseding the original recommendation-only design; 1.1.0 added the operator/installer API: `doctor()`, `status()`, `enable_default_policy()`; 1.2.0 turns the database-local extension into a cluster-global subsystem: one control database, one controller process, database workers that run a shipped SQL program, central state, sweep generations, and complete-evidence gating for cluster settings. There is no upgrade script from 1.1.0; see section 18. 1.3.0: Debian 12/13 and EL10 packages; `autovacuum = off` repaired before the sweep and on every reload; table settings become recommendations (`table_recommendations`, section 13) and the program runs no `ALTER TABLE`; `min_table_bytes` 0 and `target_dead_tuple_min` 1000 defaults; true per-second I/O deltas; upgrade script 1.2.0 -> 1.3.0.)
**Safety posture:** a fresh install is active (policy `enabled = true`, `dry_run = false`, cluster-setting management on) behind the cluster switch `adaptive_autovacuum.enabled` (on by default; off pauses the whole cluster); per-table cost boosts are opt-in; emergency execution is on. Installing is opting in, which matches the no-DBA target; the guardrails below carry that choice. Future upgrade scripts must preserve the `enabled` / `dry_run` values an installation already has.
**Source layout:** the current `sql/adaptive_autovacuum--1.3.0.sql` is assembled from `sql/parts/01_schema.sql`, `02_program.sql`, `03_control_plane.sql` and `04_views_api.sql` by `bash sql/assemble.sh`; contributors edit the parts, run the script, and commit both. The C side is the single file `src/adaptive_autovacuum.c`.

## 1. Purpose

The extension is a bounded controller around PostgreSQL's existing autovacuum subsystem. It does not replace the core autovacuum launcher or workers. It observes whether table maintenance is falling behind and acts at two levels, mirroring how production DBAs tune autovacuum:

1. **Cluster level first.** Autovacuum is a cluster-wide phenomenon - one worker pool, one shared cost budget, one trigger baseline. When the data shows a cluster setting is wrong, the controller corrects it through `ALTER SYSTEM` plus configuration reload, within a fixed allowlist, rate limits, and a full old-value audit.
2. **Table level for outliers.** Relations that remain special after the baseline is right - disproportionate-DML tables, very large tables, insert-only tables - receive reversible per-table storage parameters that are automatically restored once the relation is healthy.

It can additionally execute a guarded manual vacuum when a relation's transaction-ID age is critical and no equivalent vacuum is active.

The central design objective is not maximum vacuum speed. It is to reduce backlog and wraparound risk without creating uncontrolled I/O, memory, DDL-lock, or configuration churn.

## 2. Goals and non-goals

### Goals

- Detect persistent dead-tuple backlog and insert backlog rather than react to one noisy sample.
- Control maintenance capacity as a closed loop on the *velocity* of cluster maintenance debt (dead plus inserted-since-vacuum tuples): raise while the debt grows or stalls, hold while it shrinks, decay back toward the operator baseline once it is gone.
- Repair `autovacuum = off`, the single most dangerous misconfiguration for an unattended installation, before anything else: at the start of every sweep and immediately after a configuration reload that turned it off (a configurable number of consecutive checks can delay it).
- Correct the cluster-wide autovacuum baseline (trigger thresholds and scale factors for vacuum, insert-vacuum, and analyze; cost limit and delay; worker count and launcher interval; autovacuum memory) when evidence shows it is mistuned - applied automatically with rails, or recorded as recommendations when the operator prefers.
- Size the PostgreSQL 18 dead-tuple trigger ceiling (`autovacuum_vacuum_max_threshold`) from the actual fleet rather than a constant.
- Derive per-table thresholds from a target dead-tuple / inserted-rows budget for outlier relations and hand them to the operator as recommendations with ready-to-run SQL; never recommend a trigger looser than the one in place.
- Recommend stronger table-level cost settings, tiered by severity, for a bounded number of urgent relations, and recommend their removal once the relation is healthy.
- Recognize XID and MXID age independently from ordinary dead-tuple pressure, **including the TOAST relation's own age**.
- Use PostgreSQL 18 vacuum-progress information, including cost-delay time and repeated index-vacuum cycles.
- Consider effective memory limits in Linux cgroups as well as host memory.
- Record pre-change values for every cluster setting it touches and the previous values behind every table recommendation.
- Never write table settings; respect stricter operator-set cluster values.
- Make every automatic action explainable through decision history and change audits.

### Non-goals in this version

- Replacing core autovacuum scheduling.
- Writing table reloptions (`ALTER TABLE ... SET`): since 1.3.0 they are recommended, never applied.
- Changing settings of an already-running autovacuum worker through table reloptions.
- Automatically terminating user sessions, prepared transactions, or replication slots that hold back cleanup.
- Managing TOAST-specific reloptions (TOAST *age* is assessed; TOAST parameters are not written).
- Measuring storage latency or queue depth from the operating system.
- Running several emergency vacuums concurrently.
- Providing binary compatibility across PostgreSQL major versions.
- Automatically *lowering* `autovacuum_max_workers` (raising is automatic; lowering is an operator decision).

## 3. Process topology

```text
PostgreSQL postmaster
  |
  +-- core autovacuum launcher and workers (unchanged)
  |
  +-- adaptive autovacuum launcher                static worker, connected to no database
        supervises exactly one controller; exponential backoff 10 s .. 600 s
        |
        +-- adaptive autovacuum controller        dynamic worker, connected to control_database
              runs sweep generations:
                _begin_generation() -> _discover_databases()
                -> database workers (max_database_workers at a time), each result absorbed centrally
                -> _global_controller() (one decision) -> ALTER SYSTEM (one apply step) -> naptime
              |
              +-- adaptive autovacuum database A  dynamic, connected to A: runs program.sql as DO, writes <oidA>.out
              +-- adaptive autovacuum database B  dynamic, connected to B
              |
              +-- adaptive autovacuum emergency   dynamic, one at a time cluster-wide, request in bgw_extra
```

**Launcher.** Registered from `_PG_init()` while the library is loaded through `shared_preload_libraries`. It initializes a backend connection to no database (`pg_database` is a shared catalog, which is all it needs), records its PID in shared memory, and supervises exactly one controller. Before starting it, the launcher looks `adaptive_autovacuum.control_database` up in `pg_database`; if the database does not exist, is a template, or does not allow connections, it logs a WARNING with a hint and retries with exponential backoff (10 s doubling to 600 s) instead of starting a controller that would fail. A controller that exits is restarted with the same backoff; the failure count is forgotten once the restarted controller has completed a sweep. The launcher never evaluates policy and never touches a user database.

**Controller.** One dynamic worker connected to the control database. It owns every write to the control tables and is the only process that ever calls `ALTER SYSTEM`. It works in **sweep generations**: `_begin_generation()` increments `controller_state.cluster_generation`; `_discover_databases()` lists every connectable, non-template database from `pg_database`, applies the policy's `included_databases` / `excluded_databases` LIKE patterns, upserts `database_state` (dropped databases take their state with them), and returns the list in descending transaction age; the controller then runs up to `max_database_workers` database workers concurrently, absorbing each result as it lands; after the last one it makes ONE global decision (`_global_controller()`, with fresh host metrics and the next-XID counter) and performs ONE apply step over `global_apply_queue`; then it sleeps `naptime_seconds`. Emergency requests are dispatched during the sweep and between sweeps, so a wraparound emergency never waits for a slow sweep. When the extension objects are missing in the control database (no `CREATE EXTENSION` yet, or an outdated version) the controller waits and logs one WARNING per ten iterations. In this document, "cycle" or "check" means one scan of one database inside a sweep; "sweep" means one generation over all databases.

**Database workers.** Collectors and executors, never controllers. For each database the controller writes an input document to `pg_stat_tmp/adaptive_autovacuum/<dboid>.in` (`_worker_input()`: policy, this database's previous `table_state` rows, its `table_policy` rows, emergency gates, host metrics, the cluster XID rate, and the cost-boost budget already used elsewhere) and the program text to `program.sql` once per sweep. The worker connects to the target database, sets the session GUC `adaptive_autovacuum.worker_input` to the document, runs the program as an anonymous `DO` block in one transaction, reads the result from `adaptive_autovacuum.worker_output`, writes `<dboid>.out`, and exits. The program uses only `pg_catalog`, so the managed database needs no extension objects; table changes and the in-cycle ANALYZE run inside it, each DDL in its own subtransaction. A worker that fails writes `{"ok": false, "error": ...}`; one that crashes or is terminated at `database_worker_timeout_seconds` leaves no file, and the controller records the database as `failed` with its previous summary kept. The worker's `bgw_name` carries the database name (`adaptive autovacuum database <name>`), so `pg_stat_activity` shows which database a slot is scanning.

**Emergency worker.** Started by the controller for one queued request at a time cluster-wide; the request (database and relation OID, memory, cost, lock timeout, wraparound flag) is passed in `bgw_extra`, and the outcome comes back through `emergency_<request_id>.out`. It connects to the target database, acquires the shared-memory emergency slot, runs the guarded `vacuum()` under `emergency_timeout_seconds`, and exits. The controller records the outcome in `emergency_queue` and dispatches the next request.

**Handoff files.** All handoff documents live under `pg_stat_tmp/adaptive_autovacuum/` (`PG_STAT_TMP_DIR`), which is excluded from base backups and cleaned at server start; the controller creates the directory on demand, and every input/output pair is deleted after it has been absorbed. Files are written to a temporary name and renamed into place, so a reader never sees a half-written document.

All wait loops call `CHECK_FOR_INTERRUPTS()` after every latch wake-up. This is load-bearing: `DROP DATABASE` (and other operations built on process-signal barriers) waits on **every** process in the cluster, and a background worker that never absorbs those barriers blocks such commands indefinitely. This was found and fixed through live testing.

### Worker scheduling

Databases are scanned in descending transaction age (`GREATEST(age(datfrozenxid), mxid_age(datminmxid))`), so the databases nearest wraparound are inspected first in every sweep. `adaptive_autovacuum.max_database_workers` bounds a slot scheduler in the controller: up to that many database workers run concurrently, each under its own `database_worker_timeout_seconds`. The default is 2: emergency vacuums already run outside these slots in the dedicated emergency worker, but a routine scan can still be slow in one database (a large catalog, lock waits, or the in-cycle ANALYZE of a big never-analyzed table), and with a second slot that never delays the checks of the databases scheduled after it. Setting 1 gives a strictly serial scan. Reserve `max_worker_processes` for the launcher, the controller, `max_database_workers` database workers, and one emergency worker.

The shared-memory emergency slot holds the owning worker PID and database OID. The emergency worker must acquire it before vacuuming, and a `before_shmem_exit` callback releases it; a later worker can reap a slot whose PID is no longer present in the process array. Together with the controller's one-request-at-a-time dispatch this preserves the one-emergency-vacuum cluster limit across controller restarts and abnormal worker exits.

### Standby behavior

All workers are registered with `BgWorkerStart_RecoveryFinished`: on a hot standby nothing starts, so the extension performs no writes, no `ALTER SYSTEM`, and no vacuums there. After a promotion the postmaster starts the launcher automatically, the launcher starts the controller, and normal operation begins within one naptime. As defense in depth both the launcher and the controller check `RecoveryInProgress()` each iteration and stay idle (state `idle: server in recovery`) if they ever observe recovery. Extension configuration is not synchronized across an HA pair; keep `postgresql.conf` settings aligned yourself or through your HA tooling.

## 4. Components

### 4.1 C launcher

- Define the extension GUCs and reserve the small shared-memory block.
- Register the static launcher worker.
- Resolve `adaptive_autovacuum.control_database` in the shared `pg_database` catalog; warn and back off when it is missing, a template, or not connectable.
- Start and supervise exactly one controller; restart it with exponential backoff.
- Stay idle while the server is in recovery or `adaptive_autovacuum.enabled` is off.
- Reload SIGHUP settings; absorb process-signal barriers.

It does not connect to any database and does not evaluate policy.

### 4.2 C controller

- Connect to the control database by OID; record its PID, the control database OID, and a human-readable `controller_state` in shared memory (`controller_status()`).
- Wait until the 1.2.0 SQL objects exist in the control database (`_begin_generation()` and `database_state`).
- Run sweep generations: recover stale emergency requests, publish `program.sql`, begin the generation, collect host metrics, discover databases, schedule database workers, absorb every result through `_absorb_database_result()`, run `_global_controller()` once, then **apply queued cluster-setting changes**: claim pending rows from `global_apply_queue`, validate each GUC name against a fixed C-side allowlist and each value as a plain numeric literal (`autovacuum` is the one boolean entry and accepts only `on`), capture the current value, call the exported `AlterSystemSetConfigFile()` entry point, mark the row applied with its old value, and signal the postmaster to reload. `ALTER SYSTEM` cannot be executed through SPI (utility statements from functions are rejected), which is why the controller calls the internal entry point directly.
- Dispatch emergency requests one at a time, during and between sweeps, and record their outcome.
- Log one summary line per database scan and per sweep (`log_cycle_summary`), and one WARNING per sweep when the extension is also created in other databases.
- Keep the generation counters in shared memory current (expected, completed, and failed databases, sweep timing, sweep-duration EMA).

### 4.3 C database worker

- Connect to one database by OID.
- Read `<dboid>.in` and `program.sql`, hand the input over through the session GUC `adaptive_autovacuum.worker_input`, run the program as a `DO` block in one transaction, read `adaptive_autovacuum.worker_output`, write `<dboid>.out`.
- On any error write `{"ok": false, "error": ...}` so the controller can record the failure with its message.

It never reads or writes the control tables, never touches shared memory beyond the process list, and never applies cluster settings.

### 4.4 C emergency worker

A separate dynamic worker started by the controller for one request:

- Acquire the cluster-wide shared-memory emergency slot (report `failed` immediately if another emergency vacuum is running anywhere in the cluster; the slot is released by a `before_shmem_exit` hook on both normal and abnormal exit).
- Run the manual vacuum for that single relation with session-local maintenance and cost settings.
- Enforce `adaptive_autovacuum.emergency_timeout_seconds` (default 24 h, `0` = unlimited) through the timeout infrastructure: on expiry the vacuum is cancelled and the request marked failed.
- Report `completed` or `failed` plus the error text through its result file. The controller records it; failures set an escalating retry backoff (N recent failures -> N × 5 minutes, capped at 2 h), and the program additionally refuses to requeue a relation that failed 8 times within 24 h.

### 4.5 SQL control plane (control database)

Functions the controller calls, all `SECURITY DEFINER` with a fixed search path:

- `_begin_generation()`: next `cluster_generation`, stamps the sweep start.
- `_discover_databases()`: every connectable non-template database with the include/exclude patterns applied; upserts `database_state`; deletes the state of dropped databases; oldest first.
- `_worker_input(...)`: the input document for one database (policy, previous `table_state`, `table_policy`, emergency gates, host metrics, cluster XID rate, boost budget used elsewhere); stamps the scan start.
- `_absorb_database_result(...)`: persists one worker result: `table_state` upserts and deletes, `decisions`, `emergency_queue` inserts, and the `database_state` summary (status `healthy` / `backlog` / `emergency`, scan generation and timing, counts, debt and its velocity EMA computed here, max ages, `extension_installed`). `_record_database_failure()` marks a database `failed` and keeps its previous summary.
- `_global_controller(...)`: the single cluster-level decision step (section 10): aggregates the `database_state` rows of the current generation, samples the cluster counters, records one `global_recommendations` row, and queues allow-listed changes when the evidence is complete.
- `_recover_stale_emergencies()`, `_claim_emergency_request()`, `_set_emergency_worker_pid()`, `_finish_emergency_request()`: the emergency queue lifecycle, PID-reuse guarded.
- `_database_program()`: returns the program text (4.6).
- Diagnostics: `_scan_this_database(generation, ...)` runs the program in the current database the way a worker would and absorbs the result; `_run_cycle(...)` (unchanged signature) chains generation, discovery, scan, and global step for the regression tests.

### 4.6 SQL database program

`_database_program()` returns the body of a PL/pgSQL block that the database worker executes as `DO $aav_program$ ... $aav_program$` inside the managed database. It reads its input from `current_setting('adaptive_autovacuum.worker_input')`, evaluates the table policy (sections 6 to 9, 12, 13), computes table recommendations, runs the in-cycle ANALYZE in its own subtransaction, and leaves one JSON result in `adaptive_autovacuum.worker_output`: `ok`, `extension_installed`, a summary (table count, eligible, overdue, dead/insert overdue, emergency relations, fleet target, medians, debt, max ages, open recommendations, analyzed, scan seconds), the new `table_state` rows and the OIDs to delete, the `decisions` transitions, and the emergency requests. It references only `pg_catalog`, so it runs unchanged in a database that has never seen `CREATE EXTENSION`; it contains no `ALTER TABLE` (the regression suite asserts it), and the SQL text of a recommendation is built in the control database by `_reloptions_sql()`. The controller refuses a program text that contains the quoting tag, so the block cannot be broken out of. The program is part of the extension script (`sql/parts/02_program.sql`), so it is versioned and upgraded with the control database.

### 4.7 Tables (control database only)

- `policy`: one cluster-wide policy row, including `included_databases` / `excluded_databases`.
- `table_policy`: optional per-relation overrides or exclusion, keyed by (`database_name`, `schema_name`, `relation_name`). No OID: rows survive dump/restore and OID reuse, a row whose relation does not exist (yet, or any more) is kept, and the worker matches it by name in the target database.
- `table_state`: hysteresis counters, the vacuum-progress fingerprint, the table recommendation (`recommendation_status`, `recommended_reloptions`, `previous_reloptions`, `recommendation_reason`, `recommended_at`, `applied_at`) and the metrics as of the last write, keyed by (`database_oid`, `relation_oid`). Rows exist only for relations with something to remember (non-normal, carrying a recommendation, vacuum fingerprint); a healthy relation without a recommendation has no row. The previous rows travel to the worker in the input document and come back in the result, so the controller's write volume is O(relations that need attention), not O(all relations). Rows of dropped relations are deleted at the next scan of their database, rows of dropped databases at discovery; rows not written for 7 days age out.
- `database_state`: one row per discovered database: identity, `status` (`healthy`, `backlog`, `emergency`, `failed`, `excluded`, `pending`), `scan_generation`, scan timing, `last_error`, `extension_installed`, and the summary the global step aggregates (counts, medians, fleet target, debt and velocity, max ages). This table is the cross-database aggregate store (section 10).
- `decisions`: an append-only transition log within the retention window, with `generation`, `database_oid`, and `database_name`; a row when a relation enters a (state, action) pair, when a change is applied or fails, and a `recovered` row when it returns to normal. UNLOGGED (as is `global_recommendations`): nothing reads either table back for control, so a crash costs history only, while their WAL is skipped. On a hot standby they cannot be queried at all.
- `global_recommendations`: one row per sweep with `generation`, `databases`, `evidence_complete`, `vacuum_activity_rate`, `vacuum_activity_detail`, `cost_budget_rate`, `cost_ceiling_mbps`, the recommended values (cost pair, workers, `recommended_autovacuum_naptime_seconds`, memory, ring, triggers), and the reason. Always recorded; queued for application only when `manage_global_settings = true`, `dry_run = false`, and the sweep evidence is complete.
- `global_apply_queue`: cluster-setting changes awaiting or completed application, with `generation`, old value, status, and error.
- `emergency_queue`: guarded manual-vacuum requests from any database (`database_oid`, `database_name`), each carrying the projected seconds to the read-only cutoff at enqueue time (`deadline_seconds`); the controller claims by deadline first.
- `controller_state`: the single authoritative row: `cluster_generation`, `last_complete_generation`, sweep timing and the `observed_sweep_seconds` EMA, `last_xid8` and `xid_rate`, the WAL sample, pressure flags, cluster debt and velocity, the backlog-free and autovacuum-off counters, the cost baseline, the activity samples, and the raise record (`last_cost_raise_at`, the raised pair, `activity_before_raise`).
- Views: `database_status`, `table_status`, `table_recommendations`, `actions`, `aging_tables`, `wraparound_status`, `latest_global_recommendation`, `active_vacuums` (4.8).

Keeping policy in SQL makes most changes reviewable and upgradeable without adding more C-level dependencies on PostgreSQL internals; shipping the per-database part as a program text keeps the managed databases free of extension objects.

### 4.8 Observability

`status()` is cluster-first: one row with the control database and whether the current database is it, launcher and controller state, `cluster_generation` / `last_complete_generation`, sweep timing, managed / excluded / failed / stale database counts, tables seen / needing vacuum / in emergency, maintenance debt and trend, running autovacuum workers and the live cost pair, plus the queue, emergency, and wraparound columns. `doctor()` runs 19 checks: `library_preloaded`, `config_file_errors`, `extension_version`, `control_database`, `launcher_enabled`, `launcher_running`, `controller_running`, `policy`, `last_sweep`, `cluster_evidence`, `duplicate_installations`, `global_changes`, `relation_errors`, `table_recommendations` (WARN while a recommendation waits for an operator), `emergency_vacuum`, `wraparound`, `autovacuum`, `track_cost_delay_timing`, `recovery`. `status()` counts `open_table_recommendations`. `controller_status()` exposes the shared-memory block: PIDs, state text, control database OID, generation counters, expected / completed / failed databases, sweep timestamps, the sweep EMA, and the emergency slot. `database_status` adds the freshness flag `stale` (not revisited within `max(10 × naptime, 3 × observed sweep seconds)`); `table_status` replaces the former `relation_status` and carries `database_name`; `table_recommendations` lists, per database and relation, `apply_sql` (open) or `revert_sql` (applied, revert) with the reason; `latest_global_recommendation` adds `vacuum_read_mbps` / `vacuum_write_mbps` derived from the `pg_stat_io` page deltas; `actions` is one cluster-wide action log (scope `cluster`, `table`, `emergency`); `aging_tables` lists the ten oldest relations of the database it is queried in, TOAST age included.

## 5. Safety gates

An automatic write requires all applicable gates:

1. The library is preloaded.
2. `adaptive_autovacuum.enabled` is on at cluster level (the default).
3. The extension exists in the control database (`adaptive_autovacuum.control_database`, default `postgres`) and the controller is connected to it. Copies of the extension in other databases are ignored.
4. `adaptive_autovacuum.policy.enabled` is true (one cluster policy; there is no per-database policy) and the database is not excluded by `included_databases` / `excluded_databases`.
5. `dry_run` is false.
6. **For cluster settings:** `manage_global_settings` is true; the sweep evidence is complete (every non-excluded database was scanned successfully in the current generation; a failed or timed-out database turns that sweep's recommendation into a record-only one); the GUC is on the C-side allowlist; the value passes numeric validation; no pending change for it already exists; the new value actually differs numerically from the current one. Only the controller process queues and applies cluster settings, once per sweep, so there is exactly one decision per generation cluster-wide; database workers never do. Different settings move together in one step on purpose: raising `autovacuum_max_workers` alone splits the same `cost_limit` across more workers, so the cost side must be able to follow immediately.
7. **For table recommendations** (nothing here is applied; the operator runs `apply_sql`): the table is not excluded; the condition has persisted for `overdue_cycles_before_recommend` checks; a trigger recommendation is issued only when it would fire earlier than the current trigger; a cost recommendation only when `recommend_table_costs` is true, the tier pair is stronger than the pair the table vacuums under today, and fewer than `max_boosted_relations` boost recommendations stand cluster-wide (new ones are refused under host pressure except for critical wraparound).
8. For emergency vacuum, `emergency_vacuum_enabled` is true and no active or recently failed equivalent request exists; additionally the cleanup horizon must not itself be past the failure line - an old snapshot, prepared transaction, or replication slot pinning the horizon makes freezing futile, so the program records a `horizon_blocked` decision naming the blocker (see `adaptive_autovacuum.horizon_blocker()`) instead of queueing or taking over - and the relation must not have failed 8 emergency attempts within 24 hours. Cancelling a RUNNING autovacuum additionally requires the observed-stall evidence of section 12: minimum runtime plus `emergency_takeover_stall_samples` consecutive samples with frozen progress counters.

Wraparound age checks run twice per database scan: once inside the performance scan, and once in a **safety scan** that deliberately ignores `min_table_bytes`, `excluded_schemas`, and `table_policy.enabled` - a tiny or excluded relation ages exactly like a large one. The safety scan covers system catalogs and materialized views too. It never cancels a running vacuum of any kind: it keeps no per-relation progress state, so stall evidence cannot exist there, and it only escalates the never-started case.

These gates are independent. Enabling the launcher does not implicitly enable the cluster policy, and enabling the policy does not disable dry-run.

## 6. Observation model

### Relation signals

The policy reads, per eligible relation:

- `pg_class.reltuples`, `pg_class.relpages`, `pg_class.reloptions`
- `pg_class.relfrozenxid` and `pg_class.relminmxid` - **combined with the TOAST relation's** `relfrozenxid`/`relminmxid` via `GREATEST(...)`, because the TOAST table ages independently and is easy to miss
- `pg_stat_get_live_tuples()` / `pg_stat_get_dead_tuples()` / `pg_stat_get_ins_since_vacuum()` (direct per-relation statistics functions; cheaper than joining the `pg_stat_all_tables` view across the whole catalog)
- `pg_class.relallfrozen` (PostgreSQL 18): the insert-trigger scale component is multiplied by the share of pages not yet all-frozen, matching the core formula; on PostgreSQL 17 the column does not exist and the factor is 1.0, which is the core formula there too
- relation size, estimated from `relpages × block size`; the exact `pg_total_relation_size()` fallback runs only for never-analyzed relations whose tuple statistics show at least `min_table_bytes / block_size` rows (a relation with fewer rows cannot reach the threshold in-line), so a freshly restored schema or a forest of empty partitions does not pay a lock and file stat per relation per cycle (`_relation_bytes()`)
- reloptions parsed once per relation in a LATERAL (one `unnest` instead of one `_option_value()` call per option), and a set-based pre-filter: the PL/pgSQL loop only receives relations whose dead or insert pressure is at least half the elevated ratio, whose XID/MXID age is at least half the warning ratio, that already have a `table_state` row, or that have a vacuum running; everything else is normal by construction. The eligible count and the fleet's largest dead-tuple target come from one aggregate query over all eligible relations, so the catalog scan stays O(relations) (as core's autovacuum launcher) while the loop is O(interesting relations). Measured at 100,000 relations: 5.3 s to 1.7 s per cycle with every table eligible (VALIDATION.md, 2026-09-12)
- `pg_stat_progress_vacuum` joined to `pg_stat_activity`, **filtered to the current database's `datid`** (the view is cluster-wide; an unfiltered join lets a same-OID relation in another database masquerade as a local vacuum)

The statistics tuple counts are estimates. The controller therefore uses persistence across cycles and coarse state tiers rather than treating one estimate as exact.

### Vacuum-progress signals

PostgreSQL 18 exposes fields used by this implementation: elapsed time from the matching activity row, `delay_time`, `index_vacuum_count`, dead-tuple byte counters, and heap-block progress/phase. `delay_time` is useful only when `track_cost_delay_timing` is enabled. A high delay fraction suggests cost throttling; repeated index-vacuum cycles indicate the dead-TID store could not hold all work in one pass and justify more autovacuum memory. The count of running autovacuum workers versus `autovacuum_max_workers` provides the worker-saturation signal.

### Host signals

The controller gathers the one-minute load average, online CPU count, and total/available memory, once before the database scans (handed to every worker in its input document) and once more, fresh, for the global decision. On Linux it reads `/proc/meminfo` and then constrains memory to the current cgroup v2 or v1 memory limit when that limit is lower than host RAM.

On Windows there is no load average. The worker samples the system-wide CPU busy fraction over a 200 ms window (`GetSystemTimes()`) and reports `busy_fraction × cpu_count` as `load1`; memory comes from `GlobalMemoryStatusEx()`. The semantic difference matters for the pressure gate: a Unix load average includes processes waiting to run and can exceed the CPU count, while CPU utilization saturates at 1.0 per CPU - so the default `high_load_per_cpu = 1.5` is unreachable on Windows and deployments there should size it below 1.0 (for example 0.85) if CPU-based pressure gating is desired. Memory-based pressure works identically on both platforms.

### Cluster counters

The global step samples three cluster-wide counters into `controller_state` once per sweep and differences them against the previous sweep. The **next transaction ID** is read by the controller in C through `ReadNextFullTransactionId()` and passed to `_global_controller()`: it reads the shared counter without assigning an XID, so measuring the consumption rate never advances the clock it measures (the SQL-only fallback, used by the test harness, is `pg_snapshot_xmax(pg_current_snapshot())`, which does not allocate either). The rate feeds the emergency deadline projection and is handed to every database worker. The **WAL byte counter** gives the storage guardrail below. The **vacuum activity counter** is the autovacuum workers' `pg_stat_io` operations on relations weighted by the vacuum cost model, `hits × vacuum_cost_page_hit + reads × vacuum_cost_page_miss + (writes + extends) × vacuum_cost_page_dirty`, so its rate (`vacuum_activity_rate`, cost units per second) is directly comparable with the budget the live cost pair allows (`cost_budget_rate` = `cost_limit × 1000 / cost_delay_ms`). The per-operation components (hits, reads, writes, extends per second, differenced from the raw counters saved in `controller_state`) are kept in `vacuum_activity_detail`. It measures how much of the cost budget autovacuum is actually spending, not storage bandwidth.

### Storage signal

CPU and RAM miss the resource autovacuum most often saturates: storage. As a database-native proxy, the global step samples `pg_stat_wal.wal_bytes` into `controller_state` once per sweep; the delta gives the cluster WAL generation rate in MB/s. When the opt-in `policy.high_wal_mbps` threshold (0 = disabled) is exceeded, the sweep runs under host pressure (the flag is handed to every database worker in its input document): aggression raises are blocked and the walk-back branches engage. The measured rate and the resulting `storage_pressure` flag are recorded in every decision's host-metrics JSON. The threshold is deliberately operator-set - a sane value depends on the storage device - and WAL rate is a write-side proxy, not a full I/O model. Validated under a ~20K TPS pgbench load: the guardrail measured up to 273 MB/s and stepped the cost settings down, then reversed after the load stopped (VALIDATION.md, 2026-08-14).

Limitations: CPU count is not constrained by cgroup CPU quota; load average / CPU busy is not an application-latency signal; OS-level disk latency, queue depth, and PSI are not read (the WAL-rate guardrail above is the database-native stand-in). Host pressure therefore blocks or reduces aggressive actions, but absence of reported pressure is not proof that more I/O is safe.

## 7. Trigger policy

Core autovacuum's PostgreSQL 18 update/delete trigger is:

```text
trigger = min(max_threshold, threshold + scale_factor * estimated_tuples)   when max_threshold >= 0
trigger = threshold + scale_factor * estimated_tuples                        otherwise
```

The insert-vacuum trigger is analogous (`insert_threshold + insert_scale_factor × estimated_tuples`; a negative threshold disables it). The controller computes both exactly as core does, honoring reloption-over-GUC precedence, and measures each relation's backlog as a ratio against its own trigger. A relation's severity is the **worse** of its dead-tuple ratio and its insert ratio.

For a relation with persistent backlog, the controller derives a target budget:

```text
dead target   = clamp(estimated_rows * target_dead_tuple_ratio,  target_dead_tuple_min,  target_dead_tuple_max)
insert target = clamp(estimated_rows * target_insert_ratio,      target_insert_min,      target_insert_max)
```

and, from the driving side (dead, insert, or both):

```text
desired_threshold     = max(threshold_floor, 10% of target)
desired_scale_factor  = (target - desired_threshold) / estimated_rows   (clamped)
desired_max_threshold = target                                          (dead side only)
```

Trigger settings are recommended (never written) only for backlog states, only when normal autovacuum is enabled globally and for the table, and only when the recommended trigger fires earlier than the current one: a table the operator already tuned tighter than the policy target is left alone and the reason says so (the cluster cost pair and worker count carry that backlog). The dead-side pair (threshold, scale factor, plus `autovacuum_vacuum_max_threshold` on PostgreSQL 18) is always recommended together. A table-level `autovacuum_enabled = false` does not disable core wraparound protection, so XID/MXID monitoring and the guarded emergency path remain active.

### Cluster baseline correction (mistuned-baseline detector)

Per-table overrides are for outliers. When at least **3 relations and 25% of the eligible fleet** are dead-overdue in the same cycle, the baseline - not the tables - is wrong. The controller then takes the **median** of the per-relation desired thresholds and scale factors as the new cluster-wide `autovacuum_vacuum_threshold` / `autovacuum_vacuum_scale_factor`, keeps `autovacuum_analyze_scale_factor`/`_threshold` in proportion (half the vacuum scale, PostgreSQL's default ratio, with floors), and the same rule applies independently on the insert side for `autovacuum_vacuum_insert_*`.

### Fleet-derived trigger ceiling

`autovacuum_vacuum_max_threshold` - PostgreSQL 18's cap that lets one sane percentage coexist with very large tables - is not a constant here. It is derived every cycle as the dead-tuple target of the **largest** eligible relation (ratio × rows, clamped to the policy bounds): the biggest table never waits longer than its own policy target, while smaller relations keep triggering via the scale factor because their computed trigger stays below the ceiling. Hysteresis prevents churn: the ceiling is tightened when disabled or more than 10% looser than derived, raised only when grossly over-tight (below half of derived), and anything in between is respected as operator intent.

## 8. State machine and hysteresis

Relation states are prioritized as follows:

```text
wraparound_critical
wraparound_warning
backlog_critical
backlog_urgent
backlog_elevated
normal
```

Wraparound state is evaluated first because XID/MXID exhaustion is a correctness risk rather than ordinary bloat.

The controller increments `consecutive_overdue` while a relation is non-normal and issues a table recommendation only after `overdue_cycles_before_recommend`. It increments `consecutive_healthy` while normal and recommends reverting an applied cost boost only after `healthy_cycles_before_revert`. An applied recommendation is frozen as recommended until the relation is normal, so it is never re-tuned behind the operator; cluster settings are paced by the sweep (one decision per generation) and the at-most-doubling step (see §10). Changes are coarse and state-based rather than proportional on every sample, reducing oscillation.

## 9. Cost management

### Cluster level

The shared autovacuum cost budget (`autovacuum_vacuum_cost_limit`/`_cost_delay`) is corrected automatically as a closed loop on **maintenance-debt velocity**. Every sweep sums dead tuples plus inserted-since-vacuum tuples over all eligible relations (in the same aggregate pass that counts the fleet), differences it against the previous sweep's total in `controller_state`, and smooths the rate with an EMA (alpha 0.5). Each database worker reports its debt total in its result document; the controller stores it with a per-database velocity EMA in `database_state`, sums the rows of the current generation, and the trend is the cluster rate times the sample interval relative to the cluster debt, classified with a deadband (`backlog_trend_deadband`, default 5% per check): *growing*, *flat*, or *shrinking*; *unknown* on the first cycle. With overdue relations and no host pressure the controller then: raises step-wise (at most doubled per change window, capped by `recommendation_cost_limit_max`) when the debt is growing, flat, or unknown; **holds** when the debt is shrinking, because the current settings are demonstrably working; and *reduces* under host pressure regardless of trend (the delay-bound long-vacuum trigger is unchanged). Once no relation has been overdue cluster-wide for `recovery_cycles_before_decay` consecutive checks (default 10), it takes one step halfway back toward the operator baseline (cost limit halved toward it, delay doubled toward it) and resets the counter, so incident aggression decays over tens of checks rather than staying forever. The baseline is the value found before the first automatic change; it is refreshed to the live value whenever that value is not the one the extension last applied (an operator edit is never fought), and the newest applied row per setting is exempt from queue retention so the comparison survives it. The delay walk-down halves per window but stops at `recommendation_delay_min_ms` (default 0.5 ms): delay 0 equals unthrottled manual-vacuum aggression and is never reached automatically, while an operator-chosen delay already below the floor is respected and never raised.

Two memory-side settings are sized opportunistically while maintenance is actually running and the host has free memory - an idle cluster is never retuned. `vacuum_buffer_usage_limit` (PG16+) is, per the PostgreSQL documentation, "the size of the Buffer Access Strategy used by the VACUUM and ANALYZE commands" - the ring those commands work through inside shared_buffers. A larger ring can speed maintenance up, but ring pages displace regular cached pages, and host free memory says nothing about shared-buffers cache pressure. The heuristic is therefore deliberately conservative and the caps do the real work: at most doubled per cycle up to `recommendation_buffer_usage_limit_max_mb`, additionally bounded by the server's own silent 1/8-of-shared_buffers clamp divided across the worker pool so concurrent rings cannot crowd out the workload's cache; it is halved back toward the built-in default under host pressure, and an operator value of 0 ("no limit") is never touched. It is a separate signal from `autovacuum_work_mem`: repeated index passes indicate dead-tuple memory pressure and feed the work_mem heuristic, not the ring size. `autovacuum_work_mem` keeps its evidence-based raise (repeated index passes = the vacuum ran out of dead-tuple memory) and additionally ratchets toward the free-memory-derived value while workers are running; it is never lowered without host pressure. Because the shared budget is split across workers, raising `autovacuum_max_workers` does not increase total un-boosted vacuum I/O - it adds parallelism. The worker count is therefore raised (never lowered) on the capacity signal: every worker is busy while relations are overdue **and** the debt trend is not shrinking, i.e. the pool is structurally too small rather than momentarily busy. Saturation is read two ways, because one `pg_stat_activity` sample per cycle misses workers that start and finish between samples: every worker busy, or an overdue queue of at least `2 × workers` and `workers + 2` relations. The step goes toward the overdue count but at most doubles per change (1, 2, 4, 8, 16); the extra workers must fit at `autovacuum_work_mem` each into half the currently free memory, and `autovacuum_worker_slots` and `recommendation_workers_max` (default 16, the PostgreSQL 18 default slot count) cap it. The CPU count is deliberately not a ceiling: workers are separate processes but share one cost budget, so more of them add concurrency across relations rather than proportionally more I/O, and a 1-worker-per-CPU rule left small hosts with hundreds of overdue tables unable to grow the pool. CPU still acts through the load-per-CPU pressure gate (on Windows that gate needs `high_load_per_cpu` below 1.0, see section 6). Memory or storage pressure suppresses the raise unless a relation is in `wraparound_critical`, where added workers help PostgreSQL's own forced vacuums and safety outranks conservatism; CPU load alone does not, because the workers share one cost budget and the pool grows concurrency rather than I/O (1.3.0; earlier versions held under any host pressure, which on a small host under load kept the pool at one worker while hundreds of tables were overdue).

**Launcher interval (1.3.0).** Core's autovacuum launcher visits each database once per `autovacuum_naptime` and starts one worker for it, so with the default 60 s a database with a hundred overdue tables receives one new worker per minute no matter how large `autovacuum_max_workers` is: in the 1.3.0 drills the pool went to 16 within 40 s while one to three workers actually ran. The controller therefore manages `autovacuum_naptime` (reloadable) with the same evidence and the same shape as the cost pair: while relations are overdue, the debt is not under control, memory and storage are not under pressure and fewer workers run than the pool allows, the interval is halved per check down to `naptime_min_seconds` (default 5 s); once no relation has been overdue for `recovery_cycles_before_decay` checks it doubles back toward the operator baseline together with the cost decay. `manage_naptime = false` leaves it alone. The baseline is tracked like the cost pair (the value found before the first automatic change, refreshed when the live value is not the one last applied here). A shorter interval costs one launcher catalog pass per database per interval, which is why it is ramped and decayed rather than set once.

"Shrinking" alone is not a reason to hold: the controller projects the drain time as debt divided by the measured shrink rate and only treats the backlog as under control when that projection is within `max_backlog_drain_seconds` (default 180 s); a backlog shrinking at 2 % per check on a 60 s naptime would otherwise sit unhelped for most of an hour. The same test gates the worker raise. The cost pair has two additional brakes because doubling the limit while halving the delay quadruples the theoretical throughput per step, and the knob-unit caps (`recommendation_cost_limit_max` 10000, `recommendation_delay_min_ms` 0.5) together allow about 200 times the PostgreSQL default budget. (1) A page-rate cap: `vacuum_cost_ceiling_mbps(limit, delay)` = `(1000 / delay ms) × (limit / vacuum_cost_page_hit) × block size`, in MiB/s (the theoretical rate if every cost unit were a page hit, not physical bandwidth), must stay at or below `recommendation_max_vacuum_mbps` (default 3200, about four times the 781 MiB/s of 200 / 2 ms). When the doubled pair would exceed it the delay is kept, since it is what smooths I/O into small slices, and the limit is raised only as far as fits at the current delay; if nothing fits the pair is held. The cap never lowers an operator pair that already exceeds it. (2) Activity feedback: each sweep samples the cost-weighted autovacuum activity of section 6 and keeps its rate over the last interval. When a raise is queued for application, the rate seen before it is stored with the target pair in `controller_state` (`activity_before_raise`). While that pair is the live one, a further raise requires a sample interval that counts as post-raise (the queue's `applied_at` for the raise falls within the first tenth of the interval, so at the default naptime the raise is judged on the very next sweep rather than a sweep later) and an activity rate at least `cost_raise_min_activity_gain_percent` (default 10) above the stored one; otherwise the controller holds. The hold reason reports both rates and says that the extra budget is not being used yet, so another raise would not help; it lists possible causes (storage limits, lock waits, vacuum phase changes, worker turnover, sampling timing) rather than claiming that storage is the limit, because the activity metric cannot tell them apart. A record whose pair no longer matches the live settings (operator change, failed apply, decay) is ignored; a pair still waiting in the apply queue keeps its first record (it is re-recommended every sweep until applied, and the applied row is matched by value), and a backlog-free sweep clears the record so the next incident's first raise is judged fresh rather than against a quiet interval. Dry-run recommendations are not recorded, so they keep showing the uncapped-by-feedback advice. The observed rate, its components, the budget of the live pair, and the ceiling of the recommended pair are written to `global_recommendations.vacuum_activity_rate`, `vacuum_activity_detail`, `cost_budget_rate`, and `cost_ceiling_mbps`. Limitation: autovacuum workers flush I/O statistics between tables, so a single very long vacuum can make one interval read low and hold a raise one sweep longer than necessary; a hold is never a lowering.

### Table level

Table cost boosts are recommendations (`recommend_table_costs`, default true), never written by the extension. A relation in a backlog or wraparound state gets the cost pair of its severity tier (`elevated_cost_limit` / `_delay_ms`, `urgent_*`, `critical_*`) in its recommendation when that pair is stronger than the one the table vacuums under today (its own cost reloptions, else the cluster pair); at most `max_boosted_relations` such recommendations stand cluster-wide, the most urgent first, and new ones are refused under host pressure except for critical wraparound. Once the operator has applied it and the relation has been normal for `healthy_cycles_before_revert` checks, the boost gets a `revert` recommendation, because a table with explicit cost parameters is excluded from core cost balancing and keeps its budget for as long as the reloptions stay.

### In-flight limitation

Changing a table reloption does not retune a worker that has already read the table's options, and the operator's `ALTER TABLE` needs a lock that conflicts with an active vacuum: run `apply_sql` with a `lock_timeout` when a vacuum may be running. Table changes affect future maintenance runs.

## 10. Cluster-setting application

The original design recorded cluster values as recommendations only. Field experience inverted that: autovacuum starvation is a cluster problem (worker pool, cost budget, baseline), and requiring a human to apply every correction re-created the exact operational gap the extension exists to close. The shipped design **applies** cluster settings by default, with the following rails, and downgrades to recommendation-only when `manage_global_settings = false`:

- **Fixed allowlist**, enforced twice: the SQL policy only enqueues the thirteen managed maintenance GUCs (cost pair, workers, `autovacuum_naptime`, memory, ring, six trigger settings) plus the repair-only `autovacuum` entry, and the C applier independently rejects anything outside its compiled-in list.
- **`autovacuum = off` repair.** With `repair_disabled_autovacuum` (default true) the policy counts consecutive checks that saw `autovacuum` off in `controller_state` and, at `repair_disabled_autovacuum_cycles` (default 1, the first check), queues `autovacuum = on` through the same audited path and reloads in the same sweep; the applier accepts no other value for that GUC, so the extension can switch autovacuum on but never off. An operator who wants a maintenance window without autovacuum raises the cycle count or sets the flag to false; the controller itself is the safer thing to turn off for such a window.
- **Numeric validation** of every value at both layers (the `autovacuum` row is validated as the literal `on` instead), plus **bounds validation**: the SQL policy never enqueues a value outside the GUC's own `pg_settings` min/max, the `policy` table's CHECK constraints cap every knob that feeds a bounded setting at that setting's documented maximum (cost limits ≤ 10000, delays ≤ 100 ms, scale factors ≤ 100, work_mem below the kilobyte-conversion overflow), and the C applier isolates each queue row in a subtransaction - a value the server rejects is marked failed individually instead of aborting the whole apply cycle and being retried until expiry. One constraint the server does NOT reject is enforced explicitly at apply time: `autovacuum_max_workers` above `autovacuum_worker_slots` is merely warned about and capped at runtime, so the applier fails such a row itself - the policy caps its own recommendation, but a queued row can outlive a restart that lowered the slot count, and manual queue inserts bypass the policy.
- **Deduplication and a no-op filter**: at most one pending change per GUC, and a change equal to the current value is never enqueued. Pacing comes from the sweep (one decision per generation) and the at-most-doubling step, not from a timer - a per-GUC cooldown was removed because it starved correlated settings (a workers-only raise dilutes the unchanged cost limit across more workers).
- **Old-value audit**: the applier captures the pre-change value into the queue row, giving a one-statement rollback path.
- **Direction rules**: worker count only rises automatically; the trigger ceiling respects tighter operator values; cost aggression falls under host pressure.
- **Application mechanics**: `ALTER SYSTEM` cannot run through SPI, so the controller builds the statement nodes and calls the exported `AlterSystemSetConfigFile()`, then signals the postmaster (`SIGHUP`). Every managed GUC is reloadable in PostgreSQL 18, so changes take effect within seconds without restarts.
- **Failure containment**: an invalid row is marked `failed` with a reason; rows that stay pending for an hour expire; the queue is retention-pruned.

### Sweep generations and complete evidence

Cluster GUCs affect the whole cluster, so they are decided from cluster-wide evidence, and there is exactly one decider. Every database worker's result is absorbed into `database_state` with the sweep's `scan_generation`; after the last worker of the generation the controller runs `_global_controller()` once. It aggregates the `database_state` rows whose `scan_generation` is the current generation: counts add up, the trigger ceiling takes the cluster-wide maximum, cross-database medians are approximated as overdue-count-weighted averages of the per-database medians, and the maintenance debt and its velocity are summed. The mistuned-baseline detectors, the worker-count recommendation, and the overdue-driven cost branch all run on the merged values; the recommendation reason states the cluster evidence explicitly, and the row records `generation`, `databases`, and `evidence_complete`.

Evidence is **complete** when every non-excluded database was scanned successfully in this generation (no failure, no timeout, no worker without a result). Only then are changes queued into `global_apply_queue`; an incomplete sweep records the recommendation and leaves the settings alone, `controller_state.last_complete_generation` stays where it was, and `doctor()`'s `cluster_evidence` names the failed databases. A database that is merely slow does not break completeness: the sweep waits for it (up to `database_worker_timeout_seconds`). Freshness is judged separately, in `database_status.stale`: a database counts as stale only when it has not been revisited within `max(10 × naptime, 3 × observed sweep duration)`, so a sweep over a thousand databases is not misread as a fleet of dead databases.

Shared memory holds only the controller identity, the generation counters, and the emergency slot. The earlier design kept a per-database summary slot array in shared memory (`max_tracked_databases`) and aggregated it in every database worker; it was scan-order dependent (each database decided from whatever its neighbours had published), needed a per-GUC once-per-two-naptimes cooldown and an optional `global_settings_database` to keep several deciders from compounding, and overflowed at a fixed capacity. With one controller and the control database as the aggregate store there is no capacity limit, no warm-up sweep, no cooldown timer, and no designated database: pacing is one decision per sweep, and audit rows always land in the control database.

Application runs in the controller right after the decision: claim pending rows (`FOR UPDATE SKIP LOCKED`), validate, `AlterSystemSetConfigFile()`, mark applied with the old value, reload. Recommendations are still always recorded in `global_recommendations` - including when they are also applied - because the reason text is the operator-facing explanation.

## 11. Memory policy

`autovacuum_work_mem` is a per-worker maximum, so the recommendation divides a bounded fraction of currently available (cgroup-aware) memory across `autovacuum_max_workers`, with floors and caps. It is changed only when a running vacuum is observed making repeated index-vacuum passes - the concrete evidence of a memory-bound vacuum - and never raised under host pressure. The effective current value resolves `-1` to `maintenance_work_mem`.

For a critical emergency relation, the manual vacuum receives a session-local `maintenance_work_mem` calculated from available memory and clamped between emergency minimum and maximum values. This changes only the emergency worker's own session.

## 12. Wraparound controller

The controller calculates, per relation:

```text
xid_age    = greatest(age(main.relfrozenxid),  age(toast.relfrozenxid))
mxid_age   = greatest(mxid_age(main.relminmxid), mxid_age(toast.relminmxid))
xid_ratio  = xid_age  / effective_xid_freeze_max_age
mxid_ratio = mxid_age / effective_mxid_freeze_max_age
```

TOAST inclusion matters: the TOAST relation has its own freeze horizon and lags whenever the main heap is vacuumed with `PROCESS_TOAST off` or by paths that skip TOAST. The effective maximum is the lower of the cluster setting and any nonnegative table-level override.

`wraparound_warning` is relative - a configurable ratio of the effective `autovacuum_freeze_max_age` (default 0.70). It only prioritizes the relation and surfaces visibility; ages between the warning and the forced-vacuum point are core PostgreSQL's job, handled routinely by its cost-throttled anti-wraparound autovacuum.

`wraparound_critical` requires **evidence that the built-in mechanism is failing**, judged from the built-in vacuum's own behavior. An earlier revision fired the emergency at 85% of `autovacuum_freeze_max_age`; that was rejected because a manual `vacuum()` bypasses autovacuum cost balancing, and spending unthrottled I/O in territory the forced autovacuum resolves on its own is pure waste. A later revision used a bare absolute age; the shipped criteria refine it to two failure modes:

- **Never started.** No vacuum is running on the relation although its age is past `stall_age = LEAST(emergency_xid_age, emergency_stall_multiplier × effective freeze_max_age)`. With the 1.5 default the forced autovacuum is 50% of its own trigger overdue - the launcher or worker pool is failing. The absolute `emergency_xid_age` cap (default 1 billion, the AWS RDS `MaximumUsedTransactionIDs` alarm point, ~50% of the ~2.1 billion read-only cutoff) governs clusters running very large `freeze_max_age` values. The multiplier is constrained > 1.0 so the emergency can never fire before the built-in trigger point.
- **Running but provably stuck (takeover).** A rising age is deliberately NOT accepted as failure evidence for a running vacuum: `pg_class.relfrozenxid` is only updated at the very end of a vacuum, so the age keeps climbing for the whole runtime of a perfectly healthy multi-hour vacuum, and a heap-scan-based ETA misjudges index-dominated vacuums. Instead, each cycle stores a progress fingerprint in `table_state` - phase, `heap_blks_scanned`, `heap_blks_vacuumed`, `indexes_processed`, `index_vacuum_count`, and `dead_tuple_bytes`, i.e. every `pg_stat_progress_vacuum` counter that moves while a vacuum does real work in any phase - keyed to the vacuum's PID. Takeover requires ALL of: `backend_type = 'autovacuum worker'` (never the `(to prevent wraparound)` tag alone - a dead-tuple-triggered autovacuum past the trigger runs the same aggressive freeze without the tag), at least `emergency_takeover_min_runtime_seconds` of runtime (default 3600), age past the stall line, and an unchanged fingerprint for `emergency_takeover_stall_samples` consecutive samples (default 5). Only then is the stuck worker cancelled with `pg_cancel_backend()` and replaced by the index-skipping emergency profile. A vacuum showing any progress, however slow, and a manual `VACUUM` are never cancelled.

Complementarily, a mistuned `autovacuum_freeze_max_age` (< 50M: near-constant forced vacuums; > 1.2B: little headroom before `vacuum_failsafe_age` and the read-only cutoff) is flagged in the global recommendation reason. It has postmaster context, so it is record-only - never applied automatically.

The `wraparound_status` view exposes the early-warning model per database (`age(datfrozenxid)` and multixact age, headroom to the read-only cutoff, `ok`/`watch`/`alarm` at half / full `emergency_xid_age`) for external monitoring.

Before queuing an emergency request the database program additionally verifies: emergency execution enabled; dry-run off; no manual vacuum on the relation; no pending/running request; no failed request still in its retry delay. The request records the projected seconds until the read-only cutoff (remaining XIDs divided by the measured cluster XID consumption rate) and the worker claims by that deadline first, unknown deadlines last, then by absolute age; a table discovered later but closer to exhaustion therefore runs before an older request. The queue is central, so the deadline order holds across databases; the emergency lane is still a single slot.

The emergency worker calls PostgreSQL's exported `vacuum()` entry point for **that single relation** with the wraparound-failsafe profile:

- `freeze_min_age = 0` and `multixact_freeze_min_age = 0` (freeze everything visible, maximal `relfrozenxid` advance),
- table-age thresholds zero (aggressive scan),
- `INDEX_CLEANUP OFF` (index vacuuming dominates runtime and contributes nothing to advancing `relfrozenxid`; a later normal vacuum cleans the indexes),
- `TRUNCATE OFF` (avoids the `ACCESS EXCLUSIVE` tail-truncation phase),
- TOAST processed (it carries its own `relfrozenxid`),
- session-local cost settings and a bounded lock timeout, `is_wraparound = true`.

The emergency worker must own the shared-memory emergency slot before it vacuums, and the controller dispatches one request at a time, so at most one extension-initiated emergency vacuum runs cluster-wide even across controller restarts. Note that manual `vacuum()` calls do not produce the server-log "vacuum of table" line (that instrumentation is autovacuum-specific); the queue row timestamps and the age drop are the audit evidence.

### What the controller cannot solve

Vacuum cannot remove or freeze everything it needs while an old snapshot, prepared transaction, replication slot, or standby feedback horizon holds back `OldestXmin`. Resource escalation is not a substitute for diagnosing cleanup-horizon blockers. Operators should correlate critical age with old `backend_xid`/`backend_xmin` values, prepared transactions, replication-slot horizons, long-running transactions, standby feedback, and vacuum logs showing tuples "not yet removable". The extension deliberately does not terminate or alter those objects automatically.

## 13. Table recommendations

The controller never changes a table's reloptions. It computes what the table needs and records it in `table_state`; the `table_recommendations` view turns that into SQL the operator runs in the table's own database. This keeps the locks, the timing and the decision with the operator, and it removes the failure the automatic path had: a floor of 5,000 dead tuples turned a 1% target into 5% and *loosened* triggers an operator had set to 1,000, so autovacuum stopped firing on tables the controller then read as healthy.

Lifecycle, per relation:

- **open**: the relation has been non-normal for `overdue_cycles_before_recommend` checks and something tighter or stronger than today is worth recommending. `recommended_reloptions` holds the values (dead-side threshold and scale factor together, plus the PG18 max threshold; insert-side pair when the insert backlog drives; the tier cost pair when a boost is recommended), `previous_reloptions` the current values of those keys (null = not set), `apply_sql` the `ALTER TABLE ... SET (...)` to run, and `reason` the numbers behind it. While open the values follow reality each check; the row is rewritten only when they change.
- **applied**: every recommended key matches the relation's reloptions numerically. The recommendation is frozen: it is not re-tuned while in place, even when the relation now reads more severe against its tighter trigger. `revert_sql` restores the previous values.
- **revert**: the relation has been normal for `healthy_cycles_before_revert` checks and the applied recommendation carried a cost boost. The row keeps only the cost keys and `revert_sql` removes them. Trigger settings the operator applied are theirs to keep and are not recommended for revert.
- The row disappears when the relation is healthy and nothing of ours is left in place, when the operator changed or removed the recommended keys and the relation is healthy, or when the relation is dropped. If the operator changes a recommended key to another value while the relation is still overdue, the recommendation reopens against the new value.

Outliers only: when the previous scan of the database found the fleet widely overdue on a side (at least 3 relations and a quarter of the eligible relations, the same rule as the cluster baseline detector of section 7), no trigger recommendation is issued on that side and the reason says that the cluster baseline is being corrected instead; the per-table path is for the few tables the corrected baseline still leaves behind. Never-loosen guard: a dead-side or insert-side trigger is recommended only when it fires earlier than the current trigger; a cost pair only when it is stronger than the pair the table vacuums under today. A relation whose operator settings already match what the policy would recommend gets no row at all.

Upgrade from 1.2.0: table options the old controller wrote stay in place (they are tighter triggers); the upgrade script logs one `legacy_table_settings` row per relation in `decisions` (visible in `actions`) with the SQL that restores the captured original values.

## 14. Locking and transaction boundaries

### Database scan

Each database scan runs in one transaction in the database worker, through SPI, as an anonymous `DO` block. The in-cycle `ANALYZE` executes inside a PL/pgSQL exception block with a short `lock_timeout`; a failure rolls back only that statement and is recorded in the returned decisions. The program runs no other DDL: table settings are recommended, not written. The result is written to a file after the transaction commits; the controller absorbs it into the control tables in a separate transaction of its own, so a controller failure while absorbing leaves the target database's changes committed and the database marked `failed` for that generation (its previous summary is kept).

### Cluster-setting application

The global decision runs in one transaction in the controller after the last worker of the generation; the apply step follows in its own transaction. The `postgresql.auto.conf` write itself is non-transactional; if the transaction fails after the file write, the row remains pending and the next sweep re-applies the same value - idempotent by construction.

### Emergency vacuum

`VACUUM` manages per-relation transactions internally and cannot be treated as ordinary transactional SQL. The controller claims the request in the control database, starts the emergency worker with the request in `bgw_extra`, and the worker applies session-local GUCs, creates a cross-transaction memory context, and invokes `vacuum()` through the C API. Completion or failure travels back through the result file and is recorded by the controller in a separate transaction.

A crash after claim but before completion can leave a queue row in `running`. At the start of each later sweep, `_recover_stale_emergencies()` marks a running request failed when its recorded worker PID is no longer visible in `pg_stat_activity` **or belongs to a backend that started after the request was claimed** (the PID-reuse guard: a recycled PID must not masquerade as the dead worker). The shared-memory slot independently self-heals when its owner PID is no longer in the process array.

## 15. Security model

- Installation requires superuser because it installs C code and a background worker.
- Internal policy functions are `SECURITY DEFINER` with a fixed search path.
- The database program runs as an anonymous `DO` block in the target database and references only `pg_catalog`; its input arrives through the session GUC `adaptive_autovacuum.worker_input` (`SUSET`, not settable from configuration files, hidden from `SHOW ALL`), and the controller rejects a program text containing the dollar-quoting tag.
- Handoff documents are written under `pg_stat_tmp`, which belongs to the server account; they contain policy, catalog-derived metrics and relation names, not table data.
- Public privileges are revoked from all internal tables and functions; public read access is granted only to the status views and `horizon_blocker()`. `host_metrics()` exposes host-level resource figures and is granted to `pg_monitor` rather than PUBLIC.
- Dynamic SQL receives a relation name built from catalog identifiers; the SQL text of a table recommendation is built from allow-listed keys and numeric-validated values only (`_reloptions_sql()`), and cluster GUCs are validated independently in both SQL and C.
- Database workers connect as the bootstrap superuser. This is powerful and is a principal reason for conservative defaults, the narrow actuator surface, and the double-validated allowlists.

Production deployments may replace public view access with a monitoring role and should audit all changes to `policy`, `table_policy`, and controller state.

## 16. Failure modes and responses

| Failure | Behavior | Operator response |
|---|---|---|
| Control database missing, a template, or `datallowconn = false` | Launcher logs a WARNING with a hint, does not start the controller, retries with backoff 10 s to 600 s; `controller_status()` shows `waiting for control database` | Create the database, or point `adaptive_autovacuum.control_database` at an existing one and reload |
| Extension not created in the control database | Controller waits (`waiting for CREATE EXTENSION in the control database`), logs one WARNING per ten iterations; nothing is managed | `CREATE EXTENSION adaptive_autovacuum;` there (or `ALTER EXTENSION ... UPDATE`) |
| Extension also created in another database | WARNING at `CREATE EXTENSION`; the copy is ignored; `doctor()` reports `control_database` FAIL there and `duplicate_installations` WARN in the control database; the controller logs one WARNING per sweep | `DROP EXTENSION adaptive_autovacuum;` in the extra database |
| Database excluded by policy | Discovered, `database_state.status = 'excluded'`, never scanned | Adjust `included_databases` / `excluded_databases` |
| Database worker exits without a result (crash, connection failure) | Controller records `failed` with that message and keeps the previous summary; evidence incomplete for the generation, so cluster settings are recorded, not applied | `SELECT database_name, last_error FROM adaptive_autovacuum.database_status WHERE status = 'failed';` check the server log |
| Database worker exceeds timeout | Controller terminates it; recorded as failed | Increase `database_worker_timeout_seconds` only after understanding the workload |
| Controller exits (error, SIGTERM) | Launcher restarts it with backoff; the generation stays incomplete and the next sweep starts a new one | Check the server log (`adaptive autovacuum sweep failed: ...`) |
| No background-worker slot | Launcher (`waiting for a background worker slot`) or controller logs a warning and retries; a database whose worker could not be registered is recorded as failed | Increase `max_worker_processes` |
| ANALYZE lock unavailable | ANALYZE skipped and logged, retried at the next scan | Inspect competing DDL/vacuum |
| Operator changes a recommended key to another value | The recommendation reopens against the new value; an applied recommendation is never re-tuned while in place | Apply or ignore it; `table_policy` changes the targets |
| `autovacuum = off` found | Queued and applied before the sweep, and right after a reload that turned it off; `doctor()` `autovacuum` WARN meanwhile | Nothing; the extension never turns it off |
| Cluster-setting row invalid (unknown GUC / non-numeric value) | Row marked `failed` with reason; nothing applied | Investigate source of the bad row |
| Cluster-setting row never applied | Pending rows expire after one hour | Check the controller log |
| Emergency vacuum errors | Request becomes failed with retry delay | Inspect error and cleanup-horizon blockers before retry |
| Emergency worker dies | Stale `running` row recovered via PID + backend-start check at the start of the next sweep; slot self-heals | Alert if a request stays running beyond `emergency_timeout_seconds` |
| Handoff file missing or unreadable | Worker (input) or controller (output) treats the scan as failed | Check permissions and free space under `pg_stat_tmp` |
| `track_cost_delay_timing` off | Delay-bound detection stays blind | Enable and reload |
| Stats reset or inaccurate estimates | State may temporarily mis-estimate backlog | Rely on hysteresis; inspect decision log |

## 17. Version compatibility

The SQL layer targets PostgreSQL 18 columns and semantics (`autovacuum_vacuum_max_threshold`, `pg_stat_progress_vacuum.delay_time`, `autovacuum_worker_slots`, reloadable `autovacuum_max_workers`). The C layer uses server headers and exported backend functions; PostgreSQL does not promise a stable C ABI across major releases. The most sensitive boundaries are the `VacuumParams` structure and `vacuum()` invocation (emergency path) and `AlterSystemSetConfigFile()` (cluster application).

Required release process for every major version: build against that major's headers; compare the declarations above; run regression tests; run an assertion-enabled server; test SIGTERM during policy DDL and during emergency vacuum; test upgrade/uninstall; run sustained workload tests; publish per-major binaries. The compile-time guard rejecting versions below 17 is not proof that an untested future major is compatible. CI exercises the regression suite on PostgreSQL 17 and 18, each with and without `shared_preload_libraries`.

### Platform compatibility

The SQL layer is operating-system independent. The C layer isolates its platform-specific code to host-metric collection (`#ifdef WIN32` / `#ifdef __linux__` branches); everything else - background workers, signal delivery (`kill(PostmasterPid, SIGHUP)`), `AlterSystemSetConfigFile()`, `vacuum()` - goes through PostgreSQL's own portability layer and works unchanged on Windows.

On Unix the build uses PGXS (`make`). On Windows, PGXS is unavailable for MSVC-built servers (such as the EDB distribution); the provided `windows/build_windows.bat` compiles the DLL with Visual Studio Build Tools directly against the installation's shipped server headers (`include\server\port\win32_msvc`, `win32`, `server`) and links `lib\postgres.lib`. Both artifacts come from the same source file; no platform forks exist. Windows-only tooling lives in the `windows/` folder; the Unix Makefile and the shared `src/` are unaffected.

## 18. Deployment runbook

1. Build and test against the exact PostgreSQL minor environment.
2. Install the library and extension files.
3. Set `shared_preload_libraries`, reserve worker capacity (launcher + controller + `max_database_workers` + one emergency worker), optionally set `adaptive_autovacuum.control_database`, and restart.
4. Create the extension once, in the control database (`postgres` by default). Do not create it anywhere else; every connectable database is discovered from there.
5. Optionally set `dry_run = true` in the cluster policy (a fresh install is active); enable the cluster GUC and reload.
6. Run `doctor()` in the control database: `control_database`, `controller_running`, `last_sweep`, and `duplicate_installations` must be OK. Check that `database_status` lists every database you expect, and exclude the rest with `excluded_databases`.
7. Observe several sweeps: review `actions`, `decisions`, `global_recommendations` (including `evidence_complete`), and proposed values against real churn.
8. Turn dry-run off if it was set. Cluster-setting management activates here - set `manage_global_settings = false` first if cluster changes must stay manual.
9. Review `table_recommendations`, run the `apply_sql` you agree with in the table's database, and confirm the cluster-change audit trail.
10. Cost-boost recommendations are on by default (`recommend_table_costs`), two at a time cluster-wide; revert them when the table is healthy (`revert_sql`).
11. Enable emergency vacuum only after rehearsing blockers, cancellation, timeout, and recovery.
12. Alert on critical relation state, open table recommendations, failed cluster changes, failed or stale databases, failed/stale emergency requests, and a controller that is not running.

1.2.0 upgrades in place (`ALTER EXTENSION adaptive_autovacuum UPDATE`); see section 13 for the table options 1.2.0 wrote. There is no upgrade script from 1.1.0: in every database that has the 1.1.0 objects, review 1.1.0's `changed_tables` and `global_apply_queue.old_value`, restore what should not be kept, `DROP EXTENSION adaptive_autovacuum;`, then create 1.2.0 once in the control database and re-apply policy edits and name-keyed `table_policy` rows.

## 19. Recommended alerts

- Any `wraparound_critical` relation, and any `wraparound_status` row at `watch` or `alarm`.
- XID/MXID age still rising after a completed emergency vacuum.
- Table recommendations open for longer than a day (`table_recommendations.recommended_at`).
- `global_apply_queue` rows in `failed`, or `pending` older than one sweep.
- Emergency queue status `failed`, or `running` beyond `emergency_timeout_seconds`.
- Repeated ANALYZE errors (`decisions.error`).
- `doctor()` `controller_running` or `control_database` not OK; `controller_status().controller_state` not `running` or `sweeping` for longer than a few naptimes.
- `database_status` rows in `failed` or `stale`; `last_complete_generation` falling behind `cluster_generation` for several sweeps.
- Launcher or controller unable to obtain a worker slot.
- Rising overdue-relation counts over successive sweeps.
- Repeated index-vacuum cycles while the memory recommendation is capped.

## 20. Future work

- A progress-velocity model for takeover (predicting a miss of the read-only cutoff from measured per-phase progress rates); today only a full stall triggers takeover, which is deliberately the most conservative choice.
- True cross-database median computation for the mistuned-baseline detector (today: overdue-count-weighted average of per-database medians, now computed centrally from `database_state`).
- Delta sampling of `pg_stat_io` timing and evictions to refine the WAL-rate storage guardrail; Linux PSI/disk telemetry; cgroup CPU quota detection.
- Application-latency and connection-pressure guardrails.
- Per-database policy overrides (today: one cluster policy plus include/exclude patterns and name-keyed `table_policy` rows).
- An upgrade script from 1.1.0 (the 1.2.0 redesign ships without one; a migration would have to move per-database `relation_state` rows into `table_state` with the database OID and merge the per-database policies into one).
- `aging_tables` across databases from the control database (today it lists the database it is queried in).
- TOAST-specific reloption policy (TOAST age is already assessed).
- Prometheus-compatible status functions.
- Property and concurrency tests for the sweep scheduler.

## 21. Important decision summary

| Decision | Rationale | Trade-off |
|---|---|---|
| Background-worker extension | Tight integration, no external scheduler | Superuser C code and per-major rebuilds |
| **One control plane per cluster (control database)** | Install once; no per-database `CREATE EXTENSION`; state in ordinary tables with no capacity limit; one place to query | The control database must exist and stay connectable; copies elsewhere are ignored, not merged |
| Launcher, one controller, database workers | Database-local catalogs require database-local connections; one controller gives one decision per sweep | More process orchestration; a slow database delays the sweep's decision, though not the other databases' scans |
| **SQL program shipped to workers as a `DO` block** | Managed databases need no extension objects; the program is versioned with the control database and reviewable as SQL | One long anonymous block, re-parsed per scan and debugged through its result document; input travels through a session GUC |
| **Control database, not shared memory, as the aggregate store** | No slot capacity, no warm-up sweep, durable across restarts, queryable (`database_state`) | A few catalog-sized queries per sweep in the control database; shared memory keeps only identity and generation counters |
| Cluster settings decided once per sweep by the controller, from complete evidence | Removes the scan-order race and the per-GUC cooldown of the per-database design; incomplete evidence never changes settings | A single failing database holds cluster changes until it scans or is excluded |
| **Name-keyed `table_policy`** | Survives dump/restore and OID reuse; one central row addresses a relation in any database | A rename detaches the row (update it by name); rows for missing relations are kept, not reported |
| Next XID read without allocation (`ReadNextFullTransactionId()`) | Measuring the XID rate never advances the counter it measures | Needs C; the SQL fallback uses the snapshot xmax |
| Bounded worker concurrency (default 2 slots) | One slow database (e.g. an in-cycle ANALYZE) cannot starve the other databases' wraparound checks; emergencies are outside the slots anyway | Two transient worker slots consumed from `max_worker_processes`; set 1 for a strictly serial scan |
| Shared emergency slot in shared memory | Restart-safe one-emergency-vacuum admission cluster-wide | Emergencies queue behind each other by design |
| SQL policy, C orchestration | Reviewable, upgradeable policy | More boundary code |
| Active default (dry-run opt-in) | Installing is opting in; a server nobody tunes gets managed without a second step | An unreviewed install writes cluster settings; bounded steps, allow-list, audit and baseline recovery carry the risk |
| Worker pool not capped by CPU count, not blocked by CPU load | Shared cost budget means workers add concurrency, not proportional I/O; small hosts with long overdue queues need more than one worker per CPU and are exactly the hosts that show load | Relies on the memory and storage gates, the memory cap and `recommendation_workers_max`; the cost pair still holds under CPU pressure |
| `autovacuum_naptime` ramped down and decayed | One new worker per database per naptime made a large pool useless during a backlog | One launcher catalog pass per database per interval while it is short |
| **Cluster settings applied, not just recommended** | Autovacuum starvation is a cluster problem; a human-in-the-loop for every correction re-creates the gap the tool closes | Writes `postgresql.auto.conf`; needs allowlists, complete-evidence gating, old-value audit, and an opt-out (all provided) |
| Fleet-derived trigger ceiling | A constant cap is either wrong for small fleets or useless for big ones | Recomputed each sweep; hysteresis needed against churn |
| **Table settings recommended, never written** | The automatic path loosened operator-tuned triggers in a drill (a 5,000-tuple floor turned 1% into 5%) and took locks the operator could not schedule; ready-to-run SQL keeps the operator in control | The operator must act; an applied boost stays until they revert it (the revert is recommended too) |
| Never-loosen guard | A recommendation that fires later than the current trigger hides an existing backlog | Tables tuned tighter than the target get cost advice only |
| `autovacuum = off` repaired before the sweep and on reload | The most dangerous misconfiguration must not wait for a sweep over every database | One cheap query per sweep and per reload |
| Activity feedback in cost units, not MB/s | Comparable with the budget the cost pair allows; a raise nobody spends is visible without guessing at storage | Cannot say why the budget is unused; the hold reason lists causes instead of naming one |
| Worker count ratchet-up only | More workers ≠ more un-boosted I/O (shared budget splits); lowering is workload policy | Over-provisioned workers persist until an operator trims |
| Cost boosts bounded cluster-wide (`max_boosted_relations`) | Boosted tables bypass core cost balancing; unbounded boosts multiply I/O | The third urgent table waits for a slot |
| Emergency vacuum with failsafe profile (`INDEX_CLEANUP OFF`, `FREEZE`) | Fastest safe path to advancing `relfrozenxid`, mirrors core failsafe | Leaves index cleanup to a later normal vacuum |
| Takeover only on observed stall, never on age or ETA | Age rises through any healthy long vacuum (relfrozenxid updates at the end); cancelling working vacuums makes wraparound worse | A slowly progressing doomed vacuum is left alone until it truly stalls |
| TOAST-aware age assessment | TOAST ages independently; main-heap-only checks under-estimate risk | One extra catalog join per scan |
| Direct `vacuum()` / `AlterSystemSetConfigFile()` APIs | Correct execution outside SPI's utility restrictions | The most version-sensitive C boundaries |

## 22. Primary PostgreSQL references

- Background workers: https://www.postgresql.org/docs/18/bgworker.html
- Autovacuum configuration: https://www.postgresql.org/docs/18/runtime-config-autovacuum.html
- Resource consumption: https://www.postgresql.org/docs/18/runtime-config-resource.html
- Routine vacuuming and wraparound: https://www.postgresql.org/docs/18/routine-vacuuming.html
- Vacuum progress reporting: https://www.postgresql.org/docs/18/progress-reporting.html
- Table storage parameters: https://www.postgresql.org/docs/18/sql-createtable.html
- `ALTER TABLE`: https://www.postgresql.org/docs/18/sql-altertable.html
- `ALTER SYSTEM`: https://www.postgresql.org/docs/18/sql-altersystem.html
- Server source, `vacuum.h`: https://github.com/postgres/postgres/blob/REL_18_STABLE/src/include/commands/vacuum.h
- Server source, core autovacuum: https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/postmaster/autovacuum.c
