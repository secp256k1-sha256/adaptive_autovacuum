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

## Required release gate

For each supported PostgreSQL major version:

1. Compile with that major's server development package.
2. Run `make installcheck`.
3. Test with assertions enabled.
4. Exercise launcher restart, worker timeout, SIGTERM during VACUUM, stale queue recovery, ownership conflict, cgroup memory limits, and active anti-wraparound autovacuum.
5. Run sustained workload tests before enabling non-dry-run actions.
