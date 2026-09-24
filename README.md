# adaptive_autovacuum

**Autovacuum that tunes itself, for PostgreSQL 17 and 18 (full feature set on 18).**

![PostgreSQL 17 and 18](https://img.shields.io/badge/PostgreSQL-17%20%7C%2018-336791?logo=postgresql&logoColor=white)
[![Release](https://img.shields.io/github/v/release/secp256k1-sha256/adaptive_autovacuum?color=22c55e)](https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest)
[![Tests](https://github.com/secp256k1-sha256/adaptive_autovacuum/actions/workflows/test.yml/badge.svg)](https://github.com/secp256k1-sha256/adaptive_autovacuum/actions/workflows/test.yml)
![License](https://img.shields.io/badge/license-PostgreSQL-blue)
![Language](https://img.shields.io/badge/lang-C%20%2B%20PL%2FpgSQL-555)
![Status](https://img.shields.io/badge/status-beta-orange)

> **⚠️ Beta version, testing in progress.** This extension is under active development and validation. It has been functionally tested on Linux and Windows (PostgreSQL 18.4, 18.6, 17.6, and 17.11), including regression suites, a hot-standby drill, live emergency-vacuum drills, and ~20,000 TPS pgbench runs, but has not yet completed sustained production-scale testing. Please include `SELECT * FROM adaptive_autovacuum.doctor();` output in bug reports.

## Install once. Manage the whole PostgreSQL instance.

`adaptive_autovacuum` runs as a cluster-level background service. Install it once, in the control database (`postgres` unless `adaptive_autovacuum.control_database` says otherwise):

```sql
CREATE EXTENSION adaptive_autovacuum;
```

It automatically discovers and manages all eligible databases in the same cluster: every connectable, non-template database is found in `pg_database` and scanned by a short-lived database worker, and all results, decisions and table state are kept in the control database. You do not need to install it in every database; the other databases need no extension objects at all. Creating the extension in a second database only raises a WARNING, that copy is ignored (`doctor()` reports `duplicate_installations`), and the database keeps being managed from the control database. Choose the managed set with the policy columns `included_databases` / `excluded_databases` (LIKE patterns) in the control database.

## Quick install (PostgreSQL 17 and 18)

No compiler, headers or manual file copying. Download the installer, read it, run it.

**Linux** (Ubuntu 24.04 / 26.04, RHEL / Rocky / Alma 9):

```bash
curl -fsSLO https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.sh
less install.sh
sudo bash install.sh
```

**Windows** (EDB-style PostgreSQL 17 or 18 x64, elevated PowerShell):

```powershell
Invoke-WebRequest https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
.\install.ps1 -Credential (Get-Credential postgres)
```

The installer discovers your PostgreSQL clusters (and makes you choose when that is ambiguous, for example when both a 17 and an 18 cluster run), verifies the
package checksum against the release manifest, installs the files, appends `adaptive_autovacuum` to
`shared_preload_libraries` without touching the other entries, asks before restarting the one selected service,
creates the extension once, in the control database (`postgres`, or the one you pass with `--control-database` /
`-ControlDatabase`), turns the controller on, and ends with a health report. Copies of the extension in other
databases are reported as ignored.


Diagnose any time with `sudo adaptive-autovacuum-setup doctor` (Windows: `adaptive-autovacuum-setup.ps1 doctor`) or, in SQL,
`SELECT * FROM adaptive_autovacuum.doctor();`. Details, offline installation, package-manager-only installation,
uninstall and exit codes: [docs/INSTALL-LINUX.md](docs/INSTALL-LINUX.md), [docs/INSTALL-WINDOWS.md](docs/INSTALL-WINDOWS.md),
[docs/INSTALLER-SECURITY.md](docs/INSTALLER-SECURITY.md), [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).



<div align="center">

### **Autovacuum that manages itself**

**Built for PostgreSQL installations that don't have a DBA.**

</div>

---

PostgreSQL's autovacuum defaults are intentionally conservative. They are sensible starting points, but they assume someone is watching the database, noticing when maintenance falls behind, and adjusting the configuration as the workload grows.

> ### Increasingly, that person does not exist.

Small teams, startups, solo developers, AI-assisted projects, and vibe-coded applications often run PostgreSQL without dedicated DBA expertise.

Automation and AI agents can also create environments a traditional DBA would rarely design manually:

* 🗄️ **Thousands of databases** on one host
* 📚 **Very large table counts**
* 🔄 **Rapidly changing schemas**
* 📊 **Tables with no recorded ANALYZE**
* ⚙️ **Autovacuum settings copied from defaults, old blog posts, or generated configs**
* 🧹 **Dead-tuple backlogs that grow unnoticed until they become incidents**

`adaptive_autovacuum` is built for those environments.


---

## 🔍 What it watches

`adaptive_autovacuum` continuously asks:

### 🧹 Is vacuum keeping up?

Are dead tuples being created faster than autovacuum can remove them?

### 👷 Are there enough workers?

Is `autovacuum_max_workers` large enough for the number of databases, tables, and active maintenance work on the host?

### 🐌 Is vacuum being throttled too heavily?

Are `autovacuum_vacuum_cost_limit` and `autovacuum_vacuum_cost_delay` preventing the backlog from ever disappearing?

### 🚀 Can PostgreSQL safely push harder?

Do host load, available memory, vacuum activity, and the optional WAL-rate guardrail allow more aggressive maintenance?

### 📏 Are percentage-based thresholds becoming ineffective?

Are large tables waiting far too long before autovacuum triggers?

### ❄️ Are insert-heavy tables accumulating future freeze work?

Insert-only and append-heavy tables can remain deceptively clean while transaction-ID maintenance debt continues to build.

### 📊 Are tables being queried without ever having been analyzed?

Missing statistics can lead to bad query plans long before someone notices the root cause.

### 🚨 Is anti-wraparound autovacuum genuinely stuck?

Are transaction IDs continuing toward exhaustion while PostgreSQL's normal protection is failing to make progress?

### ♻️ Did emergency tuning leave aggressive settings behind?

Temporary per-table tuning should be restored once the workload has recovered.

---

## ⚙️ What it does

When maintenance falls behind, `adaptive_autovacuum` reacts.

It can:

| Capability                | What it does                                                       |
| ------------------------- | ------------------------------------------------------------------ |
| 🧹 **Vacuum tuning**      | Adjusts cluster-wide vacuum cost limits and delays                 |
| 👷 **Worker capacity**    | Recommends more workers; applies increases on PostgreSQL 18         |
| 🎯 **Trigger tuning**     | Corrects ineffective vacuum thresholds on large or busy tables     |
| 🔥 **Hot-table tuning**   | Temporarily applies more aggressive per-table settings             |
| 📊 **Automatic ANALYZE**  | Analyzes eligible live tables with no recorded ANALYZE                |
| 🗑️ **Backlog recovery**  | Responds to growing dead-tuple maintenance debt                    |
| 🧊 **Freeze protection**  | Detects dangerous XID/MXID conditions                              |
| 🚨 **Emergency vacuum**   | Takes over when anti-wraparound autovacuum is demonstrably failing |
| ♻️ **Automatic rollback** | Restores owned table options and decays incident cost tuning              |

---

## 🖥️ Host-aware maintenance

More aggressive maintenance only helps while the machine has capacity for it.

`adaptive_autovacuum` watches signals such as:

* CPU load
* available memory
* WAL generation (pressure threshold is opt-in)
* running vacuum activity
* maintenance backlog
* active autovacuum workers
* XID/MXID pressure

Normal tuning uses these signals to decide when to:

> **Push harder** when maintenance is falling behind and the host has spare capacity.

or:

> **Back off** when vacuum itself risks becoming the workload.

Emergency wraparound protection has separate escalation rules.

---

## 🎯 Design goal

The goal is **not maximum benchmark performance**.

The goal is:

> ### **Vacuum faster than the database creates maintenance debt, use as much of the host as is safely available, and intervene before neglected maintenance becomes an outage.**

---

### Healthy database?

`adaptive_autovacuum` should have very little to do.

### Unhealthy or unmanaged database?

It should behave like:

<div align="center">

## **The DBA who isn't there.**

</div>

---

## Contents

- [Install once](#install-once-manage-the-whole-postgresql-instance)
- [Quick install](#quick-install-postgresql-17-and-18)
- [Installation](#installation)
- [How it decides](#how-it-decides)
- [Monitoring](#monitoring)
- [Operating the controller](#operating-the-controller)
- [Configuration](#configuration)
- [Emergency protection](#emergency-protection)
- [Compatibility and operational notes](#compatibility-and-operational-notes)
- [Upgrade and removal](#upgrade-and-removal)
- [Testing and documentation](#testing-and-documentation)
- [License](#license)

## Installation

**The [quick installer](#quick-install-postgresql-17-and-18) is the simplest route.** It downloads matching binaries and runs setup. PostgreSQL must already be installed; use an administrator account and a PostgreSQL superuser connection, with a restart window available.

Prefer packages? They are on the [release page](https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest) with `SHA256SUMS`.

| Platform | Packages for PostgreSQL 17 and 18 |
| :--- | :--- |
| Ubuntu 24.04 / 26.04 | DEB, amd64 / arm64; extension package **plus** shared helper package |
| RHEL / Rocky / AlmaLinux 9 | RPM, x86_64 / aarch64; extension package **plus** shared helper package |
| Windows, EDB-style installation | x64 ZIP for the PostgreSQL major; helper included |

The extension is created once, in the control database (`postgres` by default; `--control-database` / `-ControlDatabase` picks another). Pick the file names for your platform.

**Ubuntu 24.04 amd64 / PostgreSQL 18:**

```bash
U=https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download
curl -fsSLO $U/adaptive-autovacuum-setup_1.2.0-1_all.deb
curl -fsSLO $U/postgresql-18-adaptive-autovacuum_1.2.0-1_ubuntu24.04_amd64.deb
sudo apt-get install ./adaptive-autovacuum-setup_1.2.0-1_all.deb ./postgresql-18-adaptive-autovacuum_1.2.0-1_ubuntu24.04_amd64.deb
sudo adaptive-autovacuum-setup install
```

**EL9 x86_64 / PostgreSQL 18:**

```bash
U=https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download
curl -fsSLO $U/adaptive-autovacuum-setup-1.2.0-1.el9.noarch.rpm
curl -fsSLO $U/postgresql18-adaptive-autovacuum-1.2.0-1.el9.x86_64.rpm
sudo dnf install ./adaptive-autovacuum-setup-1.2.0-1.el9.noarch.rpm ./postgresql18-adaptive-autovacuum-1.2.0-1.el9.x86_64.rpm
sudo adaptive-autovacuum-setup install
```

**Windows / PostgreSQL 18**, elevated PowerShell:

```powershell
$U = 'https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download'
Invoke-WebRequest "$U/adaptive_autovacuum-1.2.0-pg18-windows-x64.zip" -OutFile aav.zip
Expand-Archive aav.zip -DestinationPath aav
.\aav\adaptive-autovacuum-setup.ps1 install -SourceDir (Resolve-Path .\aav).Path -Credential (Get-Credential postgres)
```

To verify a download, compare its SHA-256 with `SHA256SUMS` from the release page; the helper checks every file inside the Windows ZIP itself.

<details>
<summary><strong>Build from source (contributors and custom installations)</strong></summary>

Install the compiler and server development files for your PostgreSQL major. On Debian/Ubuntu:

```bash
make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
sudo make install PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

PGDG RPM installations normally use `/usr/pgsql-18/bin/pg_config`. On Windows, use an x64 Visual Studio developer prompt:

```bat
windows\build_windows.bat "C:\Program Files\PostgreSQL\18"
```

On Windows, `packaging\windows\build-zip.ps1 -PgMajor 18` packs the build into a ZIP you install as above. For manual activation, append `adaptive_autovacuum` to your existing `shared_preload_libraries` list, restart that instance, then run `CREATE EXTENSION adaptive_autovacuum;` once, in the control database (`postgres` by default); the other databases are managed without it. Existing explicit `off` settings must be changed if you want automation enabled. The shipped `sql/adaptive_autovacuum--1.2.0.sql` is assembled from `sql/parts/01_schema.sql`, `02_program.sql`, `03_control_plane.sql` and `04_views_api.sql` by `bash sql/assemble.sh`; edit the parts, run the script, and commit both.

</details>

Detailed setup, authentication, and offline options: [Linux](docs/INSTALL-LINUX.md) · [Windows](docs/INSTALL-WINDOWS.md).

## How it decides

One controller process, connected to the control database, runs the whole cluster in **sweep generations**. Each sweep discovers the databases from `pg_database` (applying `included_databases` / `excluded_databases`), scans them oldest-transaction-age first with up to **two database workers concurrently** by default, stores every result centrally (`table_state`, `database_state`, `decisions`, `emergency_queue`), and then makes **one global decision** and **one `ALTER SYSTEM` step** for the cluster. It sleeps **60 seconds after a complete sweep**; a database's revisit interval also includes the scan time of the databases ahead of it.

Cluster settings are decided from **complete evidence only**: every non-excluded database must have been scanned successfully in the current generation. If a database failed or timed out, the recommendation is recorded in `global_recommendations` (`evidence_complete = false`) but not applied, and `doctor()` names the database. Database workers only collect and execute table-level actions; they never change cluster settings.

| Decision | Evidence and limits |
| :--- | :--- |
| **Raise vacuum cost budget** | Backlog trend and estimated drain time, host pressure, cost ceilings, and autovacuum activity gained after previous raises. |
| **Add autovacuum workers** | Saturation or an overdue queue, debt trend, available memory, policy ceiling, and PG18 worker slots. CPU count is not a direct worker ceiling. |
| **Adjust work memory / buffer ring** | Active maintenance, available memory, repeated index passes, and bounded recommendations. |
| **Tighten triggers** | Widespread overdue tables across the cluster justify baseline changes; individual outliers can receive table-level tuning. |
| **Analyze missing statistics** | Eligible live tables with no recorded ANALYZE, largest first, within a scheduling budget per database. A running ANALYZE is not cut off at the budget boundary. |
| **Restore table settings** | Six healthy checks by default, provided the controller still owns the managed options. |
| **Decay incident cost tuning** | Ten backlog-free sweeps by default, then a step toward the captured baseline. Worker counts are not automatically lowered. |

Normal table tuning starts at **64 MiB**, requires repeated overdue observations, and respects cooldowns and short lock timeouts. Missing-statistics repair and emergency scanning use separate eligibility rules. Table cost boosts (off by default) share one cluster-wide budget: boosts held in other databases count against it.

Global changes use an allow-list, `ALTER SYSTEM`, and reload. Only the controller process applies them, once per sweep and only from complete evidence; there is no separate per-setting cooldown. `autovacuum_freeze_max_age` remains advice-only. Old values and results are recorded in `global_apply_queue`, and `actions` shows them next to table changes and emergency vacuums.

The default **3,200 MiB/s cost ceiling is theoretical** (`vacuum_cost_ceiling_mbps()` treats every cost unit as a page hit), not a physical bandwidth cap. Raise feedback uses `vacuum_activity_rate`: autovacuum-worker page operations from `pg_stat_io`, weighted by the vacuum cost model, in cost units per second, compared with the budget the live cost pair allows (`cost_budget_rate`). A raise that does not lift that activity by `cost_raise_min_activity_gain_percent` (default 10) holds the next raise; the reason says the extra budget is not being used yet and lists possible causes, rather than claiming storage is the limit.

## Monitoring

Start with health and status, in the control database:

```sql
SELECT * FROM adaptive_autovacuum.doctor();
SELECT * FROM adaptive_autovacuum.status();
```

`doctor()` runs 18 checks and reports `OK`, `WARN`, `FAIL`, or `RESTART_REQUIRED`, with details and remediation. `status()` is one row for the whole cluster: control database, launcher and controller state, sweep generation and the last complete one, sweep timing, managed / excluded / failed / stale databases, tables seen and needing vacuum, maintenance debt and trend, running autovacuum workers, the live cost pair, and the queue, emergency and wraparound state. Both functions are accessible to `pg_monitor`.

| Inspect | Query |
| :--- | :--- |
| Per-database health and freshness | `SELECT * FROM adaptive_autovacuum.database_status;` |
| Table health, every database | `SELECT * FROM adaptive_autovacuum.table_status;` |
| Everything it did (cluster, table, emergency) | `SELECT * FROM adaptive_autovacuum.actions LIMIT 50;` |
| Managed table settings | `SELECT * FROM adaptive_autovacuum.changed_tables;` |
| Global changes and previous values | `SELECT * FROM adaptive_autovacuum.global_apply_queue ORDER BY id DESC;` |
| Latest cluster advice | `SELECT * FROM adaptive_autovacuum.latest_global_recommendation;` |
| Recent decisions and errors | `SELECT * FROM adaptive_autovacuum.decisions ORDER BY id DESC LIMIT 50;` |
| Oldest tables (TOAST age included) of the database you query | `SELECT * FROM adaptive_autovacuum.aging_tables;` |
| Wraparound risk per database | `SELECT * FROM adaptive_autovacuum.wraparound_status;` |
| Cleanup-horizon blockers | `SELECT * FROM adaptive_autovacuum.horizon_blocker();` |
| Controller process and sweep progress | `SELECT * FROM adaptive_autovacuum.controller_status();` |

From the shell: `sudo adaptive-autovacuum-setup doctor` (Windows: `adaptive-autovacuum-setup.ps1 doctor`); add `--format json` / `-Format json` for automation. In `pg_stat_activity` the processes appear as `adaptive autovacuum launcher`, `adaptive autovacuum controller`, `adaptive autovacuum database <name>` and `adaptive autovacuum emergency <name>`.

## Operating the controller

**No policy updates are needed for normal operation.** Fresh installations have the cluster switch on and an active cluster policy in the control database: `enabled = true`, `dry_run = false`, `manage_global_settings = true`. Emergency protection is on. Per-table **cost boosts** are optional and off; normal trigger tuning does not require them.

There is one policy row for the whole cluster; there is no per-database policy. Use these in the control database only when changing operating mode:

```sql
-- Pause the whole cluster
UPDATE adaptive_autovacuum.policy SET enabled = false;

-- Resume
UPDATE adaptive_autovacuum.policy SET enabled = true;

-- Stop scanning and managing one database (LIKE pattern)
UPDATE adaptive_autovacuum.policy SET excluded_databases = excluded_databases || 'reporting_%';

-- Observe proposals without applying them
UPDATE adaptive_autovacuum.policy SET dry_run = true;

-- Resume applying decisions
UPDATE adaptive_autovacuum.policy SET dry_run = false;
```

Pause or resume the whole cluster with `sudo adaptive-autovacuum-setup disable` / `enable`. Alternatively:

```sql
ALTER SYSTEM SET adaptive_autovacuum.enabled = off; -- use on to resume
SELECT pg_reload_conf();
```

Disabling automation does not undo existing tuning or immediately cancel maintenance already running. For an observation-only rollout, configure the cluster switch off before preloading, create the extension in the control database, set `dry_run = true`, and then enable the switch. With setup, `--no-enable` preserves an explicit off setting; it does not turn an already-enabled controller off.

## Configuration

Most installations can keep the defaults. The main operator controls are:

| Setting | Default | Purpose |
| :--- | :--- | :--- |
| `adaptive_autovacuum.control_database` | `postgres` | The one database that holds the extension and its state; the controller connects here. |
| `adaptive_autovacuum.naptime_seconds` | `60` | Sleep after a complete sweep of all databases. |
| `adaptive_autovacuum.max_database_workers` | `2` | Concurrent database workers per sweep, separate from autovacuum workers. |
| `adaptive_autovacuum.database_worker_timeout_seconds` | `3600` | Maximum wait for one database scan; a slower database counts as failed for that sweep. |
| `adaptive_autovacuum.emergency_timeout_seconds` | `86400` | Maximum runtime of one emergency VACUUM; `0` disables the limit. |
| `policy.included_databases` | `NULL` | LIKE patterns; `NULL` means every connectable, non-template database. |
| `policy.excluded_databases` | `{}` | LIKE patterns of databases that are never scanned or managed. |
| `policy.recommendation_workers_max` | `16` | Ceiling on recommended autovacuum workers. |
| `policy.manage_global_settings` | `true` | Set false to retain global advice without applying it. |
| `policy.manage_table_costs` | `false` | Optional table-level cost boosts, under one cluster-wide budget. |
| `policy.cost_raise_min_activity_gain_percent` | `10` | Autovacuum activity gain a cost raise must show before the next raise. |
| `policy.high_wal_mbps` | `0` | Optional WAL-rate pressure threshold; disabled by default. |

`policy.*` means columns in `adaptive_autovacuum.policy` in the control database, not server GUCs. Full defaults and constraints are in the [SQL schema](sql/adaptive_autovacuum--1.2.0.sql).

**Worker slots:** reserve `max_worker_processes` for the launcher, the controller, `max_database_workers` database workers and one emergency worker (5 with the defaults), on top of other extensions and parallel query.

**Many databases:** there is no capacity limit. State lives in ordinary tables in the control database, not in shared memory, and every database is discovered automatically. A sweep over many databases simply takes longer: a database's revisit interval is the sweep time plus the naptime, and `database_status.stale` flags a database only when it has not been revisited within `max(10 × naptime, 3 × observed sweep duration)`, so a slow sweep is not misread as dead databases. Raise `max_database_workers` to shorten sweeps, and exclude databases that need no management.

**Windows CPU pressure:** Windows reports CPU busy fraction rather than Unix load average. To engage the CPU gate near 85% busy, use `UPDATE adaptive_autovacuum.policy SET high_load_per_cpu = 0.85;`. The default `1.5` threshold does not engage that gate on Windows.

### Table-specific policies

Rows in `adaptive_autovacuum.table_policy` (control database) are keyed by database, schema and relation name, so one central row addresses a table in any managed database. Exclude a table from normal management:

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

No OIDs are involved: the rows survive dump/restore and OID reuse, and a row whose relation does not exist (yet, or any more) is kept and applies as soon as a relation of that name appears. After a rename, update the row's `relation_name`.

## Emergency protection

Emergency vacuum is enabled by default, with separate age and progress checks:

- **No vacuum started:** dangerous age exceeds the failure line derived from `1.5 ×` the forced-vacuum trigger, capped by the configured emergency age (default XID/MXID cap: **1 billion**).
- **Forced autovacuum is stalled:** dangerous age, at least **one hour** runtime, and **five consecutive unchanged progress samples** are required before takeover. Age growth alone is not proof of a stall.
- **XID cleanup horizon is blocked:** the XID escalation path is held and the blocker is reported. Independent MXID danger can still qualify for intervention.

Human-started vacuums and vacuums making observable progress are not takeover targets. The separate safety scan includes small tables, excluded schemas, and opted-out tables, but does not cancel running vacuums.

Emergency work uses a dedicated worker started by the controller, one request at a time cluster-wide (also between sweeps), with its own timeout, memory/cost settings, short lock timeout, and retry backoff. It prioritizes freezing and skips index cleanup. Normal host-pressure limits are not an absolute prohibition on emergency intervention.

The extension does not remove blocking transactions, prepared transactions, or replication slots for you. To disable emergency intervention for the whole cluster (in the control database):

```sql
UPDATE adaptive_autovacuum.policy SET emergency_vacuum_enabled = false;
```

## Compatibility and operational notes

| Area | Behavior |
| :--- | :--- |
| **PostgreSQL 17 / 18** | Both support cost tuning, table triggers, missing-statistics repair, and emergency protection. Binaries are major-specific. |
| **PG18 additions** | Reloadable worker-count increases, vacuum maximum thresholds, delay-time measurements, and emergency eager-freeze tuning. PG17 worker increases are advice-only. |
| **Global scope** | The extension is installed in one database and manages the whole cluster; cluster setting changes affect every database. `excluded_databases` only stops scanning and table changes there. |
| **Handoff files** | Worker input/output documents live under `pg_stat_tmp/adaptive_autovacuum/` in the data directory; excluded from base backups, removed at server start. |
| **Operator ownership** | Conflicting manual edits to managed table options make the controller back off. Unrelated GUCs are not changed. |
| **Standbys** | Automation waits for a writable server. Maintain binaries and configuration consistently through your HA tooling. |
| **Configuration managers** | Coordinate Patroni/operators/configuration tooling separately; setup rejects detected managed environments. |
| **Privileges** | Installation and workers require superuser privileges. Database workers run the policy program as an anonymous `DO` block in the target database using only `pg_catalog`. Selected health APIs are exposed to `pg_monitor`. |
| **History** | `decisions` and `global_recommendations` are UNLOGGED and can lose history after a crash. Policy, `table_state`, `database_state` and rollback state remain durable. |
| **Relations** | Normal policy watches ordinary tables, not materialized views. |

## Upgrade and removal

**Upgrade:** install the new package/files for your PostgreSQL major, restart when replacing the preloaded library, and update the extension in the control database only:

```sql
ALTER EXTENSION adaptive_autovacuum UPDATE;
```

**There is no upgrade path from 1.1.0 to 1.2.0** (beta). The extension changed from one installation per database to one control plane per cluster. The installer handles it: when the control database holds 1.1.0, the plan shows `DROP EXTENSION + CREATE EXTENSION` and, after confirmation, re-creates the extension there; policy edits and history of that copy are deleted, so review `changed_tables` and `global_apply_queue.old_value` first and re-apply policy changes afterwards (`table_policy` rows now use `database_name`, `schema_name`, `relation_name`). Databases that carried their own 1.1.0 copy keep them until you run `DROP EXTENSION adaptive_autovacuum;` there; `doctor()` lists them under `duplicate_installations`.

**Remove:** first review and restore any global/table tuning you do not want to retain, disable the controller, and coordinate outstanding maintenance. On Linux:

```bash
sudo adaptive-autovacuum-setup remove-preload
```

Complete the restart before removing packages. If several clusters share the installation, ensure none still needs the library. Optionally remove the SQL objects in the control database (and in any database that still holds a stale copy):

```sql
-- Removes extension-owned policy, state, and history
DROP EXTENSION adaptive_autovacuum;
```

Dropping the extension does not reverse prior global or table-option changes, and it forgets which table options the controller owns, so restore them first. Windows removal commands are documented in the [Windows installation guide](docs/INSTALL-WINDOWS.md).

## Testing and documentation

CI covers PostgreSQL 17 and 18 regression tests, Linux installer tests, and Windows helper checks. The badge shows current status. Run regression tests on a dedicated test cluster with the files installed and the launcher explicitly disabled for deterministic results:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

Live integration tests exercise activation and restart behavior separately. [VALIDATION.md](VALIDATION.md) records workload drills and observed results; these are not promised performance gains on other systems.

| Guide | Contents |
| :--- | :--- |
| [Linux installation](docs/INSTALL-LINUX.md) | Discovery, packages, authentication, offline setup, and exit codes. |
| [Windows installation](docs/INSTALL-WINDOWS.md) | Native installation, credentials, services, and DLL handling. |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Installation and runtime diagnosis. |
| [Architecture](docs/ARCHITECTURE.md) | Launcher, controller, database workers, the SQL program and the control tables. |
| [Installer security](docs/INSTALLER-SECURITY.md) | Verification, privileges, and recovery. |

## License

[PostgreSQL License](LICENSE).
