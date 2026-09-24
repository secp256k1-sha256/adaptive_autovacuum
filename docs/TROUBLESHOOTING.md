# Troubleshooting

Start with one command; it is the same on both platforms and inside SQL:

```bash
sudo adaptive-autovacuum-setup doctor            # Linux
.\adaptive-autovacuum-setup.ps1 doctor           # Windows (elevated)
```

```sql
SELECT * FROM adaptive_autovacuum.doctor();      -- in the control database (postgres by default)
SELECT * FROM adaptive_autovacuum.status();      -- one row for the whole cluster, machine readable
```

The extension lives in one database per cluster, the control database (`adaptive_autovacuum.control_database`,
default `postgres`), and manages every other connectable database from there; run the SQL checks in that database.
Attach `doctor --format json` output to bug reports. Statuses: `OK`, `WARN`, `FAIL`, `RESTART_REQUIRED`;
every non-OK row carries a remediation command.

## Check by check

| check | non-OK meaning | what to do |
|-------|----------------|------------|
| `library_preloaded` | `RESTART_REQUIRED`: the file lists the library, the running server does not. `FAIL`: not configured. | Restart the selected service, or rerun `adaptive-autovacuum-setup install`. |
| `config_file_errors` | `pg_file_settings` reports an error for `shared_preload_libraries` or `adaptive_autovacuum.*`. | Fix the reported line in `postgresql.auto.conf` / `postgresql.conf`. A common one after a manual `ALTER SYSTEM SET shared_preload_libraries = ''` is the value `'""'`, which stops the server from starting (`could not access file ""`): use `ALTER SYSTEM RESET shared_preload_libraries` or the helper's `remove-preload`. |
| `extension_version` | `WARN`: newer scripts on disk. `FAIL`: not created here, no control file visible, or objects newer than the files. | `ALTER EXTENSION adaptive_autovacuum UPDATE;` / `CREATE EXTENSION` in the control database / reinstall the package. There is no upgrade script from 1.1.0, see below. |
| `control_database` | `FAIL`: the extension is created in this database, but the control database is another one; the objects here are ignored. | Install once in the control database and `DROP EXTENSION adaptive_autovacuum;` here, or `ALTER SYSTEM SET adaptive_autovacuum.control_database = '<this database>'; SELECT pg_reload_conf();`. |
| `launcher_enabled` | `adaptive_autovacuum.enabled = off`: nothing is managed. | `adaptive-autovacuum-setup enable`, or `ALTER SYSTEM SET adaptive_autovacuum.enabled = on; SELECT pg_reload_conf();` |
| `launcher_running` | Library preloaded but no `adaptive autovacuum launcher` in `pg_stat_activity`. | Check the server log for the launcher; `max_worker_processes` must leave room for the launcher, the controller, `max_database_workers` database workers and one emergency worker. |
| `controller_running` | `FAIL`: the launcher runs but no `adaptive autovacuum controller` is connected; the detail shows `controller_state` (`waiting for control database`, `waiting for CREATE EXTENSION in the control database`, `restarting after exit`, `waiting for a background worker slot`). `WARN`: not expected to run (library, switch or recovery). | See "Control database problems" below; check the server log for "adaptive autovacuum controller". |
| `policy` | `WARN`: paused (`enabled = false`) or watch-only (`dry_run = true`) for the whole cluster. | `SELECT adaptive_autovacuum.enable_default_policy();` when you want it active. Deliberate settings are fine. |
| `last_sweep` | No sweep yet (the first one runs within `naptime_seconds` of the controller start) or stale (older than `max(3 × naptime, 600 s, 3 × observed sweep)`). | Wait a minute; if stale, look for a blocked database worker in the log (`database_worker_timeout_seconds`) or a controller that keeps restarting. |
| `cluster_evidence` | `WARN`: a database failed its last scan, or was not revisited within the freshness window. Cluster-wide changes are recorded but not applied until every non-excluded database is scanned. | `SELECT database_name, status, stale, last_error FROM adaptive_autovacuum.database_status WHERE status = 'failed' OR stale;` then fix the database or exclude it: `UPDATE adaptive_autovacuum.policy SET excluded_databases = excluded_databases || '<name>';` |
| `duplicate_installations` | `WARN`: the extension is also created in other databases; those copies are ignored. | `DROP EXTENSION adaptive_autovacuum;` in each of them. |
| `global_changes` | A cluster-setting change failed in the last 24 h. | `SELECT guc_name, desired_value, error FROM adaptive_autovacuum.global_apply_queue WHERE status = 'failed';` |
| `relation_errors` | A per-table action failed. | `SELECT decided_at, database_name, relation_name, action, error FROM adaptive_autovacuum.decisions WHERE error IS NOT NULL ORDER BY 1 DESC;` |
| `emergency_vacuum` | An emergency VACUUM is pending or running. | Expected under wraparound pressure; see `adaptive_autovacuum.emergency_queue` (`database_name`, `relation_name`, `status`). |
| `wraparound` | A database passed half (`WARN`) or all (`FAIL`) of the emergency age. | `SELECT * FROM adaptive_autovacuum.wraparound_status; SELECT * FROM adaptive_autovacuum.horizon_blocker();` `aging_tables` lists the ten oldest tables (TOAST age included) of the database you query it in. |
| `autovacuum` | `autovacuum = off`. | The controller repairs it after `repair_disabled_autovacuum_cycles` sweeps; or turn it on yourself. |
| `track_cost_delay_timing` | Off on PostgreSQL 18. | `ALTER SYSTEM SET track_cost_delay_timing = on; SELECT pg_reload_conf();` |
| `recovery` | Standby server. | Nothing; the launcher and controller start after promotion. |

