# Adaptive Autovacuum Architecture Guide

**Target:** PostgreSQL 18 and later
**Extension version:** 1.0.0 reference implementation (revised 2026-08-10; supersedes the original recommendation-only design)
**Safety posture:** disabled by default, dry-run by default, per-table cost boosts and emergency execution disabled by default; cluster-setting management enabled by default but inert until dry-run is lifted

## 1. Purpose

The extension is a bounded controller around PostgreSQL's existing autovacuum subsystem. It does not replace the core autovacuum launcher or workers. It observes whether table maintenance is falling behind and acts at two levels, mirroring how production DBAs tune autovacuum:

1. **Cluster level first.** Autovacuum is a cluster-wide phenomenon — one worker pool, one shared cost budget, one trigger baseline. When the data shows a cluster setting is wrong, the controller corrects it through `ALTER SYSTEM` plus configuration reload, within a fixed allowlist, rate limits, and a full old-value audit.
2. **Table level for outliers.** Relations that remain special after the baseline is right — disproportionate-DML tables, very large tables, insert-only tables — receive reversible per-table storage parameters that are automatically restored once the relation is healthy.

It can additionally execute a guarded manual vacuum when a relation's transaction-ID age is critical and no equivalent vacuum is active.

The central design objective is not maximum vacuum speed. It is to reduce backlog and wraparound risk without creating uncontrolled I/O, memory, DDL-lock, or configuration churn.

## 2. Goals and non-goals

### Goals

- Detect persistent dead-tuple backlog and insert backlog rather than react to one noisy sample.
- Correct the cluster-wide autovacuum baseline (trigger thresholds and scale factors for vacuum, insert-vacuum, and analyze; cost limit and delay; worker count; autovacuum memory) when evidence shows it is mistuned — applied automatically with rails, or recorded as recommendations when the operator prefers.
- Size the PostgreSQL 18 dead-tuple trigger ceiling (`autovacuum_vacuum_max_threshold`) from the actual fleet rather than a constant.
- Derive per-table thresholds from a target dead-tuple / inserted-rows budget for outlier relations only.
- Allocate stronger table-level cost settings gradually (ramp), to a bounded number of urgent relations, under a cluster-wide sum budget.
- Recognize XID and MXID age independently from ordinary dead-tuple pressure, **including the TOAST relation's own age**.
- Use PostgreSQL 18 vacuum-progress information, including cost-delay time and repeated index-vacuum cycles.
- Consider effective memory limits in Linux cgroups as well as host memory.
- Preserve and restore pre-existing table reloptions; record pre-change values for every cluster setting it touches.
- Stop automatic table writes if a DBA changes a controller-owned key; respect stricter operator-set cluster values.
- Make every automatic action explainable through decision history and change audits.

### Non-goals in this version

- Replacing core autovacuum scheduling.
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
  +-- adaptive autovacuum launcher
        connection: control_database
        responsibility: enumerate databases and allocate one dynamic worker
        |
        +-- short-lived database worker for database A
        |     connection: database A
        |     actions: evaluate policy, reconcile reloptions,
        |              apply queued cluster settings, optionally VACUUM
        |
        +-- short-lived database worker for database B
        |
        +-- short-lived database worker for database C
