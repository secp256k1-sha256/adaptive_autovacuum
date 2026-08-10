# Validation status

## Completed in this package

- Source is guarded for PostgreSQL 18 and later with `PG_VERSION_NUM`.
- The C API use was checked against PostgreSQL 18 declarations for background workers, shared-memory hooks, `VacuumParams`, `makeVacuumRelation()`, and `vacuum()`.
- SQL policy and C orchestration were reviewed for transaction boundaries, reversible reloption ownership, admission limits, stale request recovery, and emergency-worker cleanup.
- The architecture DOCX was rendered to 14 page images and every page was visually inspected for clipping, overlap, table breakage, and missing text.
- GitHub Actions is included to compile, install, initialize PostgreSQL 18, and run `make installcheck` in the official `postgres:18` container.

## Not completed in the current execution environment

The local container has PostgreSQL 17 `pg_config` but no PostgreSQL 18 server headers or server binaries. Therefore the extension was not compiled, linked, loaded, or executed locally against PostgreSQL 18. The source should be treated as a reference implementation until the included PostgreSQL 18 CI job passes and production-like concurrency testing is completed.

## Validation performed 2026-08-08 (post-review fixes)

Compiled against PGDG PostgreSQL 18.4 on EL9 (AlmaLinux 9 build host; gcc 11.5)
and validated on Rocky Linux 9.6 (Veeam VBR v13 appliance, agord-13l-vbr,
scratch PG 18.4 instance on port 55432, product PG 17 untouched):

- `make installcheck` passes (expected output regenerated from a real
  `pg_regress` run; the originally shipped file was hand-written and could
  never match).
- Functional cycle: backlog_critical detection -> `set_reloptions` applied
  including cost boost with `autovacuum_vacuum_cost_delay=0` (the value that
  crashed before the `to_char` trailing-dot fix) -> after `VACUUM`, state
  returns to normal and original reloptions restored.
- Background-worker end-to-end: launcher + database worker autonomously
  detected and fixed a bloated table with no manual `_run_cycle` call.
- `CREATE DATABASE`/`DROP DATABASE` completes in 0.26 s while the launcher
  runs. Before the `CHECK_FOR_INTERRUPTS()` fix in the worker wait loops the
  DROP hung indefinitely on its ProcSignalBarrier (reproduced live).
- `host_metrics()` returns real load/CPU/memory values on Linux.

Fixes applied in this revision:

1. C: `CHECK_FOR_INTERRUPTS()` in both bgworker wait loops (launcher naptime
   loop and database-worker wait loop) so ProcSignalBarriers are absorbed;
   without it any `DROP DATABASE` in the cluster blocks forever.
2. SQL: reloption values formatted via `trim(trailing '.' from to_char(...))`;
   whole-number cost delays / scale factors previously rendered as `2.`/`0.`
   and failed the numeric validation regex, so every cost boost errored.
3. SQL: `pg_stat_progress_vacuum` joined with a `datid` filter (cluster-wide
   view; cross-database relid collisions previously faked
   `vacuum_already_running` and suppressed emergency queueing).
4. SQL: stale-request recovery also compares `backend_start <= started_at`
   so a recycled PID cannot leave an emergency request stuck `running`.
5. SQL: `failed` emergency-queue rows are now purged by history retention.
6. SQL: relation scan uses `relpages`-based size estimate (falling back to
   `pg_total_relation_size` only for unanalyzed relations) and
   `pg_stat_get_live_tuples()/pg_stat_get_dead_tuples()` instead of a join
   against the `pg_stat_all_tables` view; avoids per-relation locking across
   the whole of `pg_class` every cycle.
7. Test: `_reconcile_relation_options` is called with a schema-qualified name
   (the function pins `search_path`, so unqualified names never resolve).

Still open (by design of this revision): the whole policy cycle runs in one
transaction (long-snapshot concern on very large databases), OID-keyed config
tables are not dump/restore-safe, and the emergency path has no retry cap.

