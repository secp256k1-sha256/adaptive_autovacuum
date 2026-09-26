# Validation status

## Completed in this package

- Source is guarded for PostgreSQL 17 and later with `PG_VERSION_NUM` (full feature set on 18).
- The C API use was checked against PostgreSQL 17 and 18 declarations for background workers, shared-memory hooks, `VacuumParams`, `makeVacuumRelation()`, and `vacuum()`.
- SQL policy and C orchestration were reviewed for transaction boundaries, reversible reloption ownership, admission limits, stale request recovery, and emergency-worker cleanup.
- The architecture DOCX was rendered to 14 page images and every page was visually inspected for clipping, overlap, table breakage, and missing text.
- GitHub Actions runs a `postgres:[17, 18]` container matrix: compile, install, initdb, and `make installcheck` twice per major (once loaded on demand, once preloaded).

## CI status, stated plainly

- The PostgreSQL 18 job has run and passed on GitHub Actions (first run failed and was fixed; see the 2026-08-10 CI entry below).
- The PostgreSQL 17 leg and the matrix form were added on 2026-08-14 and have NOT yet run on GitHub Actions. The identical command sequence (build, install, two-pass installcheck) has passed locally against PGDG 17.11 on AlmaLinux 9; treat the hosted PG17 run as pending until the first green matrix run is recorded here.

- 2026-09-20: `test.yml`, `package-rpm.yml`, `package-deb.yml`, `package-windows.yml` and `release.yml` have all run green on GitHub Actions; release `v1.1.0` ("1.1.0 (beta)") was published by `release.yml` with the full matrix (see the 2026-09-20 entry below).

## Validation performed 2026-08-08 (post-review fixes)

Compiled against PGDG PostgreSQL 18.4 on EL9 (AlmaLinux 9 build host; gcc 11.5)
and validated on Rocky Linux 9.6 (PG 18.4 instance on port 55432):

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

Full fresh pass on Rocky Linux 9.6 (PG 18.4 on
port 55432): PGDG packages + gcc/make from
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

## Validation performed 2026-08-10 (first real CI run - GitHub Actions)

The included CI workflow ran for the first time after the project was
uploaded to GitHub and failed in the Regression tests step with
`FATAL: cannot create PGC_POSTMASTER variables after startup`.
Root cause: `adaptive_autovacuum.control_database` was defined with
PGC_POSTMASTER context in `_PG_init()`, which also runs when the
library is loaded ON DEMAND by `CREATE EXTENSION` on a cluster without
`shared_preload_libraries` - exactly what the CI cluster (and any
user who skips the preload step) does; the backend dies. All previous
validation environments had the library preloaded, which masked this.

Fix: context changed to PGC_SIGHUP (the launcher reads the value when
it starts). Reproduced and verified on a fresh no-preload cluster
(initdb --no-locale, CREATE DATABASE contrib_regression, full test
file): before the fix the exact CI FATAL reproduced; after rebuilding,
the run is byte-identical to the expected file.

The CI workflow now runs installcheck twice: once with on-demand
loading (catches this class of bug) and once with the library
preloaded and the launcher registered (the real deployment shape).

## Validation performed 2026-08-11 (never-analyzed tables feature)

New feature: each cycle, tables with live rows but no analyze in their entire
history (no manual ANALYZE, no autoanalyze; system schemas, the extension's
own schema, and `table_policy.enabled = false` opt-outs excluded) are found
and the largest `analyze_missing_stats_per_cycle` of them (default 3, ordered
by `n_live_tup` descending) are analyzed one at a time. SQL-only change; the
C module is untouched.

Validated on Windows 11 against the EDB PostgreSQL 18.4 x64 binaries using a
scratch `initdb` cluster (port 5499) with the updated script served via the
PG18 `extension_control_path` GUC (note: entries are separated by `;` on
Windows, and the installed `$system` copy wins if listed first):

- Full `pg_regress`-equivalent run of `test/sql/adaptive_autovacuum.sql`
  (psql -X -a -q) is byte-identical to the expected file, including the new
  assertions: dry-run records `propose_analyze` without touching the table;
  live run records `analyze` with `applied = true`, `pg_class.reltuples`
  becomes accurate; a further cycle does not re-analyze (self-limiting via
  `last_analyze`).
- Top-3/ordering semantics with five never-analyzed tables (100/5000/300/
  20000/1000 rows): cycle 1 analyzed exactly t4, t2, t5 in that order
  (decision ids 1..3) while t1/t3 kept `reltuples = -1`; cycle 2 analyzed
  t3 then t1; cycle 3 was a no-op (decision count stayed 5).

Linux parity (same day, Rocky Linux 9.6,
PGDG PostgreSQL 18.4 on port 55432):

- Extension compiled from the same source (`make install with_llvm=no`).
- The full regression run is byte-identical to the expected file (after
  CRLF normalization).
- Top-3/ordering/drain semantics reproduced exactly (t4/t2/t5 then t3/t1,
  then no-op).
- Autonomous end-to-end with `shared_preload_libraries` set: after
  `ALTER SYSTEM SET adaptive_autovacuum.enabled = on` + reload, the launcher
  and database worker found and analyzed a never-analyzed 50,000-row table
  (`autovacuum_enabled = off` reloption) with no manual `_run_cycle` call;
  `reltuples` and `last_analyze` confirmed.

Not yet exercised for this feature: lock-timeout failure path (a concurrent
long transaction holding a conflicting lock) and behavior under real host
pressure; both paths are shared with existing code (`GET STACKED DIAGNOSTICS`
guard, `host_pressure` gate) but have not been provoked live.

## Validation performed 2026-08-11 (PostgreSQL 17 support)

The version floor was lowered from 18 to 17 (17 is the true floor: the code
reads the `*_dead_tuple_bytes` progress columns that appeared in 17). The C
module gates only the PG18 eager-freeze parameter; everything else is decided
at runtime in SQL from `server_version_num`:

- `pg_stat_progress_vacuum.delay_time` (new in 18) is read through a
  `to_jsonb(...) ->> 'delay_time'` detour in both `_run_cycle` queries and in
  the `active_vacuums` view, so one script parses on both majors; on 17 the
  value is NULL and delay-bound detection stays inactive.
- `autovacuum_vacuum_max_threshold` (GUC and reloption, new in 18): never
  recommended, queued, or set on 17; the trigger formula degrades to the
  classic uncapped one (NULL semantics verified).
- `autovacuum_max_workers` (PGC_POSTMASTER on 17): recommendation is still
  recorded with a "requires restart" note but never queued for ALTER SYSTEM;
  on 17 the recommendation is no longer capped by `autovacuum_worker_slots`
  (which does not exist there).

Validated on Windows 11 (EDB binaries), scratch clusters of both majors:

- PostgreSQL 17.6: `vacuum()`/`VacuumParams` compile cleanly; full regression
  run byte-identical to the same expected file used for 18; staged 3-table
  bloat scenario applied per-table reloptions WITHOUT the max_threshold key;
  the global queue contained no PG18-only GUCs; the live background worker
  applied cost_limit/cost_delay/vacuum_threshold/analyze_threshold via
  ALTER SYSTEM + reload on 17 and executed the never-analyzed ANALYZE
  autonomously.
- PostgreSQL 18.4 regression re-run after the changes: byte-identical, and a
  staged bloat scenario confirmed the max_threshold reloption is still
  proposed on 18.

Linux parity (same day, AlmaLinux 9 WSL, PGDG PostgreSQL 17.10 from
`postgresql17-devel`, gcc 11.5, CRB repo required for the devel package's
perl dependency):

- `make PG_CONFIG=/usr/pgsql-17/bin/pg_config with_llvm=no install` builds
  cleanly and a real `make installcheck` (pg_regress) passes.
- Top-3/largest-first ANALYZE semantics reproduced (never-analyzed
  30K/20K/5K-row tables picked in size order, one manual cycle).
- Autonomous end-to-end with the library preloaded: after enabling the GUC
  and reloading, the launcher's database worker drained the remaining three
  never-analyzed tables in one cycle with no manual `_run_cycle` call.

## Validation performed 2026-08-11 (comprehensive PG18 feature run, Linux lab)

Full-matrix run on the Rocky Linux 9.6, PGDG
PostgreSQL 18.4 on port 55432 (preloaded, `track_cost_delay_timing = on`,
5-second controller naptime, builtin autovacuum parked at naptime 3600s except
where staged), built from the current source including the two design changes
of the same day (no per-GUC cooldown; emergency vacuum enabled by default).
Product PG 17 untouched; environment fully removed afterwards. Every
assertion below ran against the live cluster and passed.

- **installcheck** (pg_regress) green; `host_metrics()` returned the real
  host (56 CPUs, 251 GB, live load average).
- **Per-table policy suite (21 assertions):** dry-run proposes without
  writing; live run applies trigger reloptions including the PG18
  `autovacuum_vacuum_max_threshold`; cost boosts capped at
  `max_boosted_relations = 2` and within the cluster budget; insert-only
  table got insert reloptions only; `table_policy` per-table target produced
  a tighter threshold and `enabled = false` kept the opt-out table invisible;
  synthetic host pressure blocked new boosts and switched the recommendation
  to "reduce"; a manual reloption edit flagged `ownership_conflict`, froze
  automation, and the documented hand-back query resumed it; after `VACUUM`
  and six healthy cycles the original reloptions
  (`fillfactor=90, autovacuum_vacuum_threshold=123`) were restored exactly.
- **Global GUC suite (12 assertions):** mistuned-baseline detectors (dead and
  insert side) fired; queue deduplicates while pending; the worker applied
  changes via `ALTER SYSTEM` + reload with `old_value` audit;
  `autovacuum_vacuum_threshold` 50→500, `autovacuum_analyze_threshold`
  50→250, fleet-derived `autovacuum_vacuum_max_threshold` applied. The
  cooldown removal was proven live: cost limit ramped
  **400→800→1600→3200→6400→10000 in consecutive 5-second cycles** (under the
  removed 10-minute per-GUC cap this ramp would have taken ~50 minutes).
- **Never-analyzed suite:** dry-run proposes 3 without touching stats; live
  run analyzed the top-3 largest first (t4 20000, t2 5000, t5 1000); the
  autonomous worker drained the remaining two; self-limiting confirmed
  (exactly 5 analyze decisions total).
- **Emergency suite:** default-on confirmed; 120,000 XIDs burned via pgbench
  (5.3K TPS); below the stall line the table stayed a passive
  `wraparound_warning` with an empty emergency queue; lowering
  `emergency_xid_age` to 100,000 made never-started fire and the worker froze
  victim1 (age 120,020 → <5,000) while the opted-out victim2 was untouched; a
  builtin anti-wraparound autovacuum staged to grind (cost_limit 50, 1M
  updated rows) was respected while running (`vacuum_already_running`), the
  delay-bound recommendation fired from `pg_stat_progress_vacuum.delay_time`
  (exercising the PG17-compat `to_jsonb` read path on 18), and past the
  60-second takeover minimum the controller cancelled the builtin
  ("canceling autovacuum task" logged once) and froze the 1M-row table;
  `wraparound_status` stayed consistent throughout.