```

The launcher is registered from `_PG_init()` while the library is loaded through `shared_preload_libraries`. It connects to the configured control database, reads the shared `pg_database` catalog, and starts dynamic database workers sequentially.

A background worker belongs to the cluster, but an internal backend connection is initialized for one database. The launcher therefore cannot use one SPI connection to inspect every database-local `pg_class`, statistics view, policy table, and relation. The launcher-plus-database-workers topology mirrors the database-routing principle used by core autovacuum.

Both worker wait loops call `CHECK_FOR_INTERRUPTS()` after every latch wake-up. This is load-bearing: `DROP DATABASE` (and other operations built on process-signal barriers) waits on **every** process in the cluster, and a background worker that never absorbs those barriers blocks such commands indefinitely. This was found and fixed through live testing.

### Why workers are sequential in this implementation

Sequential workers keep controller concurrency low and make behavior easy to reason about. In addition, the extension reserves one small shared-memory emergency slot containing the owning worker PID and database OID. A worker must acquire this slot before claiming a queue item, and an exit callback releases it. A later worker can reap a slot whose PID is no longer present in the process array. This preserves the one-emergency-vacuum cluster limit across launcher restarts and abnormal worker exits. The trade-off remains scan latency: a long emergency vacuum delays policy evaluation in later databases.

## 4. Components

### 4.1 C launcher

Responsibilities:

- Define extension GUCs.
- Register the static launcher.
- Enumerate connectable, non-template databases.
- Start and supervise one dynamic worker at a time.
- Terminate a database worker after the configured timeout.
- Reload SIGHUP settings; absorb process-signal barriers.

It does not evaluate table policy.

### 4.2 C database worker

Responsibilities:

- Connect internally to one database by OID.
- Verify that the extension exists and the database policy is enabled.
- Read host and cgroup memory information.
- Invoke the SQL policy evaluator in one transaction.
- **Apply queued cluster-setting changes**: claim pending rows from `global_apply_queue` (`FOR UPDATE SKIP LOCKED`), validate each GUC name against a fixed C-side allowlist and each value as a plain numeric literal, capture the current value, call the exported `AlterSystemSetConfigFile()` entry point, mark the row applied with its old value, and signal the postmaster to reload. `ALTER SYSTEM` cannot be executed through SPI (utility statements from functions are rejected), which is why the C worker calls the internal entry point directly.
- Acquire the cluster-wide shared-memory emergency slot, then claim at most one queue item.
- Run a manual vacuum with session-local maintenance and cost settings.
- Record completion or failure and release the emergency slot on both normal and abnormal exit.

### 4.3 SQL policy layer

The policy layer contains the tunable logic and durable state:

- `policy`: one database-wide policy row.
- `table_policy`: optional per-relation overrides or exclusion.
- `relation_state`: hysteresis, ownership, original reloptions, and recent metrics (dead and insert backlog).
- `decisions`: an append-only explanation log within the retention window; every row carries the host metrics the decision was made under.
- `global_recommendations`: computed cluster-level values with a human-readable reason (always recorded, regardless of whether they are applied).
- `global_apply_queue`: cluster-setting changes awaiting or completed application, with old value, status, and error.
- `emergency_queue`: guarded manual-vacuum requests.
- `changed_tables` (view): one row per (relation, managed key) with original versus current value — the operator-facing answer to "what has it changed right now."

Keeping policy in SQL makes most changes reviewable and upgradeable without adding more C-level dependencies on PostgreSQL internals.

## 5. Safety gates

An automatic write requires all applicable gates:

1. The library is preloaded.
2. `adaptive_autovacuum.enabled` is on at cluster level.
3. The extension exists in the target database.
4. `adaptive_autovacuum.policy.enabled` is true in that database.
5. `dry_run` is false.
6. **For cluster settings:** `manage_global_settings` is true; the GUC is on the C-side allowlist; the value passes numeric validation; no pending change for it already exists; the new value actually differs numerically from the current one. There is deliberately no per-GUC cooldown: correlated settings must be able to move together (raising `autovacuum_max_workers` alone splits the same `cost_limit` across more workers, so the cost side must be able to follow on the next cycle). The naptime between cycles and the at-most-doubling step provide the pacing.
7. **For table changes:** the table is not excluded; the observed condition has persisted for the hysteresis window; the relation is outside its change cooldown; no vacuum is currently reported for that relation; the controller still owns every previously managed reloption; the per-cycle DDL limit has not been consumed.
8. For table cost changes, `manage_table_costs` is true, the admission limit permits the relation, and the cluster-wide boost budget has headroom.
9. For emergency vacuum, `emergency_vacuum_enabled` is true and no active or recently failed equivalent request exists.

These gates are independent. Enabling the launcher does not implicitly enable a database policy, and enabling a database policy does not disable dry-run.

## 6. Observation model

### Relation signals

The policy reads, per eligible relation:

- `pg_class.reltuples`, `pg_class.relpages`, `pg_class.reloptions`
- `pg_class.relfrozenxid` and `pg_class.relminmxid` — **combined with the TOAST relation's** `relfrozenxid`/`relminmxid` via `GREATEST(...)`, because the TOAST table ages independently and is easy to miss
- `pg_stat_get_live_tuples()` / `pg_stat_get_dead_tuples()` / `pg_stat_get_ins_since_vacuum()` (direct per-relation statistics functions; cheaper than joining the `pg_stat_all_tables` view across the whole catalog)
- relation size, estimated from `relpages × block size` with a `pg_total_relation_size()` fallback only for never-analyzed relations (avoids taking a lock on every relation and its indexes each cycle)
- `pg_stat_progress_vacuum` joined to `pg_stat_activity`, **filtered to the current database's `datid`** (the view is cluster-wide; an unfiltered join lets a same-OID relation in another database masquerade as a local vacuum)

The statistics tuple counts are estimates. The controller therefore uses persistence across cycles and coarse state tiers rather than treating one estimate as exact.

### Vacuum-progress signals

PostgreSQL 18 exposes fields used by this implementation: elapsed time from the matching activity row, `delay_time`, `index_vacuum_count`, dead-tuple byte counters, and heap-block progress/phase. `delay_time` is useful only when `track_cost_delay_timing` is enabled. A high delay fraction suggests cost throttling; repeated index-vacuum cycles indicate the dead-TID store could not hold all work in one pass and justify more autovacuum memory. The count of running autovacuum workers versus `autovacuum_max_workers` provides the worker-saturation signal.

### Host signals

The C worker gathers the one-minute load average, online CPU count, and total/available memory. On Linux it reads `/proc/meminfo` and then constrains memory to the current cgroup v2 or v1 memory limit when that limit is lower than host RAM.

On Windows there is no load average. The worker samples the system-wide CPU busy fraction over a 200 ms window (`GetSystemTimes()`) and reports `busy_fraction × cpu_count` as `load1`; memory comes from `GlobalMemoryStatusEx()`. The semantic difference matters for the pressure gate: a Unix load average includes processes waiting to run and can exceed the CPU count, while CPU utilization saturates at 1.0 per CPU — so the default `high_load_per_cpu = 1.5` is unreachable on Windows and deployments there should size it below 1.0 (for example 0.85) if CPU-based pressure gating is desired. Memory-based pressure works identically on both platforms.

Limitations: CPU count is not constrained by cgroup CPU quota; load average / CPU busy is not an application-latency signal; disk latency, queue depth, and PSI are not read. Host pressure therefore blocks or reduces aggressive actions, but absence of reported pressure is not proof that more I/O is safe.

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

Trigger reloptions are changed only for backlog states and only when normal autovacuum is enabled globally and for the table. A table-level `autovacuum_enabled = false` does not disable core wraparound protection, so XID/MXID monitoring and the guarded emergency path remain active.

### Cluster baseline correction (mistuned-baseline detector)

Per-table overrides are for outliers. When at least **3 relations and 25% of the eligible fleet** are dead-overdue in the same cycle, the baseline — not the tables — is wrong. The controller then takes the **median** of the per-relation desired thresholds and scale factors as the new cluster-wide `autovacuum_vacuum_threshold` / `autovacuum_vacuum_scale_factor`, keeps `autovacuum_analyze_scale_factor`/`_threshold` in proportion (half the vacuum scale, PostgreSQL's default ratio, with floors), and the same rule applies independently on the insert side for `autovacuum_vacuum_insert_*`.

### Fleet-derived trigger ceiling

`autovacuum_vacuum_max_threshold` — PostgreSQL 18's cap that lets one sane percentage coexist with very large tables — is not a constant here. It is derived every cycle as the dead-tuple target of the **largest** eligible relation (ratio × rows, clamped to the policy bounds): the biggest table never waits longer than its own policy target, while smaller relations keep triggering via the scale factor because their computed trigger stays below the ceiling. Hysteresis prevents churn: the ceiling is tightened when disabled or more than 10% looser than derived, raised only when grossly over-tight (below half of derived), and anything in between is respected as operator intent.

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

The controller increments `consecutive_overdue` while a relation is non-normal and changes settings only after `overdue_cycles_before_change`. It increments `consecutive_healthy` while normal and restores original options only after `healthy_cycles_before_restore`. A per-relation cooldown prevents frequent tier changes; cluster settings are paced by the cycle naptime and the at-most-doubling step (see §10). Changes are coarse and state-based rather than proportional on every sample, reducing oscillation.

## 9. Cost management

### Cluster level

The shared autovacuum cost budget (`autovacuum_vacuum_cost_limit`/`_cost_delay`) is corrected automatically: raised step-wise (at most doubled per change window, capped by `recommendation_cost_limit_max`) when long vacuums are delay-bound or relations are overdue without host pressure, and *reduced* under host pressure. The delay walk-down halves per window but stops at `recommendation_delay_min_ms` (default 0.5 ms): delay 0 equals unthrottled manual-vacuum aggression and is never reached automatically, while an operator-chosen delay already below the floor is respected and never raised.

Two memory-side settings are sized opportunistically while maintenance is actually running and the host has free memory — an idle cluster is never retuned. `vacuum_buffer_usage_limit` (PG16+, the shared_buffers ring a VACUUM/ANALYZE may occupy; an idle ring costs nothing) is at most doubled per cycle up to `recommendation_buffer_usage_limit_max_mb`, additionally bounded by the server's own silent 1/8-of-shared_buffers clamp divided across the worker pool so concurrent rings cannot crowd out the workload's cache; it is halved back toward the built-in default under host pressure, and an operator value of 0 ("no limit") is never touched. `autovacuum_work_mem` keeps its evidence-based raise (repeated index passes = the vacuum ran out of dead-tuple memory) and additionally ratchets toward the free-memory-derived value while workers are running; it is never lowered without host pressure. Because the shared budget is split across workers, raising `autovacuum_max_workers` does not increase total un-boosted vacuum I/O — it adds parallelism. The worker count is therefore raised (never lowered) when overdue relations outnumber workers or all worker slots are busy while relations wait, independent of the host-pressure gate, bounded by `autovacuum_worker_slots`, a quarter of host CPUs, and `recommendation_workers_max`.

### Table level

Table cost overrides are disabled by default. When enabled, the controller can add `autovacuum_vacuum_cost_limit` / `autovacuum_vacuum_cost_delay` per table, with three protections:

- **Ramp.** A boost enters at the elevated tier and multiplies by `boost_ramp_factor` (default 2.0) once per change window while the relation stays overdue — never a jump to the maximum — capped by the severity tier (elevated/urgent/critical), which also ramps a boost back down when severity drops.
- **Budget.** The *sum* of all boosted cost limits stays within `boost_total_cost_limit_budget`. This is mandatory, not cosmetic: a vacuum running on a table with explicit cost parameters is excluded from core PostgreSQL's cost balancing, so many boosted tables can multiply aggregate I/O far beyond the apparent global budget.
- **Admission.** At most `max_boosted_relations` tables hold boosts simultaneously; the most urgent win. New boosts are refused during host pressure except for critical wraparound.

### In-flight limitation

Changing a table reloption does not retune a worker that has already read the table's options, and the ALTER needs a lock that conflicts with an active vacuum. The controller skips a relation with visible vacuum progress and uses a short lock timeout. Table changes affect future maintenance runs.

## 10. Cluster-setting application

The original design recorded cluster values as recommendations only. Field experience inverted that: autovacuum starvation is a cluster problem (worker pool, cost budget, baseline), and requiring a human to apply every correction re-created the exact operational gap the extension exists to close. The shipped design **applies** cluster settings by default, with the following rails, and downgrades to recommendation-only when `manage_global_settings = false`:

- **Fixed allowlist**, enforced twice: the SQL policy only enqueues the twelve managed maintenance GUCs, and the C applier independently rejects anything outside its compiled-in list.
- **Numeric validation** of every value at both layers, plus **bounds validation**: the SQL policy never enqueues a value outside the GUC's own `pg_settings` min/max, the `policy` table's CHECK constraints cap every knob that feeds a bounded setting at that setting's documented maximum (cost limits ≤ 10000, delays ≤ 100 ms, scale factors ≤ 100, work_mem below the kilobyte-conversion overflow), and the C applier isolates each queue row in a subtransaction — a value the server rejects is marked failed individually instead of aborting the whole apply cycle and being retried until expiry. One constraint the server does NOT reject is enforced explicitly at apply time: `autovacuum_max_workers` above `autovacuum_worker_slots` is merely warned about and capped at runtime, so the applier fails such a row itself — the policy caps its own recommendation, but a queued row can outlive a restart that lowered the slot count, and manual queue inserts bypass the policy.
- **Deduplication and a no-op filter**: at most one pending change per GUC, and a change equal to the current value is never enqueued. Pacing comes from the cycle naptime and the at-most-doubling step, not from a timer — a per-GUC cooldown was removed because it starved correlated settings (a workers-only raise dilutes the unchanged cost limit across more workers).
- **Old-value audit**: the applier captures the pre-change value into the queue row, giving a one-statement rollback path.
- **Direction rules**: worker count only rises automatically; the trigger ceiling respects tighter operator values; cost aggression falls under host pressure.
- **Application mechanics**: `ALTER SYSTEM` cannot run through SPI, so the C worker builds the statement nodes and calls the exported `AlterSystemSetConfigFile()`, then signals the postmaster (`SIGHUP`). Every managed GUC is reloadable in PostgreSQL 18, so changes take effect within seconds without restarts.
- **Failure containment**: an invalid row is marked `failed` with a reason; rows that stay pending for an hour expire; the queue is retention-pruned.

In clusters with many managed databases, each database's worker evaluates and may apply cluster changes. Values converge (all workers compute from the same cluster-wide inputs and current settings, and application is idempotent), but audit rows land in the database whose worker acted. A single-coordinator variant remains future work.

Recommendations are still always recorded in `global_recommendations` — including when they are also applied — because the reason text is the operator-facing explanation.

## 11. Memory policy

`autovacuum_work_mem` is a per-worker maximum, so the recommendation divides a bounded fraction of currently available (cgroup-aware) memory across `autovacuum_max_workers`, with floors and caps. It is changed only when a running vacuum is observed making repeated index-vacuum passes — the concrete evidence of a memory-bound vacuum — and never raised under host pressure. The effective current value resolves `-1` to `maintenance_work_mem`.

For a critical emergency relation, the manual vacuum receives a session-local `maintenance_work_mem` calculated from available memory and clamped between emergency minimum and maximum values. This changes only the short-lived database worker session.

## 12. Wraparound controller

The controller calculates, per relation:

```text
xid_age    = greatest(age(main.relfrozenxid),  age(toast.relfrozenxid))
mxid_age   = greatest(mxid_age(main.relminmxid), mxid_age(toast.relminmxid))
xid_ratio  = xid_age  / effective_xid_freeze_max_age
mxid_ratio = mxid_age / effective_mxid_freeze_max_age
```

TOAST inclusion matters: the TOAST relation has its own freeze horizon and lags whenever the main heap is vacuumed with `PROCESS_TOAST off` or by paths that skip TOAST. The effective maximum is the lower of the cluster setting and any nonnegative table-level override.

`wraparound_warning` is relative — a configurable ratio of the effective `autovacuum_freeze_max_age` (default 0.70). It only prioritizes the relation and surfaces visibility; ages between the warning and the forced-vacuum point are core PostgreSQL's job, handled routinely by its cost-throttled anti-wraparound autovacuum.

`wraparound_critical` requires **evidence that the built-in mechanism is failing**, judged from the built-in vacuum's own behavior. An earlier revision fired the emergency at 85% of `autovacuum_freeze_max_age`; that was rejected because a manual `vacuum()` bypasses autovacuum cost balancing, and spending unthrottled I/O in territory the forced autovacuum resolves on its own is pure waste. A later revision used a bare absolute age; the shipped criteria refine it to two failure modes:

- **Never started.** No vacuum is running on the relation although its age is past `stall_age = LEAST(emergency_xid_age, emergency_stall_multiplier × effective freeze_max_age)`. With the 1.5 default the forced autovacuum is 50% of its own trigger overdue — the launcher or worker pool is failing. The absolute `emergency_xid_age` cap (default 1 billion, the AWS RDS `MaximumUsedTransactionIDs` alarm point, ~50% of the ~2.1 billion read-only cutoff) governs clusters running very large `freeze_max_age` values. The multiplier is constrained > 1.0 so the emergency can never fire before the built-in trigger point.
- **Running but hopeless (takeover).** An autovacuum has been running on the relation for at least `emergency_takeover_min_runtime_seconds` (default 3600) and either the age still crossed the stall line while it ground on, or its heap-progress rate projects completion after the read-only cutoff at the measured XID consumption rate (the launcher samples the 64-bit transaction counter each cycle into `controller_state`; the delta gives transactions/second). The doomed worker is cancelled with `pg_cancel_backend()` and the emergency profile — which skips index cleanup, the usual reason such vacuums crawl — replaces it. The gate is `backend_type = 'autovacuum worker'`, **not** the `(to prevent wraparound)` query tag: a dead-tuple-triggered autovacuum past the wraparound trigger runs the same aggressive freeze without the tag, and that mixed shape is the common production case. A manual `VACUUM` is never judged or cancelled.

Complementarily, a mistuned `autovacuum_freeze_max_age` (< 50M: near-constant forced vacuums; > 1.2B: little headroom before `vacuum_failsafe_age` and the read-only cutoff) is flagged in the global recommendation reason. It has postmaster context, so it is record-only — never applied automatically.

The `wraparound_status` view exposes the early-warning model per database (`age(datfrozenxid)` and multixact age, headroom to the read-only cutoff, `ok`/`watch`/`alarm` at half / full `emergency_xid_age`) for external monitoring.

Before queuing an emergency request the controller additionally verifies: emergency execution enabled; dry-run off; no manual vacuum on the relation; no pending/running request; no failed request still in its retry delay. Queue priority orders by absolute age (worst table first).

The emergency worker calls PostgreSQL's exported `vacuum()` entry point for **that single relation** with the wraparound-failsafe profile:

- `freeze_min_age = 0` and `multixact_freeze_min_age = 0` (freeze everything visible, maximal `relfrozenxid` advance),
- table-age thresholds zero (aggressive scan),
- `INDEX_CLEANUP OFF` (index vacuuming dominates runtime and contributes nothing to advancing `relfrozenxid`; a later normal vacuum cleans the indexes),
- `TRUNCATE OFF` (avoids the `ACCESS EXCLUSIVE` tail-truncation phase),
- TOAST processed (it carries its own `relfrozenxid`),
- session-local cost settings and a bounded lock timeout, `is_wraparound = true`.

The database worker must own the shared-memory emergency slot before claiming work, so at most one extension-initiated emergency vacuum runs cluster-wide even across launcher restarts. Note that manual `vacuum()` calls do not produce the server-log "vacuum of table" line (that instrumentation is autovacuum-specific); the queue row timestamps and the age drop are the audit evidence.

### What the controller cannot solve

Vacuum cannot remove or freeze everything it needs while an old snapshot, prepared transaction, replication slot, or standby feedback horizon holds back `OldestXmin`. Resource escalation is not a substitute for diagnosing cleanup-horizon blockers. Operators should correlate critical age with old `backend_xid`/`backend_xmin` values, prepared transactions, replication-slot horizons, long-running transactions, standby feedback, and vacuum logs showing tuples "not yet removable". The extension deliberately does not terminate or alter those objects automatically.

## 13. Reloption ownership and restoration

The controller treats table configuration as shared state with a DBA or configuration-management system.

Before the first successful write it captures the complete original `pg_class.reloptions` array, sets `original_captured = true`, and records the exact keys and numeric values it owns in `managed_values`. On subsequent cycles it compares current values of all managed keys numerically; a difference marks `ownership_conflict` and suspends writes for that table.

When desired managed keys change, a security-definer reconciler validates every key against a fixed allowlist and every value as numeric, restores the original value for a key being released, resets keys that did not originally exist, sets the new desired keys, and uses a transaction-local lock timeout. The managed-key allowlist covers the five trigger keys (vacuum threshold/scale/max-threshold, insert threshold/scale) and the two cost keys.

The explicit `original_captured` flag distinguishes "the original options array was NULL" from "no original state has been captured" — without it, a later tier change could capture controller-written options as the baseline.

## 14. Locking and transaction boundaries

### Policy cycle

Each database policy cycle runs in one transaction through SPI. Relation DDL executes inside PL/pgSQL exception blocks; a failed lock or DDL statement rolls back only that relation's subtransaction and is recorded in the decision log. `ALTER TABLE ... SET/RESET` takes a lock that conflicts with vacuum; the controller checks progress first but still relies on a short `lock_timeout` because observations race with concurrent activity.

### Cluster-setting application

Runs in its own transaction after the policy cycle. The `postgresql.auto.conf` write itself is non-transactional; if the transaction fails after the file write, the row remains pending and the next cycle re-applies the same value — idempotent by construction.

### Emergency vacuum

`VACUUM` manages per-relation transactions internally and cannot be treated as ordinary transactional SQL. The C worker commits the request-claim transaction, applies session-local GUCs, creates a cross-transaction memory context, and invokes `vacuum()` through the C API. Completion or failure is recorded in a separate transaction.

A crash after claim but before completion can leave a queue row in `running`. At the start of each later policy cycle, the SQL layer marks a running request failed when its recorded worker PID is no longer visible in `pg_stat_activity` **or belongs to a backend that started after the request was claimed** (the PID-reuse guard: a recycled PID must not masquerade as the dead worker). The shared-memory slot independently self-heals when its owner PID is no longer in the process array.

## 15. Security model

- Installation requires superuser because it installs C code and a background worker.
- Internal policy functions are `SECURITY DEFINER` with a fixed search path.
- Public privileges are revoked from all internal tables and functions; public read access is granted only to the status views and `host_metrics()`.
- Dynamic SQL receives a relation name built from catalog identifiers; managed keys and values are allowlisted and validated — for table reloptions in SQL, and for cluster GUCs independently in both SQL and C.
- Database workers connect as the bootstrap superuser. This is powerful and is a principal reason for conservative defaults, the narrow actuator surface, and the double-validated allowlists.

Production deployments may replace public view access with a monitoring role and should audit all changes to `policy`, `table_policy`, and controller state.

## 16. Failure modes and responses

| Failure | Behavior | Operator response |
|---|---|---|
| Extension absent in a database | Worker exits normally | Install only where management is intended |
| Database policy disabled | Worker exits normally | Enable after dry-run configuration |
| No background-worker slot | Launcher logs warning and retries next cycle | Increase `max_worker_processes` |
| Table lock unavailable | Relation change skipped and logged, retried later | Inspect competing DDL/vacuum |
| DBA changes a managed table key | Ownership conflict stops writes for that table | Reconcile manually, then clear or re-adopt ownership |
| Cluster-setting row invalid (unknown GUC / non-numeric value) | Row marked `failed` with reason; nothing applied | Investigate source of the bad row |
| Cluster-setting row never applied | Pending rows expire after one hour | Check worker logs |
| Emergency vacuum errors | Request becomes failed with retry delay | Inspect error and cleanup-horizon blockers before retry |
| Worker executing emergency vacuum dies | Stale `running` row recovered via PID + backend-start check; slot self-heals | Alert if a request stays running beyond the worker timeout |
| Database worker exceeds timeout | Launcher sends SIGTERM | Increase timeout only after understanding the workload |
| Launcher/control database unavailable | Static worker exits and postmaster retries | Correct `control_database` |
| `track_cost_delay_timing` off | Delay-bound detection stays blind | Enable and reload |
| Stats reset or inaccurate estimates | State may temporarily mis-estimate backlog | Rely on hysteresis; inspect decision log |

## 17. Version compatibility

The SQL layer targets PostgreSQL 18 columns and semantics (`autovacuum_vacuum_max_threshold`, `pg_stat_progress_vacuum.delay_time`, `autovacuum_worker_slots`, reloadable `autovacuum_max_workers`). The C layer uses server headers and exported backend functions; PostgreSQL does not promise a stable C ABI across major releases. The most sensitive boundaries are the `VacuumParams` structure and `vacuum()` invocation (emergency path) and `AlterSystemSetConfigFile()` (cluster application).

Required release process for every major version: build against that major's headers; compare the declarations above; run regression tests; run an assertion-enabled server; test SIGTERM during policy DDL and during emergency vacuum; test upgrade/uninstall; run sustained workload tests; publish per-major binaries. The compile-time guard rejecting versions below 18 is not proof that an untested future major is compatible.

### Platform compatibility

The SQL layer is operating-system independent. The C layer isolates its platform-specific code to host-metric collection (`#ifdef WIN32` / `#ifdef __linux__` branches); everything else — background workers, signal delivery (`kill(PostmasterPid, SIGHUP)`), `AlterSystemSetConfigFile()`, `vacuum()` — goes through PostgreSQL's own portability layer and works unchanged on Windows.