## Validation performed 2026-08-09 (insert backlog, cost ramp/budget, workers)

Features added and validated with a 5-minute pgbench mixed workload
(36,625 TPS: one table updated 20x more than two others, plus one
insert-only table at ~11,400 inserts/s) against a deliberately weak
autovacuum baseline (scale_factor=0.4, threshold=5000, cost_limit=50,
cost_delay=20ms), launcher cycling every 15 s:

- Insert backlog policy: `n_ins_since_vacuum` vs the effective insert trigger
  drives the same elevated/urgent/critical ladder; the controller manages
  `autovacuum_vacuum_insert_threshold`/`autovacuum_vacuum_insert_scale_factor`.
  Observed: the insert-only table was flagged 30 s into the run, its insert
  threshold was applied and rescaled as the table grew, and the original
  settings were restored automatically after the workload stopped.
- Cost-boost ramp: boosts enter at the elevated tier and multiply by
  `boost_ramp_factor` per change window, capped by the severity tier.
  Observed on two tables: 1000 -> 2000 -> 4000, no instant jump to maximum.
- Cluster boost budget: `boost_total_cost_limit_budget` caps the sum of all
  active boosted cost limits.
- `recommended_autovacuum_workers` added to global recommendations
  (recorded, never auto-applied); triggers only when the overdue-relation
  count exceeds the current worker count (not reached in this run).
- Hysteresis correctness: the two lightly-updated tables were flagged once,
  recovered on their own via normal autovacuum, and the controller correctly
  made no change.
- `make installcheck` green with new reconcile tests for the insert options.

## Validation performed 2026-08-09/10 (cluster-first management)

The extension was reworked to APPLY cluster-wide settings (production-DBA
model: optimized globals first, per-table reloptions for outliers), via a
`global_apply_queue` written by the SQL policy and applied by the C worker
through `AlterSystemSetConfigFile()` + reload (ALTER SYSTEM cannot run through
SPI), with a strict 11-GUC whitelist, numeric validation, per-GUC cooldown,
and old-value audit. Validated live against re-sabotaged baselines:

- Escalating cost repair: cost_limit 25 -> 200 -> 400 -> 800 (and delay
  50 -> 6.25 ms) in autonomous cooldown-spaced rounds during a pgbench run;
  per-table overrides simultaneously shrank to the single 20x outlier table.
- Eight-GUC correction in ONE launcher cycle: cost limit/delay, workers
  3 -> 8 (9 overdue relations vs 3 workers), vacuum baseline 0.8/50000 ->
  0.2/500, insert baseline 0.8/100000 -> 0.2/2000, analyze threshold
  50 -> 250; analyze scale factor correctly left as a no-op (desired ==
  current). Multi-database convergence observed (a second database's worker
  applied the next cost escalation from its own queue).
- Fleet-derived PostgreSQL 18 trigger ceiling: autovacuum_vacuum_max_threshold
  100,000,000 -> 5,000, derived from the largest eligible relation's
  dead-tuple target (ratio x rows, clamped to policy bounds) with a
  tighten-fast/raise-only-if-grossly-tight hysteresis band; subsequent cycles
  stable ("no change justified"), no flapping.

## Validation performed 2026-08-10 (Windows)

Built with Visual Studio 2019 MSVC (`build_windows.bat`) against EDB
PostgreSQL 18.4 on Windows 11 (24 cores / 64 GB) and installed into the
existing EDB cluster (`shared_preload_libraries` via ALTER SYSTEM + service
restart). Same source file as the Unix build; platform code is confined to
host-metric collection.

- pgbench mixed workload (6 update tables, one at 20x, 2 insert-only;
  8 clients, 300 s): 26,799 TPS, 8.03 M transactions, 0 failed.
- Windows host metrics: CPU busy sampling (GetSystemTimes over 200 ms)
  reported load1 = 4.3 on 24 cores under load; memory from
  GlobalMemoryStatusEx. (Load-average substitute cannot exceed the core
  count; Windows deployments should size high_load_per_cpu below 1.0.)