- **Multi-DB + barrier:** with three managed databases the worker cycled all
  of them within one naptime; `CREATE DATABASE` 83 ms / `DROP DATABASE`
  149 ms while the launcher was running.

## Validation performed 2026-08-13 (parameter-bounds hardening)

Guards against absurd tuning values, validated on the Windows workstation
(EDB PG 18.4 live service on 5432 + scratch initdb PG 17.6 on 5433):

- **Policy CHECK upper bounds:** every knob that feeds a bounded server
  setting is now capped at that setting's documented maximum - cost limits
  <= 10000, cost delays <= 100 ms, scale factors <= 100, work_mem MB values
  <= 2097151 (the kilobyte-conversion overflow line).  Cross-column CHECKs
  the regression suite exercises carry explicit constraint names.  Seven
  negative tests added to the regression script; suite green via real
  `pg_regress` on 18.4 and 17.6 with one shared expected file.
- **Queue-time bounds validation:** the global-apply INSERT now requires the
  desired value to fall inside the GUC's own `pg_settings` min/max, so a
  mistuned policy cannot enqueue a change ALTER SYSTEM would reject.
- **Per-row apply isolation (C):** each queue row is applied inside an
  internal subtransaction; a rejected value is marked `failed` with the
  server's own error and a WARNING, and later rows still apply.  Proven live
  on the preloaded 18.4 worker: queued out-of-range `cost_limit=50000`
  (failed: "outside the valid range ... (-1 .. 10000)"), valid
  `cost_delay=3` (applied, old value audited), non-whitelisted
  `autovacuum_naptime` (failed: whitelist) - all in one cycle, worker alive.
  Previously one bad row aborted the whole apply transaction and was retried
  every cycle until the one-hour queue expiry.
- **Cost-delay floor:** new `recommendation_delay_min_ms` (default 0.5,
  CHECK 0..recommendation_delay_max_ms) stops the automatic halving above
  zero; an operator-set delay already below the floor is respected, never
  raised (formula verified for current values 2, 1, 0.6, 0.5, 0.2, 0, -1).
  Deliberate 0-delay profiles (critical boost tier, emergency failsafe) are
  unchanged.
- **Worker-slots cross-GUC guard (C):** `autovacuum_max_workers` above
  `autovacuum_worker_slots` is accepted by the server (runtime warning +
  cap), so neither the generic bounds checks nor ALTER SYSTEM rejection
  catches it; the applier now fails such rows explicitly.  Covers queued
  rows outliving a restart that lowered the slot count (postmaster-context
  GUC) and manual queue inserts; inert on PG17 (no slots GUC).  Proven live
  on the 18.4 worker with `autovacuum_worker_slots=16`: queued `20` failed
  ("exceeds autovacuum_worker_slots (16)"), boundary `16` applied in the
  same cycle, then restored.
- Compiled clean against PG 18.4 and 17.6 headers (MSVC); PG17 tree's DLL and
  script redeployed; all live-cluster test state restored afterwards
  (autovacuum_vacuum_cost_delay RESET, worker disabled, scratch DBs dropped).

## Validation performed 2026-08-13 (opportunistic memory sizing)

New managed setting `vacuum_buffer_usage_limit` (PG16+, present on both
supported majors) plus an opportunistic raise for `autovacuum_work_mem`,
validated on the Windows workstation (EDB PG 18.4 live service + scratch
initdb PG 17.6):

- **Design:** both are sized only while autovacuum workers are actually
  running and the host has free memory; an idle cluster is never retuned.
  The buffer ring is at most doubled per cycle, capped by the new policy
  knob `recommendation_buffer_usage_limit_max_mb` (default 256, CHECK
  2..16384 = the GUC's 16 GB maximum) AND by the server's silent
  1/8-of-shared_buffers clamp divided across the worker pool; halved back
  toward the built-in default under host pressure; an operator setting of 0
  ("no ring limit") is never touched.  `autovacuum_work_mem` keeps its
  repeated-index-pass evidence trigger and additionally ratchets toward the
  free-memory-derived value while workers run; never lowered without host
  pressure.
- **Live E2E (18.4):** staged a grinding autovacuum (400K-row table,
  per-table cost_limit=50/delay=20), ran a cycle with 8 GB free metrics:
  queue got `vacuum_buffer_usage_limit` 2048 -> 4096 kB - exactly the
  predicted first doubling under the derived cap
  LEAST(256 MB, 1 GB shared_buffers / 8 / 3 workers) = 43690 kB - and the C
  worker applied it through the extended whitelist (old value audited,
  `SHOW` = 4MB).  `autovacuum_work_mem` correctly queued NOTHING: the
  effective value (1 GB via maintenance_work_mem) already exceeded the
  memory-derived 273 MB and the raise never lowers.  All settings RESET and
  verified back at defaults afterwards.
- **Regression:** new-knob default + CHECK-violation tests added; suite
  green via real `pg_regress` on 18.4 and scratch 17.6 with one shared
  expected file (also proving the GUC surface parses on 17).
- Not yet exercised: a raise chain past the first doubling on a live busy
  cluster, and the host-pressure walk-back of the ring (code path mirrors
  the proven cost walk-back).

## Validation performed 2026-08-14 (review round 2: orchestration, standby, identity, storage guardrail)

Changes from the second external review, with minimal-change scope:

- **Designated global-settings database** (`adaptive_autovacuum.global_settings_database`,
  empty = legacy all-databases behavior): the SQL policy skips queueing and
  the C worker skips applying outside the designated database.
- **Bounded launcher concurrency** (`adaptive_autovacuum.max_database_workers`,
  default 1 = the historical serial scan): slot scheduler in the launcher so
  one slow database cannot starve the checks of the databases behind it.
- **Explicit standby guard**: `RecoveryInProgress()` check in the launcher
  loop (defense in depth on top of `BgWorkerStart_RecoveryFinished`).
- **table_policy identity fingerprint** (schema/name columns filled by
  trigger): mismatched rows are ignored until re-adopted; rows for dropped
  relations are removed each cycle (OID-reuse protection).
- **WAL-rate storage guardrail** (`policy.high_wal_mbps`, 0 = off):
  `pg_stat_wal.wal_bytes` delta sampled per cycle into `controller_state`;
  above the threshold the cycle runs as host pressure.
- `host_metrics()` EXECUTE moved from PUBLIC to `pg_monitor`; CI converted to
  a `postgres:[17, 18]` matrix; checked-in Windows build artifacts removed
  and `.gitignore` added; buffer-ring wording corrected; naptime semantics
  documented precisely.

Validated the same day on three environments:

- **Windows 11, EDB PG 18.4 (live service)**: MSVC builds clean against 18.4
  and 17.6 headers. Identity drill (fill -> rename ignored -> re-adopt ->
  dropped-relation cleanup). Guardrail + designation drill: storage_pressure
  fired from a real WAL-rate sample, designated DB queued 2 rows, the
  non-designated DB queued 0, its manual decoy row stayed pending while the
  designated DB applied with old-value audit. Concurrency drill with a 35 s
  ACCESS EXCLUSIVE lock on one database's policy table: serial mode stalled
  the second database for the whole lock (log-verified); with
  max_database_workers=2 the second database completed mid-lock (22:41:59)
  while the locked one finished only at lock release (22:42:25).
- **WSL AlmaLinux 9**: `make installcheck` green twice (no-preload +
  preloaded) on PGDG 18.6 AND 17.11, including the new regression assertions
  (identity fill/re-adopt/cleanup, high_wal_mbps default). Hot-standby drill
  on 18.6 (pg_basebackup + standby.signal): with the library preloaded and
  the GUC on, ZERO adaptive backends during recovery; after promotion the
  launcher appeared in pg_stat_activity; no errors.
- **QA lab (Rocky 9.6, PGDG PG 18.6 scratch cluster on port 55432; el9 .so
  built on WSL)**: pg_regress green; all drills reproduced (identity,
  guardrail 0.075 MB/s sample + designation 4-vs-0 queue rows, serial stall
  4->4 vs concurrent advance 6->7 under lock, decoy stayed pending,
  pg_monitor grant enforced); emergency lifecycle regression-checked
  end-to-end through the new scheduler (age 160,003 -> queued -> dedicated
  worker completed -> age 5). 120 s pgbench soak at 19,984 TPS (0 failed,
  0.4 ms latency) with high_wal_mbps=3: the guardrail measured up to
  273 MB/s, flagged 12 pressured cycles, and the controller walked
  aggression DOWN in cooldown-spaced steps (cost_limit 7500 -> 1000 in 0.75x
  steps, delay 2 -> 20 ms in 1.5x steps capped at the policy max, buffer
  ring walked back), then reversed direction after the load stopped;
  0 relation errors; collector-log scan showed only intentional regression
  errors and administrator-command shutdowns. Product PG 17.10 instance
  verified untouched.

Not yet exercised: the hosted GitHub Actions matrix run (see CI status at the
top), and max_database_workers > 2.

## Validation performed 2026-08-15 (major review round 3: takeover safety, cluster aggregation)

Changes from the 2026-08-15 major-issues review:

- **Takeover requires observed stall, never age or ETA** (the review's top
  issue: relfrozenxid only advances at the END of a vacuum, so a rising age
  is guaranteed for any long healthy vacuum and must never justify
  cancelling it). Each cycle stores a progress fingerprint per relation
  (phase, heap_blks_scanned/vacuumed, indexes_processed, index_vacuum_count,
  dead_tuple_bytes - every pg_stat_progress_vacuum counter that moves in any
  phase) keyed to the vacuum PID in relation_state. Takeover now requires
  minimum runtime AND age past the stall line AND an unchanged fingerprint
  for emergency_takeover_stall_samples consecutive samples (new knob,
  default 5, CHECK >= 2). The heap-scan ETA branch was removed from the
  cancellation decision (it mispredicts index-dominated vacuums), and the
  safety scan no longer cancels anything (it has no per-relation state, so
  stall evidence cannot exist there; never-started escalation only).
- **True cluster-level aggregation for global GUCs**: after every cycle each
  database worker publishes a summary (eligible/overdue/dead-overdue/
  insert-overdue counts, fleet ceiling target, trigger-setting medians) into
  a 64-slot shared-memory array; before each cycle the worker hands the
  aggregate of the OTHER databases' fresh slots (10-naptime staleness
  window) to _run_cycle as jsonb. The mistuned-baseline detectors, worker
  recommendation, and overdue cost branch run on the merged values; medians
  merge as overdue-count-weighted averages; the reason text states the
  cluster evidence. global_settings_database remains the single-applier
  control.
- **PG17 version-specific regression assertions** (the CI matrix itself was
  added 2026-08-14): the suite now asserts that autovacuum_vacuum_max_threshold
  is recommended and queued on 18 but neither recommended nor queued on 17,
  from the same shared expected file.

Validated the same day on Windows and Linux localhost :