On Unix the build uses PGXS (`make`). On Windows, PGXS is unavailable for MSVC-built servers (such as the EDB distribution); the provided `build_windows.bat` compiles the DLL with Visual Studio Build Tools directly against the installation's shipped server headers (`include\server\port\win32_msvc`, `win32`, `server`) and links `lib\postgres.lib`. Both artifacts come from the same source file; no platform forks exist.

## 18. Deployment runbook

1. Build and test against the exact PostgreSQL 18 minor environment.
2. Install the library and extension files.
3. Set `shared_preload_libraries`, reserve worker capacity, and restart.
4. Create the extension in one noncritical database.
5. Configure the database policy with dry-run true; enable the cluster GUC and reload.
6. Observe several cycles: review `decisions`, `global_recommendations`, and proposed values against real churn.
7. Turn dry-run off. Cluster-setting management activates here — set `manage_global_settings = false` first if cluster changes must stay manual.
8. Confirm reversible restoration, ownership-conflict behavior, and the cluster-change audit trail.
9. Optionally enable table cost boosts with a small admission limit.
10. Enable emergency vacuum only after rehearsing blockers, cancellation, timeout, and recovery.
11. Alert on critical relation state, ownership conflicts, failed cluster changes, failed/stale emergency requests, and worker-launch failures.