## Control database problems

**`controller_state = waiting for control database`.** The launcher could not find `adaptive_autovacuum.control_database`
in `pg_database`, or it is a template, or it has `datallowconn = false`. The server log shows
`adaptive autovacuum control database "..." does not exist; the controller is not started (retry in N s)`; the retry
backs off from 10 s to 600 s. Create the database, or
`ALTER SYSTEM SET adaptive_autovacuum.control_database = 'existing_db'; SELECT pg_reload_conf();`. The launcher picks
the new value up at its next retry.

**`controller_state = waiting for CREATE EXTENSION in the control database`.** The controller is connected but the
1.2.0 objects are missing there. Run `CREATE EXTENSION adaptive_autovacuum;` in that database; the controller logs one
WARNING per ten iterations until you do. If you created the extension in another database by mistake, `CREATE EXTENSION`
warned that the database is not the control database, `doctor()` there shows `control_database` FAIL, and the control
database shows `duplicate_installations`; drop that copy.

**`controller_state = restarting after exit`.** The controller hit an error and the launcher is backing off. Look for
`adaptive autovacuum sweep failed: ...` and `adaptive autovacuum controller exited` in the server log; the backoff
resets once the restarted controller completes a sweep.

**`controller_state = waiting for a background worker slot`.** Registering the dynamic worker failed. Raise
`max_worker_processes` (restart): launcher + controller + `max_database_workers` + one emergency worker, plus whatever
other extensions and parallel query need.

**Databases that never show up.** `SELECT * FROM adaptive_autovacuum.database_status;` lists every connectable,
non-template database with its status (`pending`, `healthy`, `backlog`, `emergency`, `failed`, `excluded`). A database
missing from the list has `datallowconn = false` or `datistemplate = true`. `excluded` comes from
`policy.included_databases` / `excluded_databases` (LIKE patterns).