- **Windows 11, EDB PG 18.4 (live service)**: MSVC builds clean vs 18.4 and
  17.6 headers. Full regression file byte-identical (modulo psql -f line
  prefixes). Aggregation end-to-end through real background workers and
  shared memory: a database with six staged overdue tables and an EMPTY
  database both produced cluster recommendations carrying "Cluster-wide
  evidence: 2 databases, 6 eligible relations, 6 overdue"; the empty
  database recommended the busy database's weighted medians (scale ~0.2,
  threshold 500), its fleet ceiling (5000), and workers 6 - the exact
  db2-develops-debt scenario from the review. Takeover NEGATIVE drill: a
  grinding anti-wraparound autovacuum (cost_limit=1/delay=100 reloptions,
  age 160,003 past the 150,000 stall line, runtime 113 s past the 60 s
  minimum - conditions under which the previous logic cancelled) was left
  alone: stalled_cycles stayed 0, decisions showed only
  vacuum_already_running, zero takeover decisions, empty queue, same pid
  still vacuuming.
- **WSL AlmaLinux 9**: make installcheck green twice (no-preload +
  preloaded) on PGDG 18.6 AND 17.11 - the PG17 leg exercising the new
  version-gate assertions on a real 17 server. Takeover POSITIVE drill on
  18.6: the same grinding autovacuum was first observed moving for several
  controller samples (stalled_cycles 0, no takeover), then SIGSTOPped;
  stalled_cycles climbed and exactly ONE queue_emergency_takeover fired at
  the 3rd consecutive frozen sample ("zero observable progress for 3
  consecutive checks", runtime 108 s), pg_cancel_backend was issued, and
  after the stopped worker exited the emergency vacuum completed (age
  160,041 -> 5). The first emergency attempt correctly failed on its lock
  timeout while the cancelled worker still held the lock and was retried
  via the queue - the designed backoff path, observed live.

Follow-up the same day: `adaptive_autovacuum.max_database_workers` default
raised from 1 to 2. Emergency vacuums already run outside the scheduler
slots, but the in-cycle ANALYZE of a large never-analyzed table can still
make one database's cycle slow, and with the serial default that delayed
every other database's wraparound checks; 2 is also the configuration the
concurrency drills validated. 1 remains available for a strictly serial
scan.

Not yet exercised: the hosted CI matrix run on GitHub Actions, aggregation
with more than two databases, and a lab-scale soak of the new takeover
logic.

## Validation performed 2026-09-12 (controller write amplification)

Change under test: the performance review's two structural findings. The
previous relation state is now LEFT JOINed into the candidate query (no
per-relation `relation_state` lookup inside the loop), a `relation_state`
row exists only for relations with something to remember and is rewritten
only when a control field changes (hourly heartbeat otherwise; hysteresis
counters saturate at their thresholds), `decisions` became a transition log
(one row per (state, action) episode, every applied or failed change, and a
`recovered` row when a relation returns to normal), and the two pure history
tables `decisions` and `global_recommendations` are UNLOGGED. All control
tables stay logged.

- `pg_regress` green on Windows PG 18.4 (isolated scratch instance via
  `extension_control_path`), and via `make installcheck` on WSL AlmaLinux 9
  against PGDG 17.11 and 18.6, each twice (loaded on demand, preloaded). The
  regression suite gained a scenario asserting: no row and no decision for a
  healthy unmanaged table; exactly one insert, one update and one delete of
  the overdue table's row across four cycles (`pg_stat_all_tables`
  counters); one decision for the overdue episode plus one `recovered`
  decision; `decisions`/`global_recommendations` unlogged, the six control
  tables permanent.
- Old (previous commit) vs new script on the same WSL PG 18.6 instance,
  3,000 small tables of which 100 overdue, dry run, five cycles, measured
  per cycle with `pg_wal_lsn_diff` and `pg_stat_all_tables`:

  | | old, steady state | new, steady state |
  |---|---|---|
  | `relation_state` rows | 3,000 | 100 |
  | `relation_state` writes per cycle | 3,000 updates | 0 (100 inserts once, 100 updates once) |
  | `decisions` rows per cycle | 100 | 0 after the first cycle (100 total) |
  | WAL per cycle | ~1.26 MB | 0 KB (155 KB first cycle, 40 KB second) |
  | cycle wall time | ~190 ms | ~155 ms |

- Regression gotcha found while writing the new scenario: insert counters
  pending in the backend must be flushed (`pg_stat_force_next_flush()`)
  BEFORE the `VACUUM` that is supposed to reset them, otherwise they land on
  top of the vacuum's report and the table looks insert-overdue.

Not yet exercised: the hosted CI run for this revision, and a lab-scale run
with tens of thousands of relations (the benchmark above is a
proportionality check, not a scale test).

## Validation performed 2026-09-12 (review: summary slots, catalog scan cost, size fallback)

Changes under test: (1) the per-database summary slot array is sized by the
new postmaster GUC `adaptive_autovacuum.max_tracked_databases` (default
256); only stale slots are reused, an overflow drops the summary, warns
once, is reported by `cluster_summary_status()` and flips
`evidence_complete` to false in the aggregate, which makes cluster-wide
changes record-only; (2) the candidate query parses reloptions once per
relation in a LATERAL instead of ~17 `_option_value()` calls, the loop only
receives relations that can be non-normal (pressure at half the elevated
ratio, age at half the warning ratio, a state row, or a running vacuum)
while the fleet count and largest target come from one aggregate query, and
the relation jsonb is built only when a decision can be written; (3) the
exact `pg_total_relation_size()` fallback runs only for never-analyzed
relations whose tuple statistics reach `min_table_bytes / block_size`
(`_relation_bytes()`, confirmed inlined by EXPLAIN VERBOSE).

- `make installcheck` green on WSL AlmaLinux 9 against PGDG 17.11 and 18.6,
  twice each (on demand and preloaded), with two new checks: the status
  function returns a sane row with and without shared memory, and the size
  estimate picks relpages, zero, or the exact size as specified. The DLL
  builds with MSVC 2022 against PG 18.4 on Windows.
- Scale benchmark on WSL PG 18.6 (24 CPU, 4 GB shared_buffers): one
  database with 100,000 small tables (1,000 of them overdue) and one with
  20,000 never-analyzed tables, dry run, three cycles each, steady-state
  wall time per cycle before and after this revision:

  | scenario | before | after |
  |---|---|---|
  | 100,000 tables, `min_table_bytes = 0` (every table eligible, 1,000 overdue) | 5.3 s | 1.7 s |
  | 100,000 tables, default `min_table_bytes` (64 MB, all filtered by size) | 0.58 s | 0.57 s |
  | 20,000 never-analyzed tables, default `min_table_bytes` | 0.65 s | 0.15 s |

  The default-filter case is bounded by the catalog scans themselves (three
  passes over a 300,000-row `pg_class` including TOAST relations), which is
  the same order of work core's autovacuum launcher does per naptime. The
  eligible-everything case was dominated by per-relation `_option_value()`
  calls and the loop body for healthy relations; both are gone.
- Not exercised: an overflow drill with more than 256 managed databases
  (the eviction and record-only paths are covered by code review and the
  status function only), and the hosted CI run for this revision.

## Validation performed 2026-09-12 (maintenance-capacity control)

Changes under test: (1) the cluster cost controller keys on maintenance-debt
velocity (dead + inserted-since-vacuum tuples, sampled per cycle, EMA-smoothed,
merged across databases): growing/flat/unknown raises as before, shrinking
holds, and ten consecutive backlog-free checks step the cost settings halfway
back toward the operator baseline kept in `controller_state`; (2) `autovacuum
= off` is repaired (queued as `autovacuum = on`, the only value the C applier
accepts for that GUC) after `repair_disabled_autovacuum_cycles` consecutive
checks, default on; (3) the worker recommendation fires on a saturated pool
with non-shrinking debt, doubles at most per step, and is capped by CPU
count, free memory / `autovacuum_work_mem`, `autovacuum_worker_slots` and
`recommendation_workers_max` (now 16), with host pressure as a gate except
under `wraparound_critical`; (4) emergency requests carry a projected
seconds-to-read-only deadline and are claimed deadline-first, and the launcher
sweeps databases oldest-age-first; (5) never-analyzed remediation runs on a
time budget (`analyze_missing_stats_budget_ms`, default 10 s, a quarter under
moderate host load, none under pressure) instead of three tables per cycle,
and dry run proposes each table once.

- `make installcheck` green on WSL AlmaLinux 9 against PGDG 17.11 and 18.6,
  twice each (on demand and preloaded), and on Windows against PG 18.4 in a
  scratch instance, twice (on demand and preloaded), with the MSVC 2022 DLL.
  New checks: a synthetic previous sample makes the same overdue backlog read
  as growing (cost limit doubled, trend and velocity recorded) and then as
  shrinking (cost limit held, reason says so); a backlog-free cycle at the
  decay threshold recommends exactly half the distance back to an injected
  baseline for both cost limit and delay and resets the counter; a dry-run
  never-analyzed proposal is not repeated on the next check; policy and
  controller-state defaults.
- Live drill on the Windows scratch instance (preloaded, `naptime_seconds =
  5`, `autovacuum = off` in `postgresql.auto.conf`, `dry_run = false`,
  `repair_disabled_autovacuum_cycles = 2`): the first check recorded
  "off for 1 of the 2 consecutive checks required", the second queued the
  repair, the C applier logged `set autovacuum = on cluster-wide (was off)`,
  the queue row shows `on` / old value `off` / `applied`, and `SHOW
  autovacuum` returned `on` after the reload.
- Cost of the new debt sums (two more per-relation statistics lookups in the
  existing aggregate pass): the 100,000-table benchmark from the previous
  section, re-run on the same WSL PG 18.6 instance, is unchanged within noise:
  1.65 s (was 1.7 s) with every table eligible, 0.59 s (was 0.57 s) with the
  default size filter, 0.15-0.19 s (was 0.15 s) for 20,000 never-analyzed
  tables, steady state, dry run.
- Not exercised: a live worker-count raise (needs a saturated worker pool
  under load) and a live deadline-ordered emergency pair; both paths are
  covered by the regression checks on the recorded recommendation and by
  code review of the claim query. The hosted CI run for this revision is
  pending.

## Validation performed 2026-09-13 (worker capacity: no CPU ceiling, queue pressure, active defaults)

Changes under test: (1) the worker recommendation is no longer capped at one
worker per CPU; the CPU count acts only through the load-per-CPU pressure
gate, while free memory / `autovacuum_work_mem`, `autovacuum_worker_slots`,
`recommendation_workers_max`, bounded doubling and the host-pressure gate stay;
(2) saturation is also inferred from the queue: an overdue count of at least
`2 × workers` and `workers + 2` counts like a fully busy pool, because one
`pg_stat_activity` sample per cycle misses workers that start and finish
between samples; (3) a fresh `CREATE EXTENSION` is active (`enabled = true`,
`dry_run = false`, `manage_global_settings = true`); the cluster switch
`adaptive_autovacuum.enabled` is unchanged (off). No C change; the shared
memory layout is unchanged.