## 19. Recommended alerts

- Any `wraparound_critical` relation, and any `wraparound_status` row at `watch` or `alarm`.
- XID/MXID age still rising after a completed emergency vacuum.
- `ownership_conflict = true`.
- `global_apply_queue` rows in `failed`, or `pending` older than the cooldown.
- Emergency queue status `failed`, or `running` beyond the worker timeout.
- Repeated relation DDL errors.
- Launcher unable to obtain a worker slot.
- Rising overdue-relation counts over successive cycles.
- Repeated index-vacuum cycles while the memory recommendation is capped.

## 20. Future work

- Single-coordinator application of cluster settings (today each managed database may apply; values converge but audit is distributed).
- Shared-memory cluster budget for bounded parallel database workers.
- Delta sampling from `pg_stat_io` and Linux PSI/disk telemetry; cgroup CPU quota detection.
- Application-latency and connection-pressure guardrails.
- TOAST-specific reloption policy (TOAST age is already assessed).
- Explicit cleanup-horizon blocker diagnostics with advisory-only remediation suggestions.
- Prometheus-compatible status functions.
- Maximum attempt count / exponential backoff for emergency requests.
- Dump/restore-safe policy storage (today's tables are OID-keyed).
- Property and concurrency tests for ownership reconciliation.

## 21. Important decision summary

| Decision | Rationale | Trade-off |
|---|---|---|
| Background-worker extension | Tight integration, no external scheduler | Superuser C code and per-major rebuilds |
| Launcher plus database workers | Database-local catalogs require database-local connections | More process orchestration |
| Sequential workers plus shared emergency slot | Low controller concurrency; restart-safe one-vacuum admission | Long vacuum delays later databases |
| SQL policy, C orchestration | Reviewable, upgradeable policy | More boundary code |
| Dry-run default | No accidental changes at install | Requires staged enablement |
| **Cluster settings applied, not just recommended** | Autovacuum starvation is a cluster problem; a human-in-the-loop for every correction re-creates the gap the tool closes | Writes `postgresql.auto.conf`; needs allowlists, cooldowns, old-value audit, and an opt-out (all provided) |
| Fleet-derived trigger ceiling | A constant cap is either wrong for small fleets or useless for big ones | Recomputed each cycle; hysteresis needed against churn |
| Cost boosts ramped and budget-capped | Boosted tables bypass core cost balancing; unbounded boosts multiply I/O | Slower to reach maximum aggression |
| Worker count ratchet-up only | More workers ≠ more un-boosted I/O (shared budget splits); lowering is workload policy | Over-provisioned workers persist until an operator trims |
| Reversible reloption ownership | Preserves DBA intent; prevents tuning debt | Conflict handling and durable state |
| Emergency vacuum with failsafe profile (`INDEX_CLEANUP OFF`, `FREEZE`) | Fastest safe path to advancing `relfrozenxid`, mirrors core failsafe | Leaves index cleanup to a later normal vacuum |
| TOAST-aware age assessment | TOAST ages independently; main-heap-only checks under-estimate risk | One extra catalog join per cycle |
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
