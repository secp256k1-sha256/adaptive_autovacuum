# Troubleshooting

Start with one command; it is the same on both platforms and inside SQL:

```bash
sudo adaptive-autovacuum-setup doctor            # Linux
.\adaptive-autovacuum-setup.ps1 doctor           # Windows (elevated)
```

```sql
SELECT * FROM adaptive_autovacuum.doctor();      -- in any database with the extension
SELECT * FROM adaptive_autovacuum.status();      -- one row, machine readable
```

Attach `doctor --format json` output to bug reports. Statuses: `OK`, `WARN`, `FAIL`, `RESTART_REQUIRED`;
every non-OK row carries a remediation command.

## Check by check

| check | non-OK meaning | what to do |
|-------|----------------|------------|
| `library_preloaded` | `RESTART_REQUIRED`: the file lists the library, the running server does not. `FAIL`: not configured. | Restart the selected service, or rerun `adaptive-autovacuum-setup install`. |
| `config_file_errors` | `pg_file_settings` reports an error for `shared_preload_libraries` or `adaptive_autovacuum.*`. | Fix the reported line in `postgresql.auto.conf` / `postgresql.conf`. A common one after a manual `ALTER SYSTEM SET shared_preload_libraries = ''` is the value `'""'`, which stops the server from starting (`could not access file ""`): use `ALTER SYSTEM RESET shared_preload_libraries` or the helper's `remove-preload`. |
| `extension_version` | `WARN`: newer scripts on disk. `FAIL`: not created here, no control file visible, or objects newer than the files. | `ALTER EXTENSION adaptive_autovacuum UPDATE;` / `CREATE EXTENSION` / reinstall the package. |
| `launcher_enabled` | `adaptive_autovacuum.enabled = off`: nothing is managed. | `adaptive-autovacuum-setup enable`, or `ALTER SYSTEM SET adaptive_autovacuum.enabled = on; SELECT pg_reload_conf();` |
| `launcher_running` | Library preloaded but no `adaptive autovacuum launcher` in `pg_stat_activity`. | Check the server log for the launcher; `max_worker_processes` must leave room for the launcher plus `max_database_workers`; `adaptive_autovacuum.control_database` must exist and accept connections. |
| `policy` | `WARN`: paused (`enabled = false`) or watch-only (`dry_run = true`). | `SELECT adaptive_autovacuum.enable_default_policy();` when you want it active. Deliberate settings are fine. |
| `last_cycle` | No cycle yet (first one runs within `naptime_seconds`) or stale. | Wait a minute; if stale, look for a blocked database worker in the log (`database_worker_timeout_seconds`). |
| `cluster_evidence` | More managed databases than `max_tracked_databases`. | `ALTER SYSTEM SET adaptive_autovacuum.max_tracked_databases = <n>;` and restart. |
| `global_changes` | A cluster-setting change failed in the last 24 h. | `SELECT guc_name, desired_value, error FROM adaptive_autovacuum.global_apply_queue WHERE status = 'failed';` |
| `relation_errors` | A per-table action failed. | `SELECT decided_at, relation_name, action, error FROM adaptive_autovacuum.decisions WHERE error IS NOT NULL ORDER BY 1 DESC;` |
| `emergency_vacuum` | An emergency VACUUM is pending or running. | Expected under wraparound pressure; see `adaptive_autovacuum.emergency_queue`. |
| `wraparound` | A database passed half (`WARN`) or all (`FAIL`) of the emergency age. | `SELECT * FROM adaptive_autovacuum.wraparound_status; SELECT * FROM adaptive_autovacuum.horizon_blocker();` |
| `autovacuum` | `autovacuum = off`. | The controller repairs it after `repair_disabled_autovacuum_cycles` checks; or turn it on yourself. |
| `track_cost_delay_timing` | Off on PostgreSQL 18. | `ALTER SYSTEM SET track_cost_delay_timing = on; SELECT pg_reload_conf();` |
| `recovery` | Standby server. | Nothing; the launcher starts after promotion. |

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
`adaptive-autovacuum-setup install --database NAME` (it detects the preload and skips that step).

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

**`doctor` shows `doctor_api` WARN for a database.** That database still runs pre-1.1.0 extension objects.
`ALTER EXTENSION adaptive_autovacuum UPDATE;` upgrades a released 1.0.0; development snapshots built before
1.0.0 was frozen have no upgrade path and need `DROP EXTENSION` + `CREATE EXTENSION` (after restoring managed
tables, see the README).

## Removing everything

1. `adaptive-autovacuum-setup disable`
2. `adaptive-autovacuum-setup remove-preload` (restart)
3. remove the package (Linux) / `adaptive-autovacuum-setup.ps1 remove-files` (Windows)
4. per database, if wanted: `DROP EXTENSION adaptive_autovacuum;`
5. cluster settings the controller applied are listed with their previous values in
   `adaptive_autovacuum.global_apply_queue.old_value` before step 4.
