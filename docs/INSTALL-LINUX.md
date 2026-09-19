# Installing on Linux

Supported by the packaged installer: PostgreSQL 17 and 18 on Ubuntu 24.04 / 26.04 (amd64, arm64) and
RHEL / Rocky / AlmaLinux 9 (x86_64, aarch64). Other hosts can still build from source (see the README).

## Quick install

```bash
curl -fsSLO https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.sh
less install.sh
sudo bash install.sh --database mydb
```

`install.sh` is a small bootstrap. It

1. checks the host (distribution, architecture, present PostgreSQL majors) and refuses unsupported ones before changing anything;
   with both 17 and 18 installed it takes the one that is running, or requires `--pg-major N` when both run;
2. downloads `release-manifest.json` for the pinned release over HTTPS and validates every field;
3. selects exactly one package for this host, downloads it and compares its SHA-256 with the manifest;
4. installs two packages with `apt-get` or `dnf`, both files only: the extension package for the chosen major
   (library, control, SQL scripts) and the shared `adaptive-autovacuum-setup` package (the helper, one per host);
5. hands over to `adaptive-autovacuum-setup install`, which does everything that touches PostgreSQL.

Add `--yes` for unattended runs, `--check` to only discover and report, `--dry-run` to print the plan.
All other options are passed to the helper (see below). Offline: `--manifest FILE --artifact-dir DIR`.

## Activation model

The extension is created **per database** (`CREATE EXTENSION adaptive_autovacuum` in every database that
should be managed). The launcher connects to `adaptive_autovacuum.control_database` (default `postgres`)
only to list databases; that database does not need the extension. Databases without the extension are
skipped. Because of that the installer never activates all databases silently:

- `--database NAME` (repeatable) names the targets;
- `--all-databases` is the explicit "everything connectable and non-template";
- `--skip-create-extension` installs files and preload only;
- an interactive session without any of these shows a list to pick from;
- `template0`/`template1` are refused (`template1` would change every future database).

## What the helper does (`adaptive-autovacuum-setup install`)

```
Detected PostgreSQL:
  Version:          18.6
  Service:          postgresql-18.service
  Data directory:   /var/lib/pgsql/18/data
  Port:             5432  state: running  connection: socket as postgres
  Preload now:      ''

Plan:
  Extension files:  /usr/pgsql-18/lib/adaptive_autovacuum.so, /usr/pgsql-18/share/extension (1.1.0)
  Preload change:   '' -> 'adaptive_autovacuum'
  Restart:          yes (postgresql-18.service)
  Database:         mydb: CREATE EXTENSION adaptive_autovacuum (version 1.1.0)
  Enable controller: yes (adaptive_autovacuum.enabled = on, track_cost_delay_timing = on)

Continue? [Y/n]
```

Nothing has changed at that point. After confirmation:

- **Preload.** `shared_preload_libraries` is read with `SHOW`, parsed as an identifier list, and the new
  value is the old one with `adaptive_autovacuum` appended (`pg_stat_statements,auto_explain` becomes
  `pg_stat_statements,auto_explain,adaptive_autovacuum`). It is applied with `ALTER SYSTEM SET` through a
  psql variable, never by editing `postgresql.conf`. `postgresql.auto.conf` is backed up first and
  `pg_file_settings` is checked for errors afterwards.
- **Restart.** Only the selected service is restarted (`systemctl restart <unit>`, or `pg_ctl` as the
  cluster owner when there is no unit), after an explicit prompt (`--yes` accepts it, `--no-restart`
  defers it and leaves the run in state `restart_required`). The helper waits up to `--restart-timeout`
  (60 s) for connections. If the server does not come back, it prints the log excerpt, restores the
  backed-up `postgresql.auto.conf` (only if the file is still byte-identical to what it wrote), starts the
  service again and exits 8.
- **Activation.** Per database: `CREATE EXTENSION` when absent, `ALTER EXTENSION ... UPDATE` when an older
  version is installed (policy and history are preserved), nothing when current. It refuses to downgrade.
- **Enable.** `adaptive_autovacuum.enabled = on` (already the built-in default; set explicitly so an earlier `off` is undone) and, on PostgreSQL 18, `track_cost_delay_timing = on`
  via `ALTER SYSTEM` + `pg_reload_conf()`. `--no-enable` skips this step. A fresh `CREATE EXTENSION` already
  creates an active policy; upgrades never change operator values.