- `make installcheck` green on WSL AlmaLinux 9 against PGDG 17.11 and 18.6,
  twice each (on demand and preloaded), and on Windows against PG 18.4 in a
  scratch instance, twice. New checks (eight overdue tables, a pool of three,
  `host_cpu_count = 1`, synthetic growing debt): the recommendation is six
  workers, above the CPU count, with the reason naming the raise; load 10 on
  that one CPU holds the pool; a free-memory figure worth 1.5 extra workers
  yields exactly one extra; `recommendation_workers_max = 4` caps at four; a
  shrinking debt holds the pool under the same queue pressure; the policy
  defaults read `enabled = true`, `dry_run = false`.
- Live drill on WSL PG 18.6 (24 CPUs, 31 GB), replaying the Ubuntu method
  from `aavtest.sql`: preloaded, `naptime_seconds = 10`, `ALTER SYSTEM`
  `autovacuum_max_workers = 1`, `autovacuum_vacuum_cost_limit = 10`,
  `autovacuum_vacuum_cost_delay = 100ms`; `CREATE EXTENSION` with no policy
  update (the row came up `t|f|t`); 100 tables of 100,000 rows (20 MB each,
  `autovacuum_vacuum_threshold = 1000`, scale factor 0); pgbench 16 clients,
  8 threads, 200 s of single-row updates (405,464 transactions, 0 failed).
  `min_table_bytes` was lowered to 8 MB because the Ubuntu tables are below
  the 64 MB default filter and would otherwise not count as overdue.
  Timeline (check every 10 s): 23:44:23 100 overdue, debt growing, queue rows
  `autovacuum_max_workers 1 → 2`, `cost_limit 10 → 200`, `cost_delay 100 →
  50` applied; 23:44:43 workers 4; 23:45:03 workers 8; 23:45:24 workers 12;
  23:45:46 workers 16, cost limit 3200. At every one of those instants
  `pg_stat_activity` showed exactly one autovacuum worker running (core's
  launcher starts one per naptime), so the old all-workers-busy rule would
  have stopped at 2; the queue-pressure rule carried the ramp. From 23:45:34
  the debt read shrinking and the pool held at 12, then 16, while the cost
  loop kept stepping until the backlog cleared (overdue 0 at 23:46:34, debt
  10 M → 56 K tuples). After the load stopped `autovacuum_max_workers` stayed
  at 16 and the cost settings at 10000 / 0.78 ms (no automatic lowering by
  design; the decay needs ten clean checks). 28 queue rows, all `applied`,
  old values recorded; 0 error lines in the server log.
- Not shown live: a recommendation above the CPU count (the WSL host has 24
  CPUs and the ramp stopped at the 16-slot PG18 default); that case is the
  regression check with `host_cpu_count = 1`. A manual `_run_cycle` with
  `host_cpu_count = 2` during the drill landed on a shrinking sample and
  correctly held at 12. `autovacuum_worker_slots` as a ceiling is not
  exercised (restart GUC). The hosted CI run for this revision is pending.
- Side observation, unchanged behaviour: the opportunistic memory sizing set
  `autovacuum_work_mem` to about 3 GB on this 31 GB host at the first check.

## Validation performed 2026-09-14 (cost-raise brakes: throughput cap, observed-I/O feedback)

Superseded in part by the next section (drain-time target and feedback timing); the cap and feedback checks below still apply.

Motivation: in the 2026-09-13 drill the cost controller doubled `cost_limit`
and halved `cost_delay` on every check, a 4x throughput step, and reached
10000 / 0.78 ms (a theoretical 102 GB/s by (1000 / delay) x (limit /
page_hit) x block size) in seven checks with no I/O signal in the loop.
Changes under test: (1) `recommendation_max_vacuum_mbps` (default 3200
MiB/s, about four times the 781 MiB/s of the PostgreSQL defaults) caps
automatic raises; the delay is kept and only the limit raise that fits at the
current delay is taken; (2) each applied raise is recorded with the
autovacuum-worker throughput (`pg_stat_io`, reads + writes + extends + hits)
measured before it, and the next raise is allowed only after a full
post-raise sample interval and a gain of `cost_raise_min_io_gain_percent`
(default 10); otherwise the controller holds and says why. New helper
`vacuum_cost_ceiling_mbps()`, new columns `global_recommendations
.autovacuum_io_mbps` / `.cost_ceiling_mbps`. SQL and tests only.

- `make installcheck` green on WSL AlmaLinux 9 against PGDG 17.11 and 18.6,
  twice each, and on Windows PG 18.4, twice. New checks: `vacuum_cost_ceiling
  _mbps(200, 2) = 781.25` and delay 0 = infinity; cap 1600 from 200 / 2 ms
  keeps the delay and raises the limit to 400 (1562.5 MiB/s); cap 780 holds
  the pair with the reason "is held"; a recorded raise matching the live pair
  with a huge pre-raise rate holds with "did not increase observed autovacuum
  throughput"; a raise younger than the previous sample holds with "not yet
  been observed over a full check interval"; a measurable gain over a zero
  pre-raise rate allows the raise; a record whose pair differs from the live
  settings is ignored.
- Live drill on WSL PG 18.6 (24 CPUs, 31 GB), identical to the 2026-09-13
  one (preloaded, `naptime_seconds = 10`, `autovacuum_max_workers = 1`,
  `cost_limit = 10`, `cost_delay = 100ms`, 100 tables of 100,000 rows,
  `min_table_bytes = 8 MB`, pgbench 16 clients / 8 threads / 240 s, 563,840
  transactions, 0 failed). Cost pair timeline (checks every 10 s, observed
  autovacuum MB/s in brackets): 00:22:27 raise to 200 / 50 ms [0.0];
  00:22:37 hold, "has not yet been observed over a full check interval";
  00:22:47 raise to 400 / 25 ms [1.0 > 0.0]; 00:22:57 hold, awaiting the
  interval; 00:23:07 raise to 800 / 12.5 ms [21.3 > 1.0 x 1.1]; 00:23:17
  hold, awaiting; 00:23:28 onward debt shrinking, pair held at 800 / 12.5 ms
  (ceiling 500 MiB/s) while observed throughput ran at 50 to 70 MB/s and the
  overdue count fell 82 -> 0 by 00:26:49. The worker pool rose 1 -> 2 -> 4 ->
  8 -> 12 on the same checks and held when the debt turned shrinking. After
  the load stopped nothing was lowered. Previous run for comparison: cost
  limit 3200 at 00:45:46 and 10000 / 0.78 ms at 00:47:37 with the backlog
  clearing in about the same time (overdue 0 at 00:46:34 vs 00:26:49 now,
  from load start 00:44:23 vs 00:22:27: 2 min 11 s vs 4 min 22 s), i.e. the
  extra 12x to 200x of cost budget bought about two minutes on a cached 2 GB
  data set.
- The throughput cap was not reached live: the feedback delay plus the
  shrinking-debt hold stopped the ramp at 500 MiB/s. The cap is exercised by
  the regression checks.
- Server log in the drill window: 16 ERROR lines, all the regression suite's
  intentional CHECK-constraint rejections at 00:22:05-06 before the drill
  started, plus the two expected "terminating background worker" FATAL
  lines at the two shutdowns. No errors from the drill itself.
- Limitation noted for the record: autovacuum workers flush `pg_stat_io`
  between tables, so one very long vacuum can make an interval read low and
  hold a raise one check longer; a hold never lowers anything.

## Validation performed 2026-09-14 (drain-time target, feedback timing, record fixes)

Follow-up to the previous section: the operator asked for the backlog to
come under control in about three minutes instead of four and a half. The
recorded series showed why it took longer: from the first "shrinking" check
the projected drain (debt / shrink rate) was 189 s and stayed at 120-180 s
for a minute, yet "shrinking" alone meant hold. Changes: (1)
`max_backlog_drain_seconds` (default 180): a shrinking backlog holds the
cost and worker raises only when projected to clear within the target;
otherwise it is stepped up (cap and feedback still apply) and the reason
says "would take about N s to clear"; (2) feedback timing: the post-raise
interval is recognised from the queue row's `applied_at` (the raise must
fall within the first tenth of the interval), so a raise is judged on the
next check, not one check later; (3) two record fixes found by the drill:
a pair still waiting in the apply queue keeps its first record (the second
drill of the day sat at 400 / 25 ms for four minutes with "has not yet been
observed" because the record was rewritten every check while the C-side
once-per-two-naptimes rule delayed the apply, and the applied row was then
never matched), the applied row is matched by value, and a backlog-free
check clears the record (the third drill held once against a quiet
interval, "59.5 MB/s before, 0.1 MB/s after", when a new small backlog
appeared three minutes after the previous one had cleared).