**A database stays `failed`.** `database_status.last_error` holds the worker's message: an error from the program
(the database's own catalogs, a permission problem), `worker exited without a result (crash, timeout or connection
failure)`, or the timeout. While it stays failed, `cluster_evidence` is WARN and no cluster setting is applied. Exclude
the database if it should not be managed.

## Handoff files

Workers and the controller exchange documents through `pg_stat_tmp/adaptive_autovacuum/` under the data directory:
`program.sql` (the database program, rewritten each sweep), `<dboid>.in` / `<dboid>.out` (one pair per database scan,
deleted once absorbed) and `emergency_<id>.out` (one per emergency request). They are excluded from base backups and
removed at server start; leftovers after a crash are harmless and overwritten by the next sweep. If the log shows
`adaptive autovacuum could not create` / `could not write` for that path, check permissions and free space of the
data directory.

## Reading `status()`

| column | meaning |
|--------|---------|
| `control_database`, `is_control_database` | configured control database, and whether you are querying it; the other columns are meaningful only there |
| `launcher_running`, `controller_running`, `controller_state` | processes in `pg_stat_activity`, and the controller's state text from shared memory |
| `cluster_generation`, `last_complete_generation` | sweep counter, and the last sweep in which every non-excluded database was scanned; when they drift apart a database keeps failing |
| `last_sweep_started_at`, `last_sweep_completed_at`, `seconds_since_last_sweep`, `sweep_seconds` | sweep timing and the sweep-duration EMA |
| `managed_databases`, `excluded_databases`, `failed_databases`, `stale_databases` | discovered databases by status; stale = not revisited within `max(10 × naptime, 3 × sweep_seconds)` |
| `tables_seen`, `tables_needing_vacuum`, `tables_emergency` | sums over the managed databases' latest scans |
| `maintenance_debt_tuples`, `maintenance_debt_velocity`, `backlog_trend` | cluster dead + inserted-since-vacuum tuples, its smoothed rate, and the trend the cost loop acts on |
| `autovacuum_workers_running`, `autovacuum_max_workers`, `cost_limit`, `cost_delay_ms` | live autovacuum capacity and cost pair |
| `pending_global_changes`, `failed_global_changes_24h`, `relation_errors_24h`, `active_emergencies`, `wraparound_status` | queue, error and emergency state |

## Installer problems

**`no supported PostgreSQL cluster` (exit 3).** The helper lists what it found. PostgreSQL 16 and older are not
supported by the extension (it needs 17 or later). A stopped cluster is not selectable for `install`; start it first.

**`ambiguous discovery` (exit 4).** Several supported clusters run. Pass `--service NAME`, `--data-dir PATH`,
`--cluster 18/main`, `--port N` (Linux) or `-ServiceName`, `-DataDirectory`, `-PgRoot`, `-Port` (Windows).

**`could not connect` (exit 7).** Linux: peer authentication for the cluster owner failed and no TCP
credentials were given; pass `--db-user postgres --pgpassfile /root/.pgpass` or fix `pg_hba.conf`.
Windows: pass `-Credential (Get-Credential postgres)` or `-PgPassFile`.

**`allow_alter_system = off`, Patroni, Kubernetes (exit 5).** The configuration is managed elsewhere. Add
`adaptive_autovacuum` to `shared_preload_libraries` in that system, restart through it, then run
`adaptive-autovacuum-setup install --database <control database>` (it detects the preload and skips that step).

**Restart failed, rolled back (exit 8).** The server did not accept connections within `--restart-timeout`
after the restart. The helper printed the log excerpt, restored `postgresql.auto.conf`, restarted, and the
server runs without the extension. Typical causes: a library built for another PostgreSQL major or
architecture (`could not load library ... wrong ELF class`, `file too short`), or `max_worker_processes`
exhausted. Fix, then rerun.

**Restart failed, rollback not possible (exit 9).** `postgresql.auto.conf` changed after the installer wrote
it (a concurrent administrator change), so it was not overwritten. The message names the backup file to
restore by hand; then start the service.

**Windows: `ERROR: run this from an elevated (Administrator) PowerShell` (exit 7).** Reopen PowerShell as
Administrator.

**Windows: old `adaptive_autovacuum.dll.old-<runid>` files in `lib\`.** A DLL that was in use was renamed
aside; the installer deletes it after the restart. If the restart was deferred, delete it after the next one.

**Rerun after an interruption.** The journal (`installer-state.json`) records every completed step and the
previous values; the helper warns about an `interrupted` or `failed` previous run and re-verifies the real
host state before each step, so simply rerun the same command.

**Upgrading from 1.1.0.** 1.2.0 has no upgrade script: the extension changed from one installation per database to
one per cluster. In every database that has the 1.1.0 objects, note `changed_tables` and
`global_apply_queue.old_value`, restore what you do not want to keep, then `DROP EXTENSION adaptive_autovacuum;`.
Then `CREATE EXTENSION adaptive_autovacuum;` once, in the control database. Policy edits do not carry over; re-apply
them to the cluster policy and re-create `table_policy` rows with `database_name`, `schema_name`, `relation_name`.

## Removing everything

1. `adaptive-autovacuum-setup disable`
2. `adaptive-autovacuum-setup remove-preload` (restart)
3. remove the package (Linux) / `adaptive-autovacuum-setup.ps1 remove-files` (Windows)
4. in the control database, if wanted: `DROP EXTENSION adaptive_autovacuum;` (and in any database that still holds
   a stale copy)
5. cluster settings the controller applied are listed with their previous values in
   `adaptive_autovacuum.global_apply_queue.old_value`, and table options it still holds in
   `adaptive_autovacuum.changed_tables`, before step 4.