- **Verify.** Files, preload, launcher worker and `SELECT * FROM adaptive_autovacuum.doctor()` in every
  target database. Exit 10 if any check is `FAIL`.

Rerunning is safe: an unchanged installation verifies and exits 0; a pending restart is resumed.

## Discovery and selection

Evidence is collected from `pg_lsclusters` (Debian/Ubuntu), systemd units (`postgresql*`), running
`postgres` processes (`-D`, `/proc/<pid>/exe`), `pg_config` binaries in the usual locations, the data
directory (`PG_VERSION`, `postmaster.pid` for port and socket) and finally SQL over the local socket as the
cluster owner. Records are merged by canonical data directory. Selection:

- no supported candidate: exit 3 and a list of what was found;
- exactly one supported candidate, or exactly one *running* supported candidate: selected;
- otherwise an interactive menu, or exit 4 in non-interactive mode. Filters: `--service`, `--data-dir`,
  `--cluster 18/main`, `--port`, `--pg-config`, `--pg-major`.

A cluster of an unsupported major (16 and older) is listed as *unsupported major* and never selected. Two running supported
clusters (for example 17 and 18) are ambiguous: pass `--pg-major`, `--service` or `--port`.
A standby (in recovery) gets preload only; extension objects are created on the primary.

Externally managed configuration is refused before any change: Patroni, Kubernetes,
`allow_alter_system = off`.

## Authentication

Peer authentication over the local socket as the cluster OS owner is tried first (`runuser -u postgres psql`).
Otherwise a TCP connection to `localhost` as `--db-user` (default `postgres`); psql prompts in an interactive
session, or reads `--pgpassfile`. Passwords never appear on a command line or in logs.

## Other commands

```
sudo adaptive-autovacuum-setup check [--json]           # discovery only
sudo adaptive-autovacuum-setup doctor [--format json]   # health of every database with the extension
sudo adaptive-autovacuum-setup disable                  # controller off (GUC), nothing removed
sudo adaptive-autovacuum-setup enable
sudo adaptive-autovacuum-setup remove-preload           # keeps the other preload libraries; restart prompt
```

Journal: `/var/lib/adaptive-autovacuum/installer-state.json` (root only; previous values, steps, final state).
Log: `/var/log/adaptive-autovacuum/setup.log`.

## Package manager only

```bash
sudo dnf install ./adaptive-autovacuum-setup-1.1.0-1.el9.noarch.rpm ./postgresql18-adaptive-autovacuum-1.1.0-1.el9.x86_64.rpm   # postgresql17-... for PostgreSQL 17
sudo apt-get install ./adaptive-autovacuum-setup_1.1.0-1_all.deb ./postgresql-18-adaptive-autovacuum_1.1.0-1_ubuntu24.04_amd64.deb
sudo adaptive-autovacuum-setup install --database mydb
```

The extension packages depend on `adaptive-autovacuum-setup`, so both majors can be installed side by side and share
one helper. The packages install files only. They never restart PostgreSQL, edit its configuration, run
`CREATE EXTENSION`, or drop extension objects on removal.

## Uninstall

1. `sudo adaptive-autovacuum-setup disable` (controller off, everything else stays)
2. `sudo adaptive-autovacuum-setup remove-preload` (restart; other libraries preserved)
3. `sudo dnf remove postgresql<major>-adaptive-autovacuum` / `sudo apt-get remove postgresql-<major>-adaptive-autovacuum`
4. Optional and destructive, per database: `DROP EXTENSION adaptive_autovacuum;` (deletes policy and history)

## Exit codes

| code | meaning |
|-----:|---------|
| 0 | success / healthy |
| 2 | invalid arguments or cancelled |
| 3 | no supported PostgreSQL found |
| 4 | ambiguous discovery; selection required |
| 5 | unsupported platform, version or managed configuration |
| 6 | download or integrity failure |
| 7 | insufficient OS or PostgreSQL privileges |
| 8 | configuration failure, rollback completed |
| 9 | restart failure, rollback not possible |
| 10 | activation or health check failed |