- `make installcheck` green on WSL AlmaLinux 9 against PGDG 17.11 and 18.6,
  twice each, and on Windows PG 18.4, twice. New checks: a debt shrinking
  10 % per 60 s check (600 s projected drain) still doubles the cost limit
  with the "would take about ... (max_backlog_drain_seconds = 180)" reason;
  the fast-shrinking hold now reports "clear in about N s"; a raise applied
  one second into a 60 s interval is judged on that interval ("did not
  increase observed autovacuum throughput") instead of awaiting another; the
  backlog-free decay check leaves the raise record cleared; policy default.
- Live drill on WSL PG 18.6, same setup as the previous sections (24 CPUs,
  `naptime_seconds = 10`, `autovacuum_max_workers = 1`, `cost_limit = 10`,
  `cost_delay = 100ms`, 100 tables of 100,000 rows, pgbench 16 clients for
  240 s, 420,676 transactions, 0 failed). Load started 00:48:04. Cost pair
  and observed autovacuum MB/s per check: 00:48:04 200 / 50 [0.0]; 00:48:14
  400 / 25 queued [3.0], applied 00:48:25 (C-side apply spacing); 00:48:35
  800 / 12.5 [17.1 > 1.0 x 1.1]; 00:48:55 1600 / 6.25 [59.5 > 20.5 x 1.1],
  ceiling 2000 MiB/s; 00:49:16 onward shrinking with projected drain within
  180 s: held. Observed throughput 133-173 MB/s at 1600 / 6.25 ms (versus
  50-70 MB/s at 800 / 12.5 ms in the previous drill: the raise did buy
  throughput, and the feedback saw it). Overdue 100 -> 65 -> 48 -> 31 -> 17
  -> 3 -> 0 at 00:50:09, i.e. 2 min 5 s after load start (previous drill
  4 min 22 s; unbraked 2 min 11 s ending at 10000 / 0.78 ms). Workers rose
  1 -> 2 -> 4 -> 8 -> 12 on the same checks and held. A second small backlog
  (12 tables at 00:51:50) was raised once to the cap: 2560 / 6.25 ms = 3200
  MiB/s exactly, reason "Throughput cap 3200 MB/s ... the delay stays at
  6.25 ms and cost_limit goes to 2560"; the record-clearing fix (3) was
  applied after this run and is covered by the regression check. Nothing
  lowered after the load stopped. Server log in the drill window: only the
  two expected "terminating background worker" lines at the shutdowns.

## Required release gate

For each supported PostgreSQL major version:

1. Compile with that major's server development package.
2. Run `make installcheck`.
3. Test with assertions enabled.
4. Exercise launcher restart, worker timeout, SIGTERM during VACUUM, stale queue recovery, ownership conflict, cgroup memory limits, and active anti-wraparound autovacuum.
5. Run sustained workload tests before enabling non-dry-run actions.

## Validation performed 2026-09-19 (1.1.0 operator API and Tier 1 installer)

Extension: version bumped to 1.1.0 with `adaptive_autovacuum--1.1.0.sql` (full) and `adaptive_autovacuum--1.0.0--1.1.0.sql`
(upgrade: `doctor()`, `status()`, `enable_default_policy()`, `_preload_lists_library()`, `_version_key()`; no table changes).
New regression test `upgrade`: `CREATE EXTENSION VERSION '1.0.0'`, operator edits and history rows, `ALTER EXTENSION UPDATE`,
values preserved, 15 doctor rows, `enable_default_policy()` flips and is idempotent, `pg_monitor` can read but not enable.
Main test gained doctor/status/preload-parser asserts that hold in both passes.

- Regression: green on WSL AlmaLinux 9 PGDG 17.11 and 18.6 (two passes each: on-demand load, preloaded) and on
  Windows PostgreSQL 18.4 scratch instance (two passes). Two fixes found by the run: `extract(epoch ...)` is numeric
  (cast to double precision), and `current_setting('adaptive_autovacuum.naptime_seconds')` returns `1min` (read
  `pg_settings.setting` instead).

Linux helper `packaging/linux/adaptive-autovacuum-setup` + `install.sh`, on WSL AlmaLinux 9.8 (systemd running, PGDG
`postgresql-18.service` on 5432 and `postgresql-17.service` on 5433, both initialised for this test):

- Discovery merged systemd and process evidence per data directory, read port/socket from `postmaster.pid`, verified facts
  over the socket as `postgres`, flagged PG17 as unsupported and auto-selected PG18. `--pg-major 17` and `--port 5433` exit 3;
  bad arguments exit 2; `check --json` is valid JSON.
- `install --database postgres --yes`: preload `'' -> 'adaptive_autovacuum'` via `ALTER SYSTEM` with a psql variable
  (a `-c` command does not interpolate `:'v'`; the statement goes through stdin), restart, `CREATE EXTENSION`,
  `adaptive_autovacuum.enabled = on`, `track_cost_delay_timing = on`, 15/15 doctor rows OK. `--no-restart` leaves state
  `restart_required`; the rerun recognises the pending file value and resumes at the restart. Rerun after success:
  no preload change, no restart, exit 0. `disable`/`enable` toggle the GUC. PG17 untouched (empty preload, no extension).
- Forced failure: a broken `.so` made the restart fail (`file too short`); the helper printed the log excerpt, restored the
  backed-up `postgresql.auto.conf` after checking its hash, restarted, exited 8, journal `rolled_back`.
- PostgreSQL behaviour found and handled: `ALTER SYSTEM SET shared_preload_libraries = ''` writes `'""'` and the server
  then fails with `could not access file ""`; an empty list is now `ALTER SYSTEM RESET` (with a check that the main
  configuration file does not still list the library).
- RPM `postgresql18-adaptive-autovacuum-1.1.0-1.el9.x86_64.rpm` built with `rpmbuild` from the working tree, installed with
  `dnf install ./...` through `install.sh --manifest ... --artifact-dir ...` (offline path); checksum mismatch and a
  path-traversal filename in the manifest are rejected with exit 6 before anything is installed; `rpm -V` clean.
- bats: 12 unit tests (`linux-discovery.bats`, one skipped as root) and 6 live tests (`linux-install.bats`) green.

Windows `AdaptiveAutovacuum.Setup.psm1` / `adaptive-autovacuum-setup.ps1` / `install.ps1`, on the workstation's live EDB
PostgreSQL 18.4 service `postgresql-x64-18` (PowerShell 7.5.2 and Windows PowerShell 5.1):

- Discovery found four EDB installations (14, 15, 17, 18) from services and registry, merged them per data directory,
  parsed the quoted service path with spaces, and selected the only running supported one (18).
- `install.ps1 -Manifest -ArtifactDir` (offline ZIP with `artifact-manifest.json`): ZIP checksum and per-file checksums
  verified, the in-use DLL replaced by rename-aside and cleaned after the restart, service restarted, `CREATE EXTENSION`
  in `aav_installer_test`, controller enabled, 15/15 doctor rows OK (first run: `last_cycle` WARN until the first cycle).
  Checksum mismatch and a hostile manifest exit 6. Rerun: `Restart: not needed`, exit 0. `check` and `doctor -Format json`
  work under Windows PowerShell 5.1 from the installed copy in `C:\Program Files\adaptive_autovacuum\1.1.0`.
- A database still on pre-1.1.0 objects (development snapshot) now yields one `doctor_api` WARN row instead of aborting.
- Pester 6: 16 unit tests (`windows-discovery.Tests.ps1`) green. The live Pester suite mirrors the manual run above.
- The controller was disabled again afterwards (`disable`), leaving the workstation with 1.1.0 files installed and
  `adaptive_autovacuum.enabled = off` as before.

Not exercised locally: DEB build and Ubuntu (`pg_lsclusters`) discovery path, aarch64/arm64, the GitHub workflows.

### Addendum 2026-09-19: PostgreSQL 17 and 18 packages, shared helper package

- Supported majors widened to 17 and 18 in both helpers and both bootstraps. With several supported majors installed the
  bootstrap takes the one with a running cluster; with two running it exits 4 and requires `--pg-major` / `-PgMajor`,
  which is then forwarded to the helper so the package and the configured cluster always match.
- RPM spec parametrised by `pgmajor`; the helper moved into its own noarch package `adaptive-autovacuum-setup` because
  two versioned packages owning `/usr/bin/adaptive-autovacuum-setup` conflict (`dnf` transaction test error reproduced
  on WSL). Debian templates (`control.in`, `changelog.in`, `generate.sh`) produce the same split (`Architecture: all`).
  `debug_package` disabled. The release manifest gained `component: setup-helper` artifacts (`postgres_major: 0`) and
  `install.sh` installs helper + extension in one transaction after verifying both checksums.
- WSL AlmaLinux 9, PG17 (5433) and PG18 (5432) both running: `postgresql17-` and `postgresql18-adaptive-autovacuum`
  built from the same spec, `install.sh --pg-major 17` configured the PG17 cluster (preload, restart, CREATE EXTENSION,
  15/15 doctor OK), then `--pg-major 18` installed the second package next to it with the shared helper; both clusters
  healthy afterwards. Stopping PG17 made the bootstrap pick 18 automatically.
- Windows: PG17 and PG18 ZIPs built (MSVC, `build-zip.ps1 -PgMajor`); with 14/15/17/18 installed and only 18 running,
  `install.ps1 -Check` selected 18 and the pg18 ZIP; `-PgMajor 17` selected the (stopped) 17 installation for `check`;
  `-PgMajor 16` exits 5. Found and fixed: a loop variable clobbered the parsed manifest, and unexpected errors now exit 8
  (`trap`) instead of leaving the previous exit code. Pester unit suite green (16) after the support-list change.
- Not exercised locally: DEB build of the two-package source, aarch64/arm64, a live PG17 install on Windows (the 17
  service shares port 5432 with 18 on this workstation), the GitHub workflows.

### Addendum 2026-09-19: `adaptive_autovacuum.enabled` defaults to on

The C GUC default changed from off to on (installing = preload + CREATE EXTENSION is the opt-in; `off` pauses every
database). Regression re-run green on WSL PG 17.11/18.6 (two passes each; pass 2 still sets the GUC off explicitly so the
launcher stays idle during the suite) and Windows PG 18.4 (two passes). A preload-only scratch cluster with no
`adaptive_autovacuum.enabled` line shows `boot_val = on, source = default`, the launcher worker running and the first
cycle completed; `doctor` reports `launcher_enabled` OK without any ALTER SYSTEM. The installers still set the GUC on
explicitly so that an earlier `off` is undone. CI discovery inside the `postgres` containers was fixed the same day:
`/proc/<pid>/exe` is unreadable there (no ptrace access for container root), so the scan now falls back to `argv[0]`,
skips zombies, validates against `postmaster.pid`, silences the environment read, and closes descriptors 3-9 around
`pg_ctl` so a restarted postmaster cannot hold the caller (bats) open.

## Validation performed 2026-09-20 (first packaged release v1.1.0)

`release.yml` published GitHub release **v1.1.0 "1.1.0 (beta)"** (normal release so `releases/latest` resolves; beta stated in
title, notes and README) with 21 assets: 8 Ubuntu DEBs (24.04/26.04 x amd64/arm64 x PG 17/18) + `adaptive-autovacuum-setup_1.1.0-1_all.deb`,
4 EL9 RPMs (x86_64/aarch64 x PG 17/18) + `adaptive-autovacuum-setup-1.1.0-1.el9.noarch.rpm`, 2 Windows ZIPs (PG 17/18),
`release-manifest.json` (16 installer artifacts, schema-validated), `SHA256SUMS`, `install.sh`, `install.ps1`, and the PGXN-style
source zip `adaptive_autovacuum-1.1.0.zip` (META.json at top level). Every asset hash in `SHA256SUMS` matches the manifest.

Each package was installed and exercised in a clean environment by CI before publication: DEB in `ubuntu:24.04` / `ubuntu:26.04`
containers via `apt-get install` of the two packages, `install.sh` offline, the `pg_lsclusters` discovery path, the live bats suite
and `apt-get remove` (extension objects preserved); RPM likewise in `almalinux:9` (x86_64 and aarch64 runners); Windows on
`windows-latest` (Chocolatey EDB PostgreSQL 17/18, MSVC build, `install.ps1` offline, live Pester suite: install, restart,
activation, doctor, idempotent rerun, disable).

Online quick install verified with the README commands against the published release:
- WSL AlmaLinux 9 (PG 17 and 18 running): `curl -fsSLO .../releases/latest/download/install.sh; sudo bash install.sh --pg-major 18
  --database postgres --yes` downloaded and checksum-verified the PG18 RPM and the helper RPM from GitHub, installed them and finished
  with doctor clean.
- Windows 11 (EDB 14/15/17/18 installed, 18 running): `Invoke-WebRequest .../releases/latest/download/install.ps1; .\install.ps1
  -Database aav_installer_test -Credential ...` downloaded and verified the PG18 ZIP, replaced the in-use DLL, restarted the service,
  15/15 doctor OK; the controller was disabled again afterwards.

CI defects found and fixed while getting there (all in workflows/test harness, none in the extension): `argv[0]` fallback when
`/proc/<pid>/exe` is unreadable in containers; zombie postmasters; quiet `environ` reads; descriptors 3-9 closed around `pg_ctl`
(bats hang); `--separate-stderr` for JSON tests; EPEL/CRB for `postgresql<major>-devel` on EL9; `initdb` instead of the systemd-bound
`postgresql-N-setup`; `tar` instead of `git archive` when checkout has no `.git`; make shebang kept on line 1 of generated
`debian/rules`; `shell: bash` for `pipefail` steps (Ubuntu 24.04 dash); Chocolatey vs preinstalled PostgreSQL on the Windows runner
(password set via temporary trust); Pester live suite runs scripts in a child `pwsh`; and a matrix bug that silently dropped every
x86_64/amd64 and 24.04 job (`include` entries without a matrix key overwrite each other) caught before publication.

Beta exit criteria (unchanged): 30 days on at least two external clusters with the controller active and no unexplained cluster
changes or failed applies, one field upgrade through `ALTER EXTENSION UPDATE`, CI green on every platform.

## Validation performed 2026-09-24 (cluster-global redesign, SQL 1.2.0, working tree)

Scope: the review's cluster-global redesign (one control plane per cluster) plus its four targeted fixes (no
`pg_current_xact_id()` for XID velocity; cost-weighted `vacuum_activity_rate` instead of a buffer-hit MB/s figure;
corrected `global_recommendations` comment; compiled `enabled` default already on). Version 1.2.0 has no upgrade path
from 1.1.0 (beta): the 1.0.0/1.1.0 scripts and the `upgrade` regression test were removed.

