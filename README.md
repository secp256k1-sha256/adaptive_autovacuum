# 🐘 adaptive_autovacuum

### PostgreSQL autovacuum that tunes itself.

**For PostgreSQL 17 & 18 · Full feature set on PostgreSQL 18**

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17%20%7C%2018-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/License-PostgreSQL-blue)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Beta-orange)](VALIDATION.md)
[![Language](https://img.shields.io/badge/C%20%2B%20PL%2FpgSQL-555555)](src/)

> **⚠️ Beta: testing in progress.** Functionally tested on Linux and Windows (PostgreSQL 17.6, 17.11, 18.4 and 18.6), including regression tests, standby and emergency-vacuum drills, and ~20,000 TPS pgbench workloads. Sustained production-scale validation is still pending. Include `SELECT * FROM adaptive_autovacuum.doctor();` when reporting an issue.



## ⚡ Quick install

No compiler or manual file copying. Review the installer, then run it.

**🐧 Linux** · Ubuntu 24.04 / 26.04, Debian 12 / 13, RHEL / Rocky / AlmaLinux 9 / 10

```bash
curl -fsSLO https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.sh
less install.sh
sudo bash install.sh
```

**🪟 Windows** · EDB PostgreSQL 17 or 18 x64, elevated PowerShell

```powershell
Invoke-WebRequest https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
.\install.ps1 -Credential (Get-Credential postgres)
```
**🗄️ Install once in the control database. Automatically manage the entire PostgreSQL cluster.**

The installer selects the PostgreSQL cluster, verifies downloads, installs the extension, preserves existing preload libraries, asks before restarting, enables the controller and reports its health. PostgreSQL must already be installed. `--control-database NAME` / `-ControlDatabase NAME` picks a control database other than `postgres`.

**🩺 Check health anytime:** `SELECT * FROM adaptive_autovacuum.doctor();` or `sudo adaptive-autovacuum-setup doctor` (Windows: `adaptive-autovacuum-setup.ps1 doctor`).

[Packages & manual installation](#-installation) · [Monitoring](#-monitoring) · [Configuration](#-configuration)

---

## 💡 The DBA who isn't there

PostgreSQL's conservative autovacuum defaults are a starting point, not a maintenance strategy. As workloads grow, dead tuples accumulate, tables outgrow percentage-based thresholds, workers become saturated and critical freeze work can fall behind.

But many databases have **no dedicated DBA**: startups, small teams, solo developers and AI-built applications may operate hundreds or thousands of databases on one host.

`adaptive_autovacuum` is a cluster-wide controller for those environments. It watches maintenance debt, adjusts PostgreSQL's allowed settings, gives exceptional tables temporary help and records its decisions. **When the database is healthy, it should have little to do.**

## 🧰 What it does

| | Capability | Response |
|:--:|---|---|
| 🧹 | **Keep vacuum ahead** | Tracks dead-tuple and insert backlogs; adjusts vacuum thresholds and cost settings. |
| 👷 | **Scale worker capacity** | Recommends more autovacuum workers and applies increases on PostgreSQL 18. |
| 🔥 | **Help hot tables** | Applies temporary table-level tuning when cluster defaults are not enough. |
| 📊 | **Repair missing statistics** | Runs `ANALYZE` on eligible tables that have never been analyzed. |
| 🖥️ | **Respect host capacity** | Considers CPU, memory, active vacuum work and optional WAL-rate pressure before increasing normal maintenance. |
| 🚨 | **Protect against wraparound** | Detects dangerous XID/MXID conditions and intervenes when built-in protection is demonstrably failing. |
| ♻️ | **Clean up after itself** | Gradually unwinds incident cost tuning and tells you when an applied table boost can be reverted. |
| 🔎 | **Explain every decision** | Exposes cluster status, actions, previous values, table recommendations with ready-to-run SQL, and errors through SQL. |

> 🎯 **The goal:** keep maintenance debt under control, use spare host capacity when needed and intervene before neglected vacuum work becomes an outage, not chase a benchmark score.

### 🛡️ Guardrails

- **Evidence before action.** Global changes require a complete, successful cluster sweep; incomplete evidence produces advice, not an automatic change.
- **Bounded tuning.** Changes use an allow-list, policy ceilings and available resource signals. CPU count is not a direct ceiling on worker recommendations.
- **Table settings stay yours.** The controller never runs `ALTER TABLE`. Per-table trigger and cost changes are recommendations with ready-to-run SQL in `table_recommendations`, and a recommendation never loosens a trigger you set. It never edits table data.
- **Separate emergency path.** An anti-wraparound vacuum making progress is not cancelled; human-started vacuums are never takeover targets.
- **Reversible.** Global changes and their prior values are audited; every table recommendation carries the SQL that reverts it.

## 🧭 Contents

- [⚙️ How it decides](#️-how-it-decides)
- [📦 Installation](#-installation)
- [📈 Monitoring](#-monitoring)
- [🎛️ Operating the controller](#️-operating-the-controller)
- [🔧 Configuration](#-configuration)
- [🚨 Emergency protection](#-emergency-protection)
- [🔄 Upgrade and removal](#-upgrade-and-removal)
- [🧪 Testing and documentation](#-testing-and-documentation)

---

## ⚙️ How it decides

One controller in the **control database** (`postgres` by default) discovers all eligible databases and scans them in sweep generations. Up to two database workers run concurrently by default. The controller collects central state, makes one global decision and applies all queued settings in one `ALTER SYSTEM` step per complete sweep. It sleeps for 60 seconds after a sweep; the revisit interval also includes scan time.

| Decision | Evidence and limits |
|---|---|
| 🧹 Raise vacuum cost budget | Backlog trend, estimated drain time, host pressure and activity gained after earlier raises. |
| 👷 Add workers | A busy pool or an overdue queue longer than the pool, debt trend, memory and storage pressure (CPU load alone does not block: workers share one cost budget), policy ceiling and PG18 worker slots. PostgreSQL 17 gets advice only. |
| ⏱️ Shorten the launcher interval | Core starts one worker per database per `autovacuum_naptime`, so a raised pool stays empty until the interval follows: halved per check while overdue relations wait and the pool is under-filled (floor 5 s), walked back up with the cost pair. |
| 🧠 Adjust memory / buffer ring | Active maintenance, available memory, repeated index passes and bounded recommendations. |
| 🎯 Tighten triggers | Widespread overdue tables justify cluster-wide changes and silence per-table advice; individual outliers get a table-level recommendation (threshold and scale factor together, never looser than today). |
| 📊 Analyze missing statistics | Eligible live tables with no recorded `ANALYZE`, largest first, within a per-database scheduling budget. |
| ♻️ Unwind incident tuning | Ten backlog-free sweeps before decaying cluster cost tuning; an applied table cost boost gets a revert recommendation after six healthy checks. Worker counts are not lowered automatically. |
| 🔧 Repair `autovacuum = off` | Turned back on before anything else: at the start of every sweep and on every configuration reload. |

Every table counts whatever its size (`min_table_bytes` defaults to 0; a small hot table hurts as much as a large one). A table recommendation needs two consecutive overdue checks, and at most two cost-boost recommendations stand at once cluster-wide (`max_boosted_relations`).

A failed or timed-out database makes the sweep's global evidence incomplete: its recommendation is recorded, but not applied. Database workers collect evidence, run `ANALYZE` on never-analyzed tables and produce table recommendations; only the central controller changes cluster GUCs, and nothing changes table settings. `autovacuum_freeze_max_age` remains advice-only.

**Cost-feedback detail:** the 3,200 MiB/s default theoretical cost ceiling is not a disk-bandwidth measurement. `vacuum_activity_rate` (vacuum cost units per second, derived from autovacuum-worker `pg_stat_io` activity and the vacuum cost weights) is compared with `cost_budget_rate`, the units per second the live cost pair allows. A raise must deliver the configured activity gain (10% by default) before the next raise. `latest_global_recommendation` also shows the worker I/O as `vacuum_read_mbps` and `vacuum_write_mbps`.

## 📦 Installation

The [Quick install](#-quick-install) scripts are the simplest path. For manual or offline installs, choose the matching binaries from [Releases](https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest) and verify them against `SHA256SUMS`.

| Platform | Package |
|---|---|
| 🐧 Ubuntu 24.04 / 26.04, Debian 12 / 13 | DEB per release, amd64 / arm64; extension and shared setup helper |
| 🐧 RHEL / Rocky / AlmaLinux / Oracle Linux 9 and 10 | one `el9` / `el10` RPM serves every clone of that major, x86_64 / aarch64; extension and shared setup helper |
| 🪟 Windows, EDB-style | PostgreSQL-major-specific x64 ZIP with setup helper |

<details>
<summary><strong>🐧 Ubuntu 24.04 amd64 · PostgreSQL 18 (DEB; Debian 13: use the `_debian13_` file)</strong></summary>

```bash
U=https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download
curl -fsSLO $U/adaptive-autovacuum-setup_1.3.0-1_all.deb
curl -fsSLO $U/postgresql-18-adaptive-autovacuum_1.3.0-1_ubuntu24.04_amd64.deb
sudo apt-get install ./adaptive-autovacuum-setup_1.3.0-1_all.deb ./postgresql-18-adaptive-autovacuum_1.3.0-1_ubuntu24.04_amd64.deb
sudo adaptive-autovacuum-setup install
```

</details>

<details>
<summary><strong>🐧 EL9 x86_64 · PostgreSQL 18 (RPM; EL10: use the `.el10.` files)</strong></summary>

```bash
U=https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download
curl -fsSLO $U/adaptive-autovacuum-setup-1.3.0-1.el9.noarch.rpm
curl -fsSLO $U/postgresql18-adaptive-autovacuum-1.3.0-1.el9.x86_64.rpm
sudo dnf install ./adaptive-autovacuum-setup-1.3.0-1.el9.noarch.rpm ./postgresql18-adaptive-autovacuum-1.3.0-1.el9.x86_64.rpm
sudo adaptive-autovacuum-setup install
```

</details>

<details>
<summary><strong>🪟 Windows · PostgreSQL 18 (ZIP)</strong></summary>

```powershell
$U = 'https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download'
Invoke-WebRequest "$U/adaptive_autovacuum-1.3.0-pg18-windows-x64.zip" -OutFile aav.zip
Expand-Archive aav.zip -DestinationPath aav
.\aav\adaptive-autovacuum-setup.ps1 install -SourceDir (Resolve-Path .\aav).Path -Credential (Get-Credential postgres)
```

</details>

<details>
<summary><strong>🛠️ Build from source</strong></summary>

Install the compiler and PostgreSQL server development files for your major version. Debian/Ubuntu:

```bash
make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
sudo make install PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

PGDG RPM installations usually use `/usr/pgsql-18/bin/pg_config`. Windows (x64 Visual Studio developer prompt):

```bat
windows\build_windows.bat "C:\Program Files\PostgreSQL\18"
```

`packaging\windows\build-zip.ps1 -PgMajor 18` packages a Windows build. For manual activation, append the library to `shared_preload_libraries`, restart, then run `CREATE EXTENSION adaptive_autovacuum;` **once in the control database**. Set any explicit `off` settings to `on` if you want automation.

The current `sql/adaptive_autovacuum--1.3.0.sql` is assembled from `sql/parts/01_schema.sql`, `02_program.sql`, `03_control_plane.sql` and `04_views_api.sql` using `bash sql/assemble.sh`; contributors should edit the parts and commit both.

</details>

See [Linux setup](docs/INSTALL-LINUX.md), [Windows setup](docs/INSTALL-WINDOWS.md), [troubleshooting](docs/TROUBLESHOOTING.md) and [installer security](docs/INSTALLER-SECURITY.md) for authentication, offline deployment and diagnostics.

## 📈 Monitoring

Run these in the **control database**:

```sql
SELECT * FROM adaptive_autovacuum.doctor();
SELECT * FROM adaptive_autovacuum.status();
```

`doctor()` runs 19 installation and runtime checks with `OK`, `WARN`, `FAIL` and `RESTART_REQUIRED` results. `status()` summarizes cluster-wide health, current sweep, database coverage, maintenance debt, active workers, cost settings and emergency state. Both are available to `pg_monitor`.

| Need | SQL |
|---|---|
| 🗄️ Database health | `SELECT * FROM adaptive_autovacuum.database_status;` |
| 🔍 Table health | `SELECT * FROM adaptive_autovacuum.table_status;` |
| 🧾 Recent actions | `SELECT * FROM adaptive_autovacuum.actions LIMIT 50;` |
| 💡 Table recommendations (SQL to run and to revert) | `SELECT * FROM adaptive_autovacuum.table_recommendations;` |
| ⚙️ Global changes and original values | `SELECT * FROM adaptive_autovacuum.global_apply_queue ORDER BY id DESC;` |
| 💡 Latest advice | `SELECT * FROM adaptive_autovacuum.latest_global_recommendation;` |
| 📝 Decisions and errors | `SELECT * FROM adaptive_autovacuum.decisions ORDER BY id DESC LIMIT 50;` |
| ⏳ Aging tables (of the database you query) | `SELECT * FROM adaptive_autovacuum.aging_tables;` |
| 🚨 Wraparound status | `SELECT * FROM adaptive_autovacuum.wraparound_status;` |
| 🔒 Cleanup-horizon blockers | `SELECT * FROM adaptive_autovacuum.horizon_blocker();` |
| 👷 Controller/sweep progress | `SELECT * FROM adaptive_autovacuum.controller_status();` |

Shell diagnostics: `sudo adaptive-autovacuum-setup doctor` or, on Windows, `adaptive-autovacuum-setup.ps1 doctor`. Use `--format json` / `-Format json` for automation.

## 🎛️ Operating the controller

Fresh installations start with `enabled = true`, `dry_run = false`, `manage_global_settings = true` and emergency protection enabled. Table settings are never written: `table_recommendations` lists the SQL to run in the table's database and the SQL to revert it. **No policy update is needed for normal operation.**

```sql
-- Table recommendations waiting for you, with the statement to run in that database
SELECT database_name, relation_name, recommendation_status, apply_sql, revert_sql, reason
FROM adaptive_autovacuum.table_recommendations;
```

```sql
-- Pause / resume cluster automation
UPDATE adaptive_autovacuum.policy SET enabled = false;
UPDATE adaptive_autovacuum.policy SET enabled = true;

-- Exclude databases matching a LIKE pattern
UPDATE adaptive_autovacuum.policy
SET excluded_databases = excluded_databases || 'reporting_%';

-- Observe without applying / return to active tuning
UPDATE adaptive_autovacuum.policy SET dry_run = true;
UPDATE adaptive_autovacuum.policy SET dry_run = false;
```

Alternatively, `sudo adaptive-autovacuum-setup disable` / `enable`, or change the cluster switch:

```sql
ALTER SYSTEM SET adaptive_autovacuum.enabled = off; -- on to resume
SELECT pg_reload_conf();
```

Pausing does **not** undo existing tuning or immediately cancel running maintenance. For an observation-only rollout, disable the cluster switch before preloading, create the extension, set `dry_run = true`, then enable the switch. The installer option `--no-enable` preserves an explicit `off` setting; it does not turn off an already-enabled controller.

## 🔧 Configuration

Defaults are designed for unattended operation. Adjust only what your workload requires.

| Setting | Default | Purpose |
|---|---:|---|
| `adaptive_autovacuum.control_database` | `postgres` | Central extension installation and state. |
| `adaptive_autovacuum.naptime_seconds` | `60` | Sleep after a complete sweep. |
| `adaptive_autovacuum.max_database_workers` | `2` | Concurrent database workers, separate from autovacuum workers. |
| `adaptive_autovacuum.database_worker_timeout_seconds` | `3600` | Maximum time for one database scan. |
| `adaptive_autovacuum.emergency_timeout_seconds` | `86400` | Emergency VACUUM runtime; `0` means unlimited. |
| `policy.included_databases` | `NULL` | All connectable non-template databases, unless filtered. |
| `policy.excluded_databases` | `{}` | LIKE patterns excluded from normal management. |
| `policy.recommendation_workers_max` | `16` | Recommended autovacuum-worker ceiling. |
| `policy.manage_naptime` | `true` | Ramp `autovacuum_naptime` down while the pool is under-filled, back up after recovery. |
| `policy.naptime_min_seconds` | `5` | Floor of the managed `autovacuum_naptime`. |
| `policy.manage_global_settings` | `true` | Apply global advice instead of only recording it. |
| `policy.recommend_table_costs` | `true` | Include a tiered cost boost in table recommendations. |
| `policy.max_boosted_relations` | `2` | Cost-boost recommendations standing at once, cluster-wide. |
| `policy.min_table_bytes` | `0` | Size floor for table scoring; `0` scores every table. |
| `policy.target_dead_tuple_min` | `1000` | Floor of the per-table dead-tuple target (1% of rows otherwise). |
| `policy.cost_raise_min_activity_gain_percent` | `10` | Required activity gain before another cost raise. |
| `policy.high_wal_mbps` | `0` | Optional WAL-rate pressure guardrail; `0` disables it. |

`policy.*` entries are columns in `adaptive_autovacuum.policy`, **not** GUCs. Reserve `max_worker_processes` slots for the launcher, controller, database workers and one emergency worker (five with defaults), in addition to other extensions and parallel queries.

**🗄️ Large clusters:** central state lives in ordinary tables, not a fixed-size shared-memory summary. All eligible databases are discovered automatically; more databases lengthen a sweep. Increase `max_database_workers` or exclude databases when needed. `database_status.stale` uses sweep-aware thresholds rather than assuming every database is revisited once per minute.

**🪟 Windows:** CPU pressure is measured as busy fraction rather than Unix load average. To engage the CPU gate near 85% busy:

```sql
UPDATE adaptive_autovacuum.policy SET high_load_per_cpu = 0.85;
```

### 🎯 Table-specific policies

Policies are centrally keyed by **database, schema and relation name**. Exclude a table:

```sql
INSERT INTO adaptive_autovacuum.table_policy (database_name, schema_name, relation_name, enabled, note)
VALUES ('mydb', 'app', 'audit_archive', false, 'Managed manually')
ON CONFLICT (database_name, schema_name, relation_name) DO UPDATE SET enabled = false;
```

Give a hot table a tighter dead-tuple target:

```sql
INSERT INTO adaptive_autovacuum.table_policy (database_name, schema_name, relation_name, target_dead_tuple_ratio, note)
VALUES ('mydb', 'app', 'orders', 0.005, 'Tighter maintenance target')
ON CONFLICT (database_name, schema_name, relation_name) DO UPDATE SET target_dead_tuple_ratio = 0.005;
```

Name-based policies survive OID changes; update `relation_name` after renaming a table. A policy can apply when its named relation is created later.

## 🚨 Emergency protection

Enabled by default, this is a **last-resort** path for anti-wraparound failure, not a shortcut around healthy PostgreSQL vacuums.

| Condition | Response |
|---|---|
| 🛑 Forced vacuum never started | Escalates at the configured dangerous XID/MXID age (default failure multiplier `1.5×`, emergency age cap 1 billion). |
| ⏸️ Forced vacuum appears stalled | Requires dangerous age, at least one hour of runtime and five unchanged progress samples before takeover. |
| 🔒 Cleanup horizon is blocked | Reports the blocker and holds XID escalation; independent MXID danger can still qualify. |

It never takes over a human-started vacuum or one showing progress. A dedicated emergency worker handles **one cluster-wide request at a time**, independently of routine sweeps, with its own timeout, memory and cost settings, short lock timeout and retry backoff. It prioritizes freezing and skips index cleanup.

The extension does not remove old transactions, prepared transactions or replication slots. Disable emergency intervention in the control database if required:

```sql
UPDATE adaptive_autovacuum.policy SET emergency_vacuum_enabled = false;
```

## 🧩 Compatibility and operational notes

| Area | What to know |
|---|---|
| PostgreSQL 17 / 18 | Both support cost tuning, triggers, missing-statistics repair and emergency protection. Binaries are major-specific. |
| PostgreSQL 18 | Adds reloadable worker increases, maximum vacuum thresholds, delay timing and emergency eager-freeze tuning. PG17 worker increases are advice-only. |
| Cluster scope | Install the extension in one control database. Global setting changes affect every database; exclusions prevent scanning and table recommendations. |
| Standbys | Automation waits for a writable primary. Keep binaries and settings consistent through HA tooling. |
| Config managers | Coordinate with Patroni/operators; setup rejects detected managed environments. |
| Privileges | Installation and workers require superuser privileges; selected health APIs permit `pg_monitor`. |
| Durability | `decisions` and `global_recommendations` are UNLOGGED history; policy, controller state and rollback information remain durable. |
| Scope | Normal policy monitors ordinary tables, not materialized views. |

## 🔄 Upgrade and removal

Upgrade the package/files for your PostgreSQL major, restart when replacing the preloaded library, then update **only the control database**:

```sql
ALTER EXTENSION adaptive_autovacuum UPDATE;
```

**1.2.0 → 1.3.0** upgrades in place. Table options that 1.2.0 set automatically stay as they are (they are tighter triggers); `actions` lists each as `legacy_table_settings` with the SQL that restores the previous values. From 1.3.0 the extension only recommends table settings.

**⚠️ Beta migration:** 1.1.0 → 1.2.0 has no in-place upgrade path because it moves from per-database copies to a single cluster control plane. The installer plans a confirmed drop/recreate in the control database. Review 1.1.0's `changed_tables` and `global_apply_queue.old_value` first, and reapply your policy changes afterwards. Remove stale 1.1.0 copies from other databases separately; `doctor()` reports them.

Before removal, restore any settings you do not want to keep, disable the controller and coordinate outstanding maintenance. On Linux:

```bash
sudo adaptive-autovacuum-setup remove-preload
```

Restart before removing packages. To remove SQL objects in the control database:

```sql
DROP EXTENSION adaptive_autovacuum;
```

**Dropping the extension does not reverse existing global or table changes** and discards its record of owned table options. Restore them first. See platform setup guides for complete removal.

## 🧪 Testing and documentation

CI runs PostgreSQL 17/18 regression suites, Linux installer tests and Windows setup-helper checks. Use a dedicated test cluster with the launcher disabled for deterministic regression tests:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

[Validation results](VALIDATION.md) document workload drills and observed results; these are not guaranteed performance gains on other systems.

| Document | Contents |
|---|---|
| [Linux installation](docs/INSTALL-LINUX.md) | Packages, cluster selection, authentication and offline setup. |
| [Windows installation](docs/INSTALL-WINDOWS.md) | Credentials, Windows services, ZIPs and DLL handling. |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Doctor checks, controller states, handoff files. |
| [Installer security](docs/INSTALLER-SECURITY.md) | Verification, privileges and recovery. |
| [Architecture](docs/ARCHITECTURE.md) | Controller, workers, SQL program and central state. |
| [Validation](VALIDATION.md) | Test coverage and observed workload behavior. |

## 📄 License

[PostgreSQL License](LICENSE).