- Cluster-first management on Windows: within two cycles of enablement the
  extension applied 7 settings via AlterSystemSetConfigFile() + SIGHUP
  emulation - cost limit 25 -> 200, delay 50 -> 25 ms, workers 3 -> 4,
  vacuum baseline 0.8/50,000 -> 0.2/500, analyze threshold 50 -> 250, and
  the fleet-derived ceiling 100,000,000 -> 11,472 (1% of the largest table,
  1.15 M rows) - all confirmed in pg_settings.
- Per-table path: outlier reloptions applied and automatically restored
  within the observation window; lock-timeout guard exercised once.
- End state stable: "No cluster-level cost change is currently justified."

## Validation performed 2026-08-10 (absolute-age emergency redesign)

The emergency wraparound trigger was redesigned per the AWS RDS
early-warning model (MaximumUsedTransactionIDs, alarm at 1 billion):
the manual emergency vacuum no longer fires at 85% of
autovacuum_freeze_max_age (unthrottled I/O in territory the cost-limited
built-in forced autovacuum handles routinely). It now requires an
ABSOLUTE table age (policy emergency_xid_age/emergency_mxid_age,
default 1,000,000,000) AND the age to already exceed the effective
autovacuum_freeze_max_age. The 0.70 ratio remains as a passive
wraparound_warning; xid_critical_ratio/mxid_critical_ratio were
removed. Added the per-database wraparound_status early-warning view
(ok / watch at half threshold / alarm at threshold, headroom to the
~2.14B read-only cutoff) and age-ordered emergency queue priority.

Validated live on Windows EDB PostgreSQL 18.4 with a scaled drill
(freeze_max_age=100,000 = the minimum, emergency_xid_age=150,000 =
the same 5x prod ratio, built-in autovacuum disabled so it could not
race the extension; XIDs burned by pgbench in a different database):

- At age 120,004 (120% of freeze_max_age; the OLD design fired at
  85,000): state wraparound_warning, decisions log 'observe' only,
  emergency queue EMPTY across three cycles.
- At age 160,007 (past the absolute threshold and past freeze_max_age):
  wraparound_critical, one queue row, the C worker's failsafe vacuum
  froze the 86 MB / 600K-row table to age 1, state returned to normal.
- wraparound_status tracked the drill database ok -> alarm and showed
  2.14 billion transactions of remaining headroom throughout.
- Evidence: adaptive_autovacuum_pgbench_report_run2/
  wraparound_redesign_evidence.txt. Cluster GUCs reset and scratch
  database dropped afterwards.

## Validation performed 2026-08-10 (evidence-based emergency criteria, final)

The absolute-age trigger from the previous entry was refined the same
day: the emergency now requires EVIDENCE that the built-in autovacuum
is failing, judged from its own behavior.

- NEVER-STARTED: no vacuum on the relation although age >=
  LEAST(emergency_xid_age, emergency_stall_multiplier x effective
  freeze_max_age); defaults 1B / 1.5 (multiplier CHECK > 1.0 so it can
  never fire before the built-in trigger point).
- TAKEOVER: an autovacuum has ground on the relation for >=
  emergency_takeover_min_runtime_seconds (default 3600) and the age
  still crossed the stall line, or heap progress projects completion
  after the read-only cutoff at the measured XID rate (64-bit xact
  counter sampled per cycle into the new controller_state table). The
  doomed worker is cancelled (pg_cancel_backend) and replaced by the
  index-skipping profile. Gate = backend_type 'autovacuum worker', NOT
  the "(to prevent wraparound)" tag - a dead-tuple-triggered autovacuum
  past the trigger runs the aggressive freeze WITHOUT the tag (proven
  in drill B); manual vacuums are never judged or cancelled.
- Mistuned autovacuum_freeze_max_age (< 50M or > 1.2B) is flagged in
  the recommendation reason (record-only; postmaster context).
