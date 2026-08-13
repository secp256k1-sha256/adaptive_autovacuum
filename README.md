# adaptive_autovacuum

**Autovacuum that tunes itself, for PostgreSQL 17 and later (full feature set on 18).**

![PostgreSQL 17+](https://img.shields.io/badge/PostgreSQL-17%2B-336791?logo=postgresql&logoColor=white)
![License](https://img.shields.io/badge/license-PostgreSQL-blue)
![Language](https://img.shields.io/badge/lang-C%20%2B%20PL%2FpgSQL-555)
![Status](https://img.shields.io/badge/status-beta-orange)

> **⚠️ Beta version, testing in progress.** This extension is under active development and validation. It has been functionally tested on Linux and Windows (PostgreSQL 18.4 and 17.6), but has not yet completed sustained production-scale testing. 

Out of the box, autovacuum uses conservative settings. On real systems that means familiar problems:

- Tables bloat faster than autovacuum cleans them, and queries slow down.
- Autovacuum runs so throttled it never finishes, or all workers are busy and tables wait in line.
- Big tables wait for millions of dead rows before anything happens, because the trigger is a percentage of table size.
- Insert-only tables (logs, events, archives) are ignored until a painful freeze storm hits.
- Someone tunes autovacuum at a table (table-level settings) during an incident, and the leftover settings are still there three years later.

`adaptive_autovacuum` watches every table and the server itself (CPU load, memory), and continuously fixes these problems **the same way an experienced DBA would**: get the cluster-wide settings right first, give genuinely special tables temporary custom settings, and clean up after itself. Every action is recorded with what it changed, why, and what the old value was.

---

## Table of contents

- [What it does](#what-it-does)
- [What it never does](#what-it-never-does)
- [See what it is doing](#see-what-it-is-doing)
- [How it decides](#how-it-decides)
- [Install](#install)
- [Turning it on safely](#turning-it-on-safely)
- [Tuning the controller](#tuning-the-controller)
- [Special cases](#special-cases)
- [Emergency wraparound protection](#emergency-wraparound-protection)
- [Upgrading and removing](#upgrading-and-removing)
- [Testing](#testing)
- [Good to know](#good-to-know)
- [License](#license)

---

## What it does

### 1. Keeps the cluster-wide autovacuum settings right

A background worker checks the whole cluster every minute (configurable). When the data says a global setting is wrong, it fixes settings through the normal `ALTER SYSTEM` + reload config mechanism, with the old value saved so you can always go back:

| Setting | Fixed when |
|---|---|
| `autovacuum_vacuum_cost_limit` / `cost_delay` | autovacuums is severely throttled and tables are falling behind. Raised step by step (doubled at most per check), never in one jump, and the delay never drops below `recommendation_delay_min_ms` (default 0.5 ms) — full manual-vacuum aggression is never set automatically. Lowered if the server is overloaded |
| `autovacuum_max_workers` | more tables are behind than there are workers, or every worker is busy while tables wait. Only ever raised automatically; lowering is your call. (PostgreSQL 18 made this reloadable, no restart needed; on PostgreSQL 17 it needs a restart, so there the advice is only recorded, never applied) |
| `autovacuum_work_mem` | a running vacuum is seen making repeated passes over the indexes, the sign it ran out of memory; also raised toward the free-memory-derived value while maintenance is actually running (never lowered without host pressure) |
| `vacuum_buffer_usage_limit` | maintenance is actually running and the host has free memory. This is the slice of shared buffers a vacuum or analyze may keep its pages in — bigger means long vacuums stop re-reading the same pages; an idle ring costs nothing. Doubled at most per check, capped by `recommendation_buffer_usage_limit_max_mb` (default 256 MB) and by 1/8 of shared buffers per worker; walked back under load; a value of 0 you set yourself (no limit) is never touched |
| `autovacuum_vacuum_scale_factor` / `_threshold` | a quarter or more of your tables are behind at the same time. That means the baseline is wrong, not the tables. So the baseline gets corrected instead of patching tables one by one |
| `autovacuum_vacuum_max_threshold` | PostgreSQL 18's cap on the dead-row trigger. Sized from your actual data: your biggest table should never wait for more dead rows than its policy target, while normal tables keep using the percentage. Only tightened automatically; a stricter value you set yourself is respected. (Does not exist on PostgreSQL 17, skipped there) |
| `autovacuum_vacuum_insert_scale_factor` / `_insert_threshold` | the same "baseline is wrong" logic, for insert-only workloads |
| `autovacuum_analyze_scale_factor` / `_analyze_threshold` | kept in proportion whenever the vacuum baseline is corrected, so planner statistics stay fresh too |

Changes are validated against a fixed list of allowed settings *and* against each setting's own documented minimum/maximum (a value the server would reject is never queued, and a bad row is marked failed individually instead of blocking the rest), and logged with old and new values in one table you can query. Prefer to stay in control? Set `manage_global_settings = false` and the extension only *writes down its advice* instead of applying it.

### 2. Gives special tables temporary custom settings

Even with a good baseline, some tables need more: the one hot table taking 20× the writes of everything else, or an append-only event table. For those, the extension sets **per-table settings** (`ALTER TABLE … SET`, the same thing you would do by hand):

- earlier autovacuum triggers for that table
- optionally a private autovacuum speed boost: starting small and doubling per step, capped by how urgent the table is **and** by a cluster-wide budget so five boosted tables can't flood your disks together

And the part hand-tuning always skips: **it undoes them.** Before the first change it saves the table's original settings; once the table has been healthy for a while (default: 6 consecutive checks), it puts the original settings back, exactly. No leftover incident tuning.

If *you* change one of the settings it manages, it notices, backs off, and stops touching that table until you hand it back.

### 3. Analyzes tables the planner knows nothing about

A table that has never been analyzed, manually or by autoanalyze, leaves the planner guessing row counts from hardcoded defaults, and that is how five-millisecond queries become five-minute ones. Freshly loaded or migrated tables sit in exactly this state until enough activity accumulates to trip autoanalyze.

Each cycle the extension finds tables that have live rows but no analyze in their entire history (system schemas and opted-out tables excluded), takes the three largest, and runs a plain `ANALYZE` on them one at a time. Once a table has statistics it never qualifies again, so on a healthy cluster this settles to a no-op. It respects dry-run, gives up quickly on locks rather than wait, and is skipped while the server is overloaded. Tune or disable it with `analyze_missing_stats` / `analyze_missing_stats_per_cycle`.

### 4. Last-resort wraparound protection

For tables getting dangerously close to transaction-ID wraparound (the failure mode that stops the whole database), it can run a targeted emergency vacuum, see [below](#emergency-wraparound-protection). On by default.

## What it never does

- Never acts until you enable it.
- Never touches a setting outside its fixed allow-list, and never touches table data.
- Never fights you: your per-table changes freeze its automation for that table; your stricter global values are respected.
- Never adds vacuum load to an already overloaded server (it watches load and memory before boosting anything).
- Never changes anything without recording what, why, and the previous value.

## See what it is doing

Everything is visible in normal tables and views inside each database:

```sql
-- cluster settings it changed: old value, new value, when, why
SELECT * FROM adaptive_autovacuum.global_apply_queue ORDER BY id DESC;

-- per-table settings currently in place: original vs current
SELECT * FROM adaptive_autovacuum.changed_tables;

-- health of every table it watches
SELECT * FROM adaptive_autovacuum.relation_status ORDER BY last_backlog_ratio DESC NULLS LAST;

-- its current advice for the cluster, in plain words
SELECT reason FROM adaptive_autovacuum.latest_global_recommendation;

-- wraparound early warning: age of every database, headroom until the
-- cluster would go read-only, and an ok / watch / alarm verdict
SELECT * FROM adaptive_autovacuum.wraparound_status;

-- complete decision history (every check, every action, every error)
SELECT decided_at, relation_name, state, action, applied, error
FROM adaptive_autovacuum.decisions ORDER BY id DESC LIMIT 50;
```

Real output from a test cluster that started with badly mistuned settings, corrected in a single pass:

```text
 id |               guc_name                | old_value | desired_value | status  | applied
----+---------------------------------------+-----------+---------------+---------+----------
  1 | autovacuum_vacuum_cost_limit          | 25        | 200           | applied | 23:50:52
  2 | autovacuum_vacuum_cost_delay          | 50        | 25            | applied | 23:50:52
  3 | autovacuum_max_workers                | 3         | 8             | applied | 23:50:52
  4 | autovacuum_vacuum_scale_factor        | 0.8       | 0.2           | applied | 23:50:52
  5 | autovacuum_vacuum_threshold           | 50000     | 500           | applied | 23:50:52
  6 | autovacuum_vacuum_insert_scale_factor | 0.8       | 0.2           | applied | 23:50:52
  7 | autovacuum_vacuum_insert_threshold    | 100000    | 2000          | applied | 23:50:52
  8 | autovacuum_analyze_threshold          | 50        | 250           | applied | 23:50:52
```

## How it decides

Every cycle, each table big enough to matter (default: over 64 MB) gets a health check on three questions:

1. **Dead rows**: how many, compared to the point where autovacuum would trigger for this table? (Uses your server version's exact trigger rules)
2. **New inserts**: how many rows added since the last vacuum, for append-heavy tables?
3. **Wraparound age**: how old is this table in transactions? This check includes the table's TOAST part (where large values live), which ages separately and is easy to miss.

The worst of those answers gives the table a state:

| State | Meaning | Response |
|---|---|---|
| `normal` | fine | nothing; restore original settings if it was previously helped |
| `backlog_elevated` | 1.5× past its trigger | earlier triggers, small boost |
| `backlog_urgent` | 3× past | stronger boost |
| `backlog_critical` | 6× past | strongest boost |
| `wraparound_warning` | 70% of the way to PostgreSQL's own forced freeze vacuum | watched and prioritized only; the built-in forced vacuum handles this range on its own |
| `wraparound_critical` | the built-in forced vacuum is provably failing: never started although the age is 1.5× past its trigger (capped at 1 billion), or running but projected never to finish | emergency vacuum / takeover (if enabled) |

Built-in caution, so it never thrashes: a table must stay behind for two consecutive checks before anything changes; each table has a cooldown between changes; only a few tables change per cycle; every `ALTER TABLE` gives up quickly rather than wait on a lock; nothing is changed on a table while it's being vacuumed.

## Install

Works on Linux/Unix and Windows. The extension behaves identically on both; only the build and service commands differ.

### Linux / Unix

Build against your server's major version, 17 or 18 (needs the server dev package: `postgresql18-devel` / `postgresql17-devel` or `postgresql-server-dev-18` / `-17`):

```bash
make PG_CONFIG=/usr/pgsql-18/bin/pg_config
sudo make install PG_CONFIG=/usr/pgsql-18/bin/pg_config
```

Add to `postgresql.conf` and restart PostgreSQL (a restart is needed once, because of `shared_preload_libraries`):

```conf
shared_preload_libraries = 'adaptive_autovacuum'
adaptive_autovacuum.enabled = off        # you will turn this on in step 1 below
track_cost_delay_timing = on             # lets it see vacuums that are mostly sleeping
```

### Windows (existing installation, e.g. the EDB installer)

You need the DLL once; build it on any machine with the same PostgreSQL major version:

1. Install **Visual Studio Build Tools** (the free compiler package is enough).
2. Make sure your PostgreSQL installation includes the development files (`include\server` and `lib\postgres.lib` exist. The EDB installer ships them by default).
3. Open the **"x64 Native Tools Command Prompt for VS"**, go to the extension folder, and run:

```bat
build_windows.bat "C:\Program Files\PostgreSQL\18"
```

4. Copy the files into your installation (Administrator prompt):

```bat
copy adaptive_autovacuum.dll            "C:\Program Files\PostgreSQL\18\lib\"
copy adaptive_autovacuum.control        "C:\Program Files\PostgreSQL\18\share\extension\"
copy sql\adaptive_autovacuum--1.0.0.sql "C:\Program Files\PostgreSQL\18\share\extension\"
```

5. Register the library and restart the PostgreSQL service **once**:

```sql
ALTER SYSTEM SET shared_preload_libraries = 'adaptive_autovacuum';
ALTER SYSTEM SET track_cost_delay_timing = on;
```

```powershell
Restart-Service postgresql-x64-18      # or: net stop postgresql-x64-18 && net start postgresql-x64-18
```

> If `shared_preload_libraries` already lists other libraries on your server, add
> `adaptive_autovacuum` to the list instead of replacing it.

**One Windows difference to know about:** Windows has no "load average". The extension measures CPU busy percentage instead (you'll see it as `load1` in the metrics). Unlike a load average, this value can never exceed the number of cores, so if you want the "server is overloaded, don't add vacuum work" protection to engage on Windows, set it below 1.0:

```sql
UPDATE adaptive_autovacuum.policy SET high_load_per_cpu = 0.85;
```

Everything else (cluster-setting fixes, per-table help, restore, the audit tables, emergency protection) works the same as on Linux.

### Both platforms

Then in every database you want managed:

```sql
CREATE EXTENSION adaptive_autovacuum;
```

Databases without the extension are simply skipped.

## Turning it on safely

Step-by-step rollout. Watch the audit tables between steps.

```sql
-- Step 1: watch only. It logs what it WOULD do, changes nothing.
UPDATE adaptive_autovacuum.policy SET enabled = true;   -- dry_run is already true
-- and in postgresql.conf: adaptive_autovacuum.enabled = on   (+ reload)

-- Step 2: let it act: fix cluster settings and per-table triggers.
--   (add  manage_global_settings = false  if you want per-table changes only)
UPDATE adaptive_autovacuum.policy SET dry_run = false;

-- Step 3: allow per-table vacuum speed boosts.
UPDATE adaptive_autovacuum.policy SET manage_table_costs = true;

-- Step 4 (optional): the emergency wraparound vacuum is on by default;
-- switch it off here if you want to run without it while evaluating.
UPDATE adaptive_autovacuum.policy SET emergency_vacuum_enabled = false;
```

## Tuning the controller

Server settings (`postgresql.conf`):

| Setting | Default | Meaning |
|---|---|---|
| `adaptive_autovacuum.enabled` | `off` | master switch |
| `adaptive_autovacuum.naptime_seconds` | `60` | how often it checks the cluster |
| `adaptive_autovacuum.control_database` | `postgres` | where the coordinator connects |
| `adaptive_autovacuum.database_worker_timeout_seconds` | `3600` | give-up time for one database's check |
| `adaptive_autovacuum.log_cycle_summary` | `on` | one log line per database per cycle |

Behavior knobs live in `adaptive_autovacuum.policy` (one row per database). The ones most worth knowing:

| Knob | Default | Meaning |
|---|---|---|
| `dry_run` | `true` | log intended actions instead of doing them |
| `manage_global_settings` | `true` | fix cluster settings, or only record advice |
| `manage_table_costs` | `false` | allow per-table vacuum speed boosts |
| `target_dead_tuple_ratio` | `0.01` | aim: vacuum a table when ~1% of it is dead rows |
| `target_insert_ratio` | `0.10` | aim: vacuum after ~10% of a table is newly inserted |
| `min_table_bytes` | 64 MB | ignore tables smaller than this (does not apply to the never-analyzed check) |
| `analyze_missing_stats` | `true` | analyze tables that have live rows but were never analyzed at all |
| `analyze_missing_stats_per_cycle` | `3` | how many never-analyzed tables to analyze per cycle, largest first |
| `change_cooldown_seconds` | `1800` | minimum gap between changes to the same table |
| `recommendation_delay_min_ms` | `0.5` | floor for the automatic cost-delay walk-down; delay 0 (manual-vacuum aggression) is never set cluster-wide automatically. A delay you set below the floor yourself is respected, never raised |
| `recommendation_buffer_usage_limit_max_mb` | `256` | ceiling for the opportunistic `vacuum_buffer_usage_limit` raise while maintenance runs |
| `healthy_cycles_before_restore` | `6` | healthy checks required before a table's original settings return |
| `max_boosted_relations` / `boost_total_cost_limit_budget` | `2` / `10000` | how many tables may hold speed boosts, and the combined ceiling |
| `high_load_per_cpu` / `low_memory_percent` | `1.5` / `15` | what counts as an overloaded server (no boosts beyond this) |
| `emergency_stall_multiplier` | `1.5` | how far past its own trigger the built-in vacuum may be before "never started" counts as failure |
| `emergency_xid_age` / `emergency_mxid_age` | 1 billion | absolute cap on the failure line above |
| `emergency_takeover_min_runtime_seconds` | `3600` | how long a grinding forced vacuum runs before it may be judged hopeless and taken over |

Everything else (severity ladders, boost tiers, emergency limits, retention) has sensible defaults and is documented as column comments and constraints on the `policy` table.

## Special cases

**Give one table its own goals:**

```sql
INSERT INTO adaptive_autovacuum.table_policy (relid, target_dead_tuple_ratio, note)
VALUES ('app.orders'::regclass, 0.005, 'hot table - keep extra clean')
ON CONFLICT (relid) DO UPDATE SET target_dead_tuple_ratio = 0.005;
```

**Keep hands off one table entirely:**

```sql
INSERT INTO adaptive_autovacuum.table_policy (relid, enabled, note)
VALUES ('app.audit_archive'::regclass, false, 'managed manually')
ON CONFLICT (relid) DO UPDATE SET enabled = false;
```

**Take a table back.** If you change a setting the extension manages, it flags the conflict and stops touching that table. To hand it back (this only clears bookkeeping, it does not touch the table):

```sql
UPDATE adaptive_autovacuum.relation_state
SET original_reloptions = NULL, original_captured = false,
    managed_values = '{}'::jsonb, ownership_conflict = false, last_change_at = NULL
WHERE relid = 'app.orders'::regclass;
```

## Emergency wraparound protection

Every table has a transaction "age" that PostgreSQL must reset with a freeze vacuum. Two limits matter:

- **`autovacuum_freeze_max_age`** (default 200 million): when a table crosses this, PostgreSQL launches its own mandatory anti-wraparound autovacuum. This is routine: it runs cost-throttled and quietly, and no outside help is needed.
- **~2.1 billion**: the hard ceiling. If a table ever gets here, the whole cluster stops accepting writes and needs hours of downtime.

The extension steps in only on **evidence that the built-in mechanism is failing**, judged from the built-in vacuum's own behavior. Two situations qualify:

- **It never started.** The table's age is 1.5× past the point where PostgreSQL should have launched a forced vacuum (`emergency_stall_multiplier` × `autovacuum_freeze_max_age`), and no vacuum is running on the table. If the built-in is 50% of its own trigger overdue, something is wrong with it (launcher stuck, workers permanently occupied elsewhere). An absolute cap (`emergency_xid_age`, default **1 billion**, about half the read-only ceiling) keeps this sane on clusters running a very large `autovacuum_freeze_max_age`.
- **It's running but will never make it.** A forced vacuum has been grinding on the table for a long time (`emergency_takeover_min_runtime_seconds`, default 1 hour), typically stuck in index cleanup, and either the age has kept climbing past the 1.5× line anyway, or its progress rate projects it finishing *after* the read-only cutoff at the cluster's measured transaction consumption rate. The extension then **cancels the doomed autovacuum and takes over** with the fast recipe below; the takeover typically finishes orders of magnitude faster precisely because it skips index cleanup. It never cancels a vacuum a human started.

It deliberately does **not** fire at a mere percentage of `autovacuum_freeze_max_age`: a manual vacuum ignores autovacuum's cost throttling, and firing it in territory the built-in vacuum handles anyway would just burn I/O and CPU for nothing. Separately, if `autovacuum_freeze_max_age` itself is set to something unreasonable (below 50 million or above 1.2 billion), the extension flags it in its advice; that setting needs a restart, so it is never changed automatically.

The emergency vacuum:

- targets **only** the at-risk table (TOAST included), never the whole database;
- runs **one at a time** across the whole cluster, worst table first, never a stampede;
- uses the fastest safe recipe: freeze everything, **skip index cleanup** (a later normal vacuum tidies the indexes), skip steps that need heavy locks;
- has its own memory and speed limits, and gives up on locks in seconds instead of hanging;
- recovers automatically if the process running it dies mid-way.

Enabled by default; if you prefer to evaluate without it first, switch it off as step 4 of the rollout.

You don't have to wait for the emergency to know something is wrong: `SELECT * FROM adaptive_autovacuum.wraparound_status;` shows every database's age, how many transactions of headroom remain before the read-only ceiling, and a plain `ok` / `watch` / `alarm` verdict (`watch` starts at half the emergency threshold, 500 million by default). Wire that column into your monitoring and you have the early-warning system without any of the automation.

## Upgrading and removing

**Upgrade / redeploy:** turn the launcher off (`adaptive_autovacuum.enabled = off`, reload) → let it restore managed tables (or accept the current values) → `DROP EXTENSION adaptive_autovacuum` in each database (this deletes its saved originals, hence restore *first*) → replace the files, restart if the `.so` changed → `CREATE EXTENSION` again and re-apply your policy.

**Remove:** same as above, then take `adaptive_autovacuum` out of `shared_preload_libraries` and restart. To undo applied cluster changes, every old value is in `global_apply_queue.old_value`.

## Testing

```bash
make installcheck PG_CONFIG=/usr/pgsql-18/bin/pg_config
```

CI builds and tests against PostgreSQL 18 on every push. `VALIDATION.md` records the hands-on validation: multi-round pgbench runs (15-36 K TPS mixed workloads against deliberately broken settings), insert-only tables detected within ~70 seconds, boosts ramping and respecting the cluster budget, an eight-setting cluster repair applied in one cycle, automatic restore after load stopped, and a live emergency-vacuum drill (transaction age 92,029 → 31).

## Good to know

- **PostgreSQL 17 or later**, built per major version. PostgreSQL 18 gets the full feature set; on 17 the extension detects the version at runtime and skips what the server cannot do:

  | On PostgreSQL 17 | Why | Behavior |
  |---|---|---|
  | `autovacuum_vacuum_max_threshold` (global and per-table) | the trigger cap is new in 18 | never recommended or set; trigger math uses the classic uncapped formula |
  | automatic `autovacuum_max_workers` raise | reloadable only since 18 (needs a restart on 17) | still recommended in `global_recommendations` with a "requires restart" note, never applied |
  | `autovacuum_worker_slots` cap on the worker advice | the GUC is new in 18 | recommendation bounded by policy limits only |
  | vacuum delay-time accounting | `pg_stat_progress_vacuum.delay_time` is new in 18 | delay-bound detection (one of three triggers for raising the cost limit) stays inactive; `active_vacuums.delay_time` is NULL. Host-pressure and overdue-backlog triggers work unchanged |
  | eager-freeze tuning on emergency vacuums | PG 18 feature | emergency VACUUM runs the same failsafe profile without it |

  Everything else (per-table triggers and cost boosts, insert-backlog policy, the other cluster-wide settings via `ALTER SYSTEM`, wraparound emergency protection, never-analyzed table detection) behaves identically on 17.
- **Windows is supported** (validated against PostgreSQL 18.4 and 17.6). Container memory limits (cgroups) are Linux-only; on Windows the overload check uses CPU busy %; see the Windows install notes.
- Cluster changes go into `postgresql.auto.conf`. If Ansible/Patroni/etc. owns your autovacuum settings, either point that tooling elsewhere or run with `manage_global_settings = false`.
- With many managed databases, each one may apply cluster changes; they converge on the same values, but audit rows land in whichever database acted.
- The policy tables reference tables by internal ID, so after a dump/restore re-apply your policy settings.
- Installation requires superuser; the workers run with superuser rights.
- Plain tables only (materialized views are not watched).
- It is a **reference implementation**: validated in lab conditions (see `VALIDATION.md`), not yet hardened by production mileage.

## License

[PostgreSQL License](LICENSE).