Regression (`test/sql/adaptive_autovacuum.sql`, 40 assertions rewritten or added: name-keyed `table_policy` applied by the
database program, discovery include/exclude, program hygiene - no extension objects, no XID allocation, no quoting tag -
`database_status`, `actions`, `aging_tables`, cluster-first `status()`, 18 `doctor()` checks): green on WSL AlmaLinux 9
PG 17.11 and PG 18.6 (pass 1 on-demand load, pass 2 preloaded with the controller off) and on Windows 11 PG 18.4 (MSVC DLL,
both passes). The result file is identical across the two majors and the two passes.

Live cluster drill (WSL PG 18.6, `naptime_seconds = 5`, control database `postgres`, three tenant databases without the
extension): the launcher (no database connection) started the controller, which logged "extension objects are missing"
until `CREATE EXTENSION` ran in `postgres`, then discovered all four databases and completed sweeps 1-4 with 4/4 databases
each (`controller_status()`: `running|4|4|4|4|0`). A 200 K-row table with `autovacuum_enabled = false` and 99.5 % dead rows
in `tenant_002` appeared in the central `table_state` as `backlog_critical` / `autovacuum_disabled`; a never-analyzed table in
`app` received `set_reloptions` (insert threshold/scale) and `analyze`, both executed by the worker connected to `app`,
while `pg_namespace` in the tenants stayed free of extension objects. The controller alone queued and applied the cluster
settings in sweep 1 (`autovacuum_vacuum_cost_limit -1 -> 400`, `_cost_delay 2 -> 1`, `_max_threshold -> 5000`), then held
with the new activity-based reason ("did not produce a meaningful increase in autovacuum activity ... the extra budget is
not being used yet"). A hand-queued `emergency_queue` row for the tenant table was claimed by the controller, run by an
emergency worker connected to `tenant_002` (worker PID recorded), and finished `completed` with `age(relfrozenxid) = 10`.
`CREATE EXTENSION` in `tenant_001` raised the install-time WARNING, `doctor()` there reported `control_database FAIL`, the
control database reported `duplicate_installations WARN`, and the controller logged the duplicate once per sweep.
`excluded_databases = ARRAY['tenant_00%']` marked both tenants `excluded` and dropped the sweep to two databases. Pointing
`adaptive_autovacuum.control_database` at a nonexistent database and terminating the controller left the launcher in
"waiting for control database" with a backoff WARNING and no controller; resetting the GUC brought the controller back
(`running`, generation continued at 10). `DROP DATABASE app` removed its `database_state` row on the next sweep. No
unexpected ERROR/WARNING lines; `pg_stat_tmp/adaptive_autovacuum/` held only `program.sql` afterwards (per-database
handoff files are removed after absorption).

Windows live check (EDB PG 18.4 scratch cluster, preloaded, `enabled = on`): identical start-up sequence, three databases
per sweep in 0.7-0.8 s, `analyze` applied in a tenant database, `doctor()` clean apart from `track_cost_delay_timing`.

Drill-script lessons (not product defects): `psql -c` with several statements runs them in one implicit transaction, so
`VACUUM` and `ALTER SYSTEM` must be issued as separate `-c` calls; the extension itself uses the server's `vacuum()` and
`AlterSystemSetConfigFile()` entry points and is unaffected.

Not yet covered: a sustained multi-tenant soak (hundreds of databases) and the emergency takeover path (stalled anti-wraparound
autovacuum) under the new dispatcher; packaging and installer changes for the single-control-database install are deferred
to the next release.

### pgbench worker/cost ladder drill, cluster-global controller (2026-09-24)

Replay of the Ubuntu `aavtest.sql` method against the redesigned controller on both hosts: control database `postgres`
(extension there only), workload database `aavtest` with NO extension objects, 100 tables x 100K rows with
`autovacuum_vacuum_threshold = 1000, scale_factor = 0`, `pgbench -c 16 -j 8 -T 150`, start `autovacuum_max_workers = 1`,
`autovacuum_vacuum_cost_limit = 10`, `autovacuum_vacuum_cost_delay = 100ms`, `adaptive_autovacuum.naptime_seconds = 10`,
`policy.min_table_bytes = 8 MB`. Samples every 5 s for 300 s (`C:\cld\aav_results\{wsl,win}_pg18.csv`, charts
`aav_drill_linux_pg18.png`, `aav_drill_windows_pg18.png`, `aav_drill_both_hosts.png`, scripts `aav_wsl_pgbench_drill.sh`,
`aav_win_pgbench_drill.ps1`, `aav_plot.py`).

WSL AlmaLinux 9 / PG 18.6 (24 CPUs, 1,837 tps): the controller alone applied every change through one queue:
sweep 5 workers 1->2, cost 10/100 ms -> 200/50 ms, insert scale factor 0.2 -> 0.09, max_threshold -> 5000; sweeps 6-9
workers 2->4->8->12->16 (one doubling-bounded step per sweep, queue pressure of 100 overdue relations); sweep 12
400/25 ms; sweep 13 800/12.5 ms plus the mistuned-baseline correction (vacuum scale 0.2 -> 0.045, threshold 50 -> 500,
analyze 0.1/50 -> 0.0225/250); sweep 14 1600/6.25 ms; then held by the activity feedback while the debt shrank from
10 M tuples to 50 K and overdue relations from 100 to 0 by the end of the load; after 10 backlog-free sweeps (sweep 29)
one decay step 1600/6.25 -> 800/12.5 ms. Windows 11 / PG 18.4 (6,308 tps): the same ladder one sweep earlier at each
step (sweeps 4-8 for workers 1->16, cost 10/100 -> 200/50 -> 400/25 -> 800/12.5 -> 1600/6.25 -> 2560/6.25 ms, the last
being the 3,200 MiB/s page-rate cap keeping the delay and taking only the limit), backlog cleared 30 s after the load
stopped, decay 2560/6.25 -> 1280/12.5 ms at sweep 29. Observed cost-weighted activity tracked the budget the pair
allows during the load (about 100 K cost units/s on both hosts) and fell to single digits afterwards, which is what the
hold reason reports. Worker count was never lowered; no controller errors in either server log (the 57 Windows log
errors are the drill's own PowerShell monitor sending malformed statements, visible as `STATEMENT: 0`).

## Validation performed 2026-09-24 (1.2.0 packaging and installers)

Version 1.2.0 everywhere (control file, spec, Debian changelog, META.json, helper, install.sh, Windows module and
install.ps1, manifest `minimum_installer_version`). Both installers switched from per-database activation to one
control database: `--control-database` / `-ControlDatabase` (default `postgres`; `--database` / `-Database` kept as an
alias, `--all-databases` / `-AllDatabases` rejected), the helper writes `adaptive_autovacuum.control_database` when it
differs, re-creates the extension (`DROP EXTENSION` + `CREATE EXTENSION`, after the plan and confirmation) when the
installed copy is older and no upgrade script exists, reports copies in other databases as ignored, waits for
`controller_running`, and `doctor` checks the control database only (JSON gained `control_database` and
`duplicate_installations`). `install.sh` now calls `/usr/bin/adaptive-autovacuum-setup` explicitly so a stale copy
earlier in `PATH` cannot shadow the packaged helper (found on the test box).

Linux (WSL AlmaLinux 9, PGDG PG 18.6 and 17.11 with the 1.1.0 RPMs installed and the extension in `postgres`):
`bash -n` clean; 16/16 unit bats; RPMs built for 18 and 17 (`--define pgmajor`); `dnf install` upgraded all three
packages in one transaction, `rpm -V` clean; `make-release-manifest.sh` produced a 3-artifact manifest with
`minimum_installer_version 1.2.0`; `install.sh --check` and `--dry-run` offline against it; the packaged helper's plan
for the 1.1.0 copy read `DROP EXTENSION + CREATE EXTENSION adaptive_autovacuum (1.1.0 -> 1.2.0: no upgrade script ...)`
and `install --yes` re-created it (`[OK] extension re-created in postgres`), `doctor --format json` reported
`control_database postgres`, `duplicate_installations ["aav_dup"]` for a copy created in another database, and
`controller_running true`; `--control-database aav_dup` moved the control plane (`ALTER SYSTEM` + reload, controller
followed: `status()` in `aav_dup` showed `is_control_database = t`) and back; live bats 7/7 (dry run, `--all-databases`
rejected, two control databases rejected, install, idempotent rerun, disable/enable, remove-preload).

Windows 11 (EDB PG 18.4 service `postgresql-x64-18`, 1.1.0 objects in `aav_installer_test`): `build-zip.ps1 -PgMajor 18`
built `adaptive_autovacuum-1.2.0-pg18-windows-x64.zip`; all five PowerShell files parse; Pester discovery 16/16;
`install.ps1` offline with a local manifest: `-Check` OK, checksum mismatch exit 6, `-DryRun` plan showed the re-create
and the control-setting change, the real run replaced the DLL, restarted the service, set
`adaptive_autovacuum.control_database = aav_installer_test`, re-created the extension there, enabled the controller,
and `doctor` was all OK except `duplicate_installations WARN` for the old `aav_win` copy (sweep 1 over 9 databases);
duplicate detection verified with a temporary `aav_win_dup`; idempotent rerun via the installed helper under
`C:\Program Files\adaptive_autovacuum\1.2.0\`; Pester live suite 4/4 (a first run failed only because a stale 1.1.0
ZIP in `dist\` was picked up; removed). The workstation was left with the controller disabled again.

Not run here: DEB build (no dpkg on the test hosts; CI covers it), the GitHub `release.yml` publication itself.

## Validation performed 2026-09-25 (1.3.0: Debian 12/13 and EL10 packages)

Packaging release plus one SQL fix (addendum 2026-09-26 below). `package-deb.yml` matrix gained `debian12` (bookworm) and `debian13` (trixie); `package-rpm.yml`
gained a `dist` dimension (`el9` on `almalinux:9`, `el10` on `almalinux:10`, PGDG `EL-<n>` repositories, artifact names
`rpm-<dist>-<arch>-pg<major>`). Version 1.3.0 everywhere (control file, spec and its changelog, Debian changelog,
META.json, helper, install.sh, Windows module and install.ps1, bats and regression asserts, docs). The SQL objects are
unchanged: `sql/adaptive_autovacuum--1.2.0.sql` stays frozen, `assemble.sh` now writes `--1.3.0.sql`, and a comment-only
`--1.2.0--1.3.0.sql` upgrade script ships so the installers take the `ALTER EXTENSION UPDATE` path; the stale 1.0.0 to
1.1.0 upgrade test was rewritten for 1.2.0 to 1.3.0 and added back to `REGRESS`. The spec sets `__brp_check_rpaths`
to nothing: EL10's rpmbuild rejected the PGXS rpath to `/usr/pgsql-18/lib` (`ERROR 0002 ... invalid runpath`), which
PGDG's own extension packages also carry. `release.yml` notes list the platforms and the in-place upgrade from 1.2.0.
`make-release-manifest.sh` already accepted `debian13` and `el10` names; `install.sh` already mapped Debian and every
EL clone (`rhel|rocky|almalinux|centos|ol` to `el<major>`), only its unsupported-distribution message changed.

Regression (WSL AlmaLinux 9, PGDG PG 18.6 and 17.11, two passes each: on demand and preloaded with the controller off):
`adaptive_autovacuum` and the new `upgrade` test pass on both majors; the upgrade output (1.2.0 created, policy edit,
`ALTER EXTENSION UPDATE` to 1.3.0, values preserved, 18 doctor checks, `_run_cycle` runs) is identical across 17/18 and
both passes and was adopted as `test/expected/upgrade.out`.

EL9 upgrade path (same box, 1.2.0 RPMs reinstalled first so the files matched the release): RPMs built for 18 and 17,
`dnf install` moved all three packages to 1.3.0 in one transaction, `rpm -V` clean, the package ships `--1.2.0.sql`,
`--1.3.0.sql` and `--1.2.0--1.3.0.sql`; `install.sh --dry-run` planned `ALTER EXTENSION adaptive_autovacuum UPDATE
(1.2.0 -> 1.3.0)` and `--yes` ran it: extension 1.3.0, `global_apply_queue` still 19 rows, the `min_table_bytes` marker
set before the upgrade survived; doctor all OK, controller running (generation 49 to 50); live bats 7/7. The PG 17
cluster held a forgotten 1.1.0 copy; the helper re-created it as 1.3.0 (`DROP EXTENSION + CREATE EXTENSION`, controller
running afterwards). A `systemctl restart` of both clusters at once failed PG 17 with `lock file "postmaster.pid"
already exists` (WSL restart race, unrelated to the packages); a plain start recovered it.

Debian 13 (fresh WSL `Debian` distribution, trixie amd64, PGDG PG 18.6, same steps as the CI job): `generate.sh 18`,
changelog `1.3.0-1` matches the control file, `dpkg-buildpackage -us -uc -b` built
`postgresql-18-adaptive-autovacuum_1.3.0-1_debian13_amd64.deb` (55 KB `.so`, three SQL scripts, control file) and
`adaptive-autovacuum-setup_1.3.0-1_all.deb`; `pg_ctlcluster 18 main` cluster (port 5434); `install.sh --check` and `--yes
--control-database postgres` offline against a local manifest: preload set, restart through `postgresql@18-main`,
extension 1.3.0 created, doctor 17 OK + `last_sweep WARN` (first minute), no FAIL; live bats 7/7; `apt-get remove`
deleted the `.so` and kept the database objects; reinstalled afterwards.

EL10 (fresh WSL `AlmaLinux-10` distribution, 10.2 x86_64, PGDG EL-10 PG 18.6, `epel-release` + `crb`, `bats` 1.11.1 from
EPEL 10; `dnf module disable postgresql` has nothing to disable and is now `|| true` in the workflow): first rpmbuild
failed in `check-rpaths` (fixed as above), second built `postgresql18-adaptive-autovacuum-1.3.0-1.el10.x86_64.rpm` and
`adaptive-autovacuum-setup-1.3.0-1.el10.noarch.rpm` (rpmlint reports the rpath and a long description line, non-fatal
as in CI); cluster via `initdb` + `pg_ctl` as in the CI container; `install.sh --check`/`--yes --control-database
postgres` offline: preload, restart with `pg_ctl` (no systemd unit), extension 1.3.0, doctor no FAIL, `rpm -V` clean;
live bats 7/7; `dnf remove` kept the database objects; reinstalled afterwards.

Windows: version bump only; the module and `install.ps1` parse, Pester discovery 16/16. Not run here: arm64/aarch64
builds, Debian 12 and Ubuntu (CI covers them), the GitHub `release.yml` publication.

### Addendum 2026-09-26: `vacuum_activity_detail` per-second keys were cumulative

`_global_controller()` built `hits_per_sec`, `reads_per_sec`, `writes_per_sec` and `extends_per_sec` from the cumulative
`pg_stat_io` autovacuum-worker counters divided by the sample interval, so the detail grew with uptime while
`vacuum_activity_rate` (delta-based) was correct. Fixed in 1.3.0 (not yet released): `controller_state` gained
`last_io_hits`, `last_io_reads`, `last_io_writes`, `last_io_extends`, written every sweep and differenced on the next;
the first sweep after an upgrade has no previous counters and reports 0. The 1.2.0 -> 1.3.0 upgrade script now adds the
four columns; `test/sql/upgrade.sql` asserts them and the main suite seeds a 100000-hit gap over 100000 s and reads back
1 hit/s. Regression: WSL AlmaLinux-9 PG 18.6 and PG 17.11, two passes each (both tests), Windows PG 18.4 two passes,
all green. Found while building a pgbench watch script that wanted MB/s from the detail keys.

## Validation performed 2026-09-26 (1.3.0: table settings recommended, autovacuum repaired first)

Follow-up to the 2026-09-25 pgbench drill on an AWS t4g.small (user-run, `Downloads\pgbenchdrill_1.sql`: 100 tables x
100K rows with `autovacuum_vacuum_threshold = 1000, autovacuum_vacuum_scale_factor = 0`, pgbench with autovacuum and the
controller off, then the controller switched on). That drill found the controller LOOSENING operator-set triggers: with
the 5,000 `target_dead_tuple_min` floor it rewrote the tables to threshold 500 / scale factor 0.045 / max threshold
5,000, the tables sat at about 2,450 dead tuples, core autovacuum never fired, and the controller read them as healthy
while the cost pair decayed. It also showed the `autovacuum = off` repair arriving minutes after the switch (10 checks,
then only at the end of a sweep) and the `vacuum_activity_detail` per-second keys being cumulative (fixed the same day).

Design decisions taken (user): per-table automatic management is gone. The database program computes table settings and
RECORDS them; it never runs `ALTER TABLE`. Trigger settings are always recommended as a threshold + scale factor pair
(plus `autovacuum_vacuum_max_threshold` on PostgreSQL 18), cost boosts are recommendations too, and the operator runs
the SQL text in the table's own database (`table_recommendations.apply_sql`, `revert_sql`); no cross-database apply
function. `min_table_bytes` defaults to 0 (a small hot table matters as much as a large one), `target_dead_tuple_min`
to 1,000. `autovacuum = off` is repaired before anything else.

What changed (SQL 1.3.0, `sql/parts/*`, upgrade script assembled from `90_upgrade_1.2.0_head.sql` + parts 02-04 with
`CREATE OR REPLACE`):

- `table_state` carries the recommendation (`recommendation_status` open / applied / revert, `recommended_reloptions`,
  `previous_reloptions`, `recommendation_reason`, `recommended_at`, `applied_at`) instead of ownership state
  (`original_reloptions`, `original_captured`, `managed_values`, `ownership_conflict`, `last_change_at`, `last_error`
  dropped). View `table_recommendations` builds the SQL with `_reloptions_sql()` (allow-listed keys, numeric values,
  null = RESET); `changed_tables`, `_reconcile_relation_options()` and `_managed_values_match()` are gone.
- Lifecycle: `open` after `overdue_cycles_before_recommend` (2) non-normal checks; `applied` when every recommended key
  matches the reloptions numerically, and then FROZEN (never re-tuned while in place, even when the table reads more
  severe against its tighter trigger); `revert` (cost keys only) after `healthy_cycles_before_revert` (6) normal
  checks; the row is dropped when nothing of ours is left in place, and when the table is dropped (state rows of
  relations that no longer exist are pruned at the next scan).
- Never-loosen guard: a dead- or insert-side trigger is recommended only when it fires earlier than the current one; a
  cost pair only when stronger than the pair the table vacuums under (its own cost reloptions, else the cluster pair).
  Widespread-overdue suppression: when the previous scan found at least 3 relations and a quarter of the eligible fleet
  overdue on a side, no trigger recommendation is issued on that side (the cluster baseline is corrected instead, the
  same rule as the section-7 detector; found in the drill where all 100 tables opened an insert-side recommendation for
  one sweep before the cluster insert scale factor changed).
- Policy: `manage_table_costs` -> `recommend_table_costs` (default true), `overdue_cycles_before_change` ->
  `overdue_cycles_before_recommend`, `healthy_cycles_before_restore` -> `healthy_cycles_before_revert`;
  `change_cooldown_seconds`, `max_changes_per_cycle`, `boost_ramp_factor`, `boost_total_cost_limit_budget` dropped;
  `max_boosted_relations` (2) now bounds standing cost-boost recommendations cluster-wide.
- `database_state.changes_applied` -> `recommended_relations`; `database_status` shows it; `status()` adds
  `open_table_recommendations`; `doctor()` adds check 14 `table_recommendations` (19 checks).
- `latest_global_recommendation` adds `vacuum_read_mbps` / `vacuum_write_mbps` (pg_stat_io page deltas x block size);
  `vacuum_activity_rate` and `cost_budget_rate` stay in cost units per second.
- `autovacuum = off` first: new `_repair_disabled_autovacuum()`; the C controller calls it (and applies the queued row,
  SIGHUP to the postmaster) at the very start of `aav_run_sweep()` before any database worker, and right after every
  configuration reload it processes in its wait loop, so `ALTER SYSTEM SET autovacuum = off; SELECT pg_reload_conf()`
  is undone within the same second. A repair applied in the last 30 s is not queued again (the controller's own copy of
  the GUC still reads off until the postmaster's reload reaches it; first drill runs produced a duplicate row from both
  the sweep start and the global step). The control-plane readiness probe requires the new function, so a 1.3.0 library
  over 1.2.0 SQL waits with the usual "missing or outdated" warning until `ALTER EXTENSION UPDATE`.
- Upgrade 1.2.0 -> 1.3.0 keeps table options the old controller wrote (they are tighter triggers) and logs one
  `legacy_table_settings` row per relation in `decisions` (visible in `actions`) with the SQL that restores the captured
  original values.

Regression (`test/sql/adaptive_autovacuum.sql`, `upgrade.sql`): the suite asserts the program text contains no
`ALTER TABLE`, exercises `_reloptions_sql()`, and runs the full lifecycle on two tables while holding them in
`SHARE UPDATE EXCLUSIVE` inside a transaction (core autovacuum skips locked relations, so the checks are deterministic):
open with the exact `apply_sql` (trigger pair + max threshold on 18 + urgent boost), never-loosen on a table tuned to
threshold 100, operator applies via `EXECUTE apply_sql`, `applied` detected and frozen while the table reads critical,
`revert` with the exact `RESET` text after one healthy check, closed after the revert, the operator's trigger kept;
widespread suppression (nine overdue of thirteen eligible: cost advice only, reason names the cluster baseline); dropped
tables pruned; 19 doctor checks; `status()`/`doctor()` agree on open recommendations. The upgrade test seeds a 1.2.0
managed row and asserts the legacy decision text, renamed and dropped columns, the moved defaults and the replaced
objects. Expected output adopted from WSL PG 18.6 (93 true, 0 false, two passes identical); PG 17.11 two passes and
Windows PG 18.4 two passes pass against it unchanged. C: rebuilt on WSL (gcc, PGDG 18.6 / 17.11) and Windows (MSVC 19.44).

Two-phase pgbench drills (scripts `C:\cld\aav_wsl_pgbench_drill.sh`, `aav_win_pgbench_drill.ps1`; charts
`C:\cld\aav_results\aav_121_*.png` from `aav_plot_recs.py`): start with `autovacuum = off`, `autovacuum_max_workers 1`,
cost 10 / 100 ms, naptime 10 s, `adaptive_autovacuum.enabled = off`; 100 worker tables x 100K rows (threshold 1000),
5 hot tables x 20K rows (default trigger) and 2 loose tables x 10K rows (scale factor 0.5, own max threshold off), all
with an indexed `counter` so updates are not HOT (page pruning otherwise removes the dead tuples of small hot tables
before autovacuum ever sees them); pgbench 16 clients for 120 s; then only the controller is switched on; the "operator"
runs every `apply_sql` open for 30 s and every `revert_sql`, one naptime apart; a 60 s hot + loose burst at +150 s.

- WSL AlmaLinux 9, PG 18.6, 24 CPUs (three runs, 2,400 to 2,750 TPS during the build, 160K to 206K dead tuples on the
  worker tables): `autovacuum = on` applied 0.1 to 0.2 s after the reload every time (queue row requested 50 ms after
  the reload; one row after the guard, two before it); first sweep 10 s later raised the pair 10 / 100 ms -> 200 / 50 ms
  (built-in floor), workers 1 -> 2 -> 4 -> 8 -> 16 over four sweeps, cost pair doubled per sweep to 1600 / 6.25 ms,
  `autovacuum_work_mem` and the cluster triggers (scale factor 0.2 -> 0.009, threshold 50 -> 100, max threshold ->
  1,000, insert scale 0.2 -> 0.09, analyze scale 0.1 -> 0.005) set from the fleet evidence; the whole debt (10.3M
  dead + inserted-since-vacuum tuples) drained in about 2.5 minutes at up to 60 MiB/s written / 17 MiB/s read by
  autovacuum workers; two cost-boost recommendations (critical tier 6000 / 0 ms) opened after two checks, were applied
  by the operator, detected `applied` on the next sweep, turned to `revert` after six healthy checks and closed after the
  RESET; the burst opened boosts for the hot tables again; after ten backlog-free checks the pair decayed 1600 / 6.25 ->
  800 / 12.5 -> 400 / 25 ms toward the baseline. Zero server-log errors. Trigger recommendations did not fire for the
  hot tables because the cluster max threshold of 1,000 already made their trigger (280) tighter than the 1,000 target,
  which is exactly the never-loosen rule; the loose tables needed their own `autovacuum_vacuum_max_threshold = -1` to
  escape that cap (run 4 below).
- Windows 11, PG 18.4 (EDB), 24 CPUs (three runs, 7,700 to 10,300 TPS, 386K to 420K dead tuples): repair applied 0.5 to
  1.2 s after the reload (the wait-loop path fired at +0.7 s; before the guard the first sweep queued a duplicate row,
  the final run on the current SQL shows exactly one), same ladder to 1600 or 2560 / 6.25 ms and 16 workers, decay to
  800 or 1280 / 12.5 ms, boosts applied and reverted, zero log errors. Core's launcher started only one worker per
  `autovacuum_naptime` / databases in the first two minutes after the repair, so activity lagged the raised budget;
  the controller does not manage `autovacuum_naptime` (candidate for later).
- WSL run 4 (loose tables with their own `autovacuum_vacuum_max_threshold = -1`): the trigger recommendation for the two
  loose tables opened only after the fleet had drained (86 of 107 tables were still overdue during the burst, so the
  widespread rule held it back, reason recorded), with the expected text ("Dead tuples 71555 ... current trigger of
  6000 (threshold 1000 + scale factor 0.5 x 10000 rows); firing at 1000 dead tuples ...") but after the drill's
  operator window. The run also exposed ratios of 10x and more printing as `#.##` (`to_char(..., 'FM0.00')`, one
  integer digit) in the state and recommendation reasons; widened to `FM9990.00` (`FM990.000` for the XID ratios) and
  the suite re-run on all three builds (WSL 18.6 x2 adopted, 17.11 x2, Windows 18.4 x2, all green).
- WSL run 5 (format fix, burst at +240 s): repair 0.1 s, one queue row; the loose tables' trigger recommendation opened
  during the burst with correct text ("Dead tuples 55812 are 9.30x the current trigger of 6000 ... firing at 1000 dead
  tuples") and was withdrawn one sweep later because autovacuum, by then with 16 workers and a raised budget, vacuumed
  them at once (55K dead against a 6,000 trigger); the operator's 30 s window never came, which is the intended
  outcome for a table autovacuum does reach. Four cost boosts (two waves) were applied and reverted. The activity
  feedback held the pair at 400 / 25 ms for most of the drain (observed activity matched the budget), it reached
  800 / 12.5 ms only during the burst and decayed to 200 / 50 ms afterwards; the drain took about 5.5 minutes
  against 2.5 in the runs where the pair climbed to 1600 / 6.25 ms. Zero log errors.

Not done: the Debian/EL10 package builds and installers were not re-run after the SQL change (the packaging is
unchanged; the SQL files ship inside the same packages), and the architecture DOCX was not regenerated.

## Validation performed 2026-09-26 (1.3.0: autovacuum_naptime managed, worker raises easier)

The drills above (all on the 1.2.x controller logic) showed `autovacuum_max_workers` going 1 -> 16 within 40 s while one
to three workers actually ran: core's launcher visits each database once per `autovacuum_naptime` (60 s) and starts one
worker for it, so a raised pool stays empty. The user asked for workers that grow more easily and a naptime that ramps
down; with nothing committed yet the working tree became 1.3.0 (`sql/adaptive_autovacuum--1.3.0.sql`,
`--1.2.0--1.3.0.sql`, version strings in the control file, Makefile, META.json, packaging, installers, docs, tests).

Changes:

- `autovacuum_naptime` is managed (allow-listed in SQL and C, reloadable): halved per check down to
  `policy.naptime_min_seconds` (default 5) while relations are overdue, the debt is not under control, memory and
  storage are not under pressure and fewer workers run than the pool allows; doubled back toward the operator baseline
  in the same decay step as the cost pair (baseline tracked in `controller_state.baseline_settings` like the cost
  pair). `policy.manage_naptime` (default true) switches it off. `global_recommendations` gained
  `recommended_autovacuum_naptime_seconds`, `status()` `autovacuum_naptime_seconds`.
- Worker raise: the queue test is now "overdue relations >= workers + 2" (was also ">= 2 x workers"), and CPU load
  alone no longer blocks a raise (memory and storage pressure still do, critical wraparound overrides): the workers
  share one cost budget, so the pool adds concurrency rather than I/O, and the small loaded host is exactly the one
  that shows load while hundreds of tables are overdue. The cost pair still holds under any host pressure.

Regression: new asserts for the defaults, the naptime halving with an under-filled pool, CPU load not blocking the
worker raise while memory pressure does (also holds naptime), naptime held with the workers when the debt is under
control, and naptime walking back up in the decay step; the upgrade test asserts the new columns. Green on WSL PG 18.6
(two passes, expected adopted, 0 false) and PG 17.11 (two passes), Windows PG 18.4 (two passes, MSVC DLL rebuilt for
the allow-list). All later WSL runs use the Debian 13 distribution (PGDG 18.6 and 17.11) at the user's request.

Two-phase drill, Windows 11 / PG 18.4, 7,400 TPS build, 382K dead tuples on the worker tables, controller switched on
at +126 s with autovacuum off: repair applied 0.4 s after the reload (one row); then per 10 s sweep

| after switch-on | max_workers | workers running | autovacuum_naptime | cost pair | overdue |
|---|---|---|---|---|---|
| 5 s | 1 | 0 | 60 s | 10 / 100 ms | 107 |
| 16 s | 2 | 0 | 60 s | 200 / 50 ms | 107 |
| 27 s | 4 | 0 | 30 s | 400 / 25 ms | 107 |
| 38 s | 8 | 0 | 15 s | 800 / 12.5 ms | 107 |
| 62 s | 16 | 4 | 5 s | 2560 / 6.25 ms | 98 |
| 84 s | 16 | 8 | 5 s | 2560 / 6.25 ms | 72 |
| 117 s | 16 | 14 | 5 s | 2560 / 6.25 ms | 29 |
| 138 s | 16 | 0 | 5 s | 2560 / 6.25 ms | 0 |

so the whole backlog drained about one minute after the pool filled, against 2.5 to 5.5 minutes in the 1.2.x runs where
at most three workers ran. Cost-boost recommendations opened, were applied and reverted; the hot + loose burst at
+240 s opened trigger recommendations for the two loose tables (`SET (autovacuum_vacuum_max_threshold = 1000,
autovacuum_vacuum_scale_factor = 0.09, autovacuum_vacuum_threshold = 100)`) which the operator applied live, plus two
boosts, all reverted or closed afterwards; after ten backlog-free checks the decay stepped `autovacuum_naptime` 5 -> 10 s
and the pair 2560 / 6.25 -> 1280 / 12.5 -> 640 / 25 ms, the reason naming the three baselines (10 / 100 ms / 60 s).
Zero log errors. Chart: `C:\cld\aav_results\aav_121_win_pg18.png`.

Same drill on WSL Debian 13 / PG 18.6 (82,800 TPS build, 657K dead tuples on the worker tables, 3.0M on the hot and
loose tables): repair applied 28 ms after the reload (one row); naptime 60 -> 30 -> 15 -> 7 -> 5 s and workers 1 -> 2
-> 4 -> 8 -> 16 over four sweeps, 12 workers running at the peak, 107 overdue relations cleared about 100 s after the
switch-on (pair 200 / 50 -> 400 / 25 -> 1600 / 6.25 ms); the burst opened trigger recommendations for both loose
tables (one combined with a cost boost in a single ALTER TABLE) which the operator applied live; decay to 640 / 25 ms
and naptime 20 s by the end of the run; zero log errors. Chart: `C:\cld\aav_results\aav_121_wsl_pg18.png`.