- active_vacuums view gained is_autovacuum.

Drills on Windows EDB PostgreSQL 18.4 (freeze_max_age = 100,000 = the
minimum -> stall line self-derives to 150,000; emergency_xid_age left
at its 1B default in both drills):

- Drill A (never-started; autovacuum off + naptime maxed): at age
  120,004 observe-only warning across three cycles (the original 85%
  design fired at 85,000); at 160,007 queued and froze the table to
  age 1. First cycle also produced the "abnormally low (100000)"
  freeze_max_age WARNING in the recommendation.
- Drill B (takeover; autovacuum ON but cost_limit=10/delay=100ms, all
  600K rows updated so 10,000 heap blocks + index needed real work):
  the built-in worker ground 431 s (1 index pass, phase "vacuuming
  heap", wait_event VacuumDelay, antiwraparound = FALSE because dead
  tuples triggered it). When the age crossed 160,068 the controller
  logged queue_emergency_takeover, cancelled pid 24780 (server log:
  "canceling autovacuum task"), and the emergency vacuum finished in
  ONE second (13:04:41 -> 13:04:42), table age 160,068 -> 9. The
  measured XID rate fed the reason's headroom figure (848,817 s).
- make-installcheck-equivalent suite green: 15 assertions incl. new
  emergency-trigger defaults and controller_state seeding.
- Evidence: adaptive_autovacuum_pgbench_report_run2/
  wraparound_redesign_evidence.txt. Cluster reset, scratch DBs dropped.

## Validation performed 2026-08-10 (Linux re-test of the final revision)

Full fresh pass on Rocky Linux 9.6 (Veeam appliance, scratch PG 18.4 on
port 55432, product PG 17.10 untouched): PGDG packages + gcc/make from
temporary Rocky 9.6 vault repos, PGXS build (`with_llvm=no` - the PGDG
bitcode step expects llvm21, absent from the 9.6 vault; the .so is
unaffected).

- `make installcheck` green (15 assertions; the expected file
  regenerated on Windows matches genuine pg_regress output on Linux).
- Cooperative stand-back proven end-to-end: when core wraparound
  protection responded on time (it launches emergency workers even
  with `autovacuum = off`), the controller logged
  `vacuum_already_running` and made no change while the built-in
  vacuum froze the table.
- Never-started drill (per-table freeze_max_age reloption 100,000,
  global at default so the cluster-level tripwire stays silent):
  emergency fired at age 150,010 against the self-derived 150,000
  stall line, table frozen to age 1. Mistuned-freeze_max_age WARNING
  reproduced while the global was 100,000.
- Takeover drill (autovacuum on, cost_limit=10/delay=100ms, 148 MB /
  14,815 blocks of real freeze work): built-in anti-wraparound vacuum
  observed grinding (182/14815 blocks at 73 s); after seven
  `vacuum_already_running` observation cycles the controller issued
  `queue_emergency_takeover` at age 160,031 with a live ETA projection
  in the reason ("projected remaining 5234 s vs 808383 s of XID
  headroom" - the measured XID rate in action), cancelled pid 3068181
  (server log: "canceling autovacuum task"), and froze the table to
  age 1 in under a second.
- Lab returned to its clean state: scratch cluster deleted, PG18 +
  toolchain removed via dnf history undo, temp vault + pgdg repos
  removed, /usr/pgsql-18 gone, port 55432 free, product PG 17.10
  verified running.
- Evidence: adaptive_autovacuum_pgbench_report_run2/
  linux_retest_v12_evidence.txt.

## Required release gate

For each supported PostgreSQL major version:

1. Compile with that major's server development package.
2. Run `make installcheck`.
3. Test with assertions enabled.
4. Exercise launcher restart, worker timeout, SIGTERM during VACUUM, stale queue recovery, ownership conflict, cgroup memory limits, and active anti-wraparound autovacuum.
5. Run sustained workload tests before enabling non-dry-run actions.
