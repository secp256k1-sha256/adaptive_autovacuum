# adaptive_autovacuum

**Autovacuum that tunes itself, for PostgreSQL 17 and 18 (full feature set on 18).**

![PostgreSQL 17 and 18](https://img.shields.io/badge/PostgreSQL-17%20%7C%2018-336791?logo=postgresql&logoColor=white)
[![Release](https://img.shields.io/github/v/release/secp256k1-sha256/adaptive_autovacuum?color=22c55e)](https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest)
[![Tests](https://github.com/secp256k1-sha256/adaptive_autovacuum/actions/workflows/test.yml/badge.svg)](https://github.com/secp256k1-sha256/adaptive_autovacuum/actions/workflows/test.yml)
![License](https://img.shields.io/badge/license-PostgreSQL-blue)
![Language](https://img.shields.io/badge/lang-C%20%2B%20PL%2FpgSQL-555)
![Status](https://img.shields.io/badge/status-beta-orange)

> **⚠️ Beta version, testing in progress.** This extension is under active development and validation. It has been functionally tested on Linux and Windows (PostgreSQL 18.4, 18.6, 17.6, and 17.11), including regression suites, a hot-standby drill, live emergency-vacuum drills, and ~20,000 TPS pgbench runs, but has not yet completed sustained production-scale testing.

## Quick install (PostgreSQL 17 and 18)

No compiler, headers or manual file copying. Download the installer, read it, run it.

**Linux** (Ubuntu 24.04 / 26.04, RHEL / Rocky / Alma 9):

```bash
curl -fsSLO https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.sh
less install.sh
sudo bash install.sh --database mydb
```

**Windows** (EDB-style PostgreSQL 17 or 18 x64, elevated PowerShell):

```powershell
Invoke-WebRequest https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
.\install.ps1 -Database mydb -Credential (Get-Credential postgres)
```

The installer discovers your PostgreSQL clusters (and makes you choose when that is ambiguous, for example when both a 17 and an 18 cluster run), verifies the
package checksum against the release manifest, installs the files, appends `adaptive_autovacuum` to
`shared_preload_libraries` without touching the other entries, asks before restarting the one selected service,
creates or updates the extension in the databases you named, turns the controller on, and ends with a health report:


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

Prefer packages? Download them from [**v1.1.0 Releases**](https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/tag/v1.1.0) and verify against `SHA256SUMS`.

| Platform | Packages for PostgreSQL 17 and 18 |
| :--- | :--- |
| Ubuntu 24.04 / 26.04 | DEB, amd64 / arm64; extension package **plus** shared helper package |
| RHEL / Rocky / AlmaLinux 9 | RPM, x86_64 / aarch64; extension package **plus** shared helper package |
| Windows, EDB-style installation | x64 ZIP for the PostgreSQL major; helper included |

These examples assume the files have been downloaded. Replace `mydb` with an existing database and choose filenames matching your platform.

**Ubuntu 24.04 amd64 / PostgreSQL 18:**

```bash
sudo apt-get install ./adaptive-autovacuum-setup_1.1.0-1_all.deb ./postgresql-18-adaptive-autovacuum_1.1.0-1_ubuntu24.04_amd64.deb
sudo adaptive-autovacuum-setup install --database mydb
```

**EL9 x86_64 / PostgreSQL 18:**

```bash
sudo dnf install ./adaptive-autovacuum-setup-1.1.0-1.el9.noarch.rpm ./postgresql18-adaptive-autovacuum-1.1.0-1.el9.x86_64.rpm
sudo adaptive-autovacuum-setup install --database mydb
```

**Windows / PostgreSQL 18**, elevated PowerShell:

```powershell
Expand-Archive .\adaptive_autovacuum-1.1.0-pg18-windows-x64.zip -DestinationPath .\aav
.\aav\adaptive-autovacuum-setup.ps1 install -SourceDir (Resolve-Path .\aav).Path -Database mydb -Credential (Get-Credential postgres)
```


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

Use the platform guide for file placement and setup. For manual activation, append `adaptive_autovacuum` to your existing `shared_preload_libraries` list, restart that instance, then run `CREATE EXTENSION adaptive_autovacuum;` in each target database. Existing explicit `off` settings must be changed if you want automation enabled.

</details>

Detailed setup, authentication, and offline options: [Linux](docs/INSTALL-LINUX.md) · [Windows](docs/INSTALL-WINDOWS.md).

## How it decides

The launcher checks databases in transaction-age order, running up to **two policy workers concurrently** by default. It sleeps **60 seconds after a complete pass**; a database's revisit interval also includes scan time.

Each managed database publishes a shared summary. Global recommendations combine available summaries so one quiet database does not hide another database's maintenance pressure.

| Decision | Evidence and limits |
| :--- | :--- |
| **Raise vacuum cost budget** | Backlog trend and estimated drain time, host pressure, cost ceilings, and activity gained after previous raises. |
| **Add autovacuum workers** | Saturation or an overdue queue, debt trend, available memory, policy ceiling, and PG18 worker slots. CPU count is not a direct worker ceiling. |
| **Adjust work memory / buffer ring** | Active maintenance, available memory, repeated index passes, and bounded recommendations. |
| **Tighten triggers** | Widespread overdue tables justify baseline changes; individual outliers can receive table-level tuning. |
| **Analyze missing statistics** | Eligible live tables with no recorded ANALYZE, largest first, within a scheduling budget. A running ANALYZE is not cut off at the budget boundary. |
| **Restore table settings** | Six healthy checks by default, provided the controller still owns the managed options. |
| **Decay incident cost tuning** | Ten backlog-free checks by default, then a step toward the captured baseline. Worker counts are not automatically lowered. |

Normal table tuning starts at **64 MiB**, requires repeated overdue observations, and respects cooldowns and short lock timeouts. Missing-statistics repair and emergency scanning use separate eligibility rules.

Global changes use an allow-list, `ALTER SYSTEM`, and reload. A given GUC can be applied no more often than once per **two configured naptimes** across the cluster. `autovacuum_freeze_max_age` remains advice-only. Old values and results are recorded in `global_apply_queue`.

The default **3,200 MiB/s cost ceiling is theoretical**, not a physical bandwidth cap. Autovacuum `pg_stat_io` feedback includes buffer hits, so it is not a direct measurement of storage throughput either.

## Monitoring

Start with health and status:

```sql
SELECT * FROM adaptive_autovacuum.doctor();
SELECT * FROM adaptive_autovacuum.status();
```

`doctor()` reports `OK`, `WARN`, `FAIL`, or `RESTART_REQUIRED`, with details and remediation. Both functions are accessible to `pg_monitor`.

| Inspect | Query |
| :--- | :--- |
| Global changes and previous values | `SELECT * FROM adaptive_autovacuum.global_apply_queue ORDER BY id DESC;` |
| Managed table settings | `SELECT * FROM adaptive_autovacuum.changed_tables;` |
| Table health | `SELECT * FROM adaptive_autovacuum.relation_status;` |
| Latest cluster advice | `SELECT * FROM adaptive_autovacuum.latest_global_recommendation;` |
| Recent decisions and errors | `SELECT * FROM adaptive_autovacuum.decisions ORDER BY id DESC LIMIT 50;` |
| Wraparound risk | `SELECT * FROM adaptive_autovacuum.wraparound_status;` |
| Cleanup-horizon blockers | `SELECT * FROM adaptive_autovacuum.horizon_blocker();` |
| Shared summary capacity | `SELECT * FROM adaptive_autovacuum.cluster_summary_status();` |

Linux diagnostics are also available with `sudo adaptive-autovacuum-setup doctor`, or `doctor --format json` for automation.

## Operating the controller

**No policy updates are needed for normal operation.** Fresh installations have the cluster switch on and an active database policy: `enabled = true`, `dry_run = false`, `manage_global_settings = true`. Emergency protection is on. Per-table **cost boosts** are optional and off; normal trigger tuning does not require them.

Use these only when changing operating mode:

```sql
-- Pause this database
UPDATE adaptive_autovacuum.policy SET enabled = false;

-- Resume this database
UPDATE adaptive_autovacuum.policy SET enabled = true;

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

Disabling automation does not undo existing tuning or immediately cancel maintenance already running. For an observation-only rollout, configure the cluster switch off before preloading, create the extension, set `dry_run = true`, and then enable the switch. With setup, `--no-enable` preserves an explicit off setting; it does not turn an already-enabled controller off.

## Configuration

Most installations can keep the defaults. The main operator controls are:

| Setting | Default | Purpose |
| :--- | :--- | :--- |
| `adaptive_autovacuum.naptime_seconds` | `60` | Sleep after a complete database pass. |
| `adaptive_autovacuum.max_database_workers` | `2` | Concurrent policy workers, separate from autovacuum workers. |
| `adaptive_autovacuum.max_tracked_databases` | `256` | Shared summary capacity; increasing it requires restart. |
| `adaptive_autovacuum.global_settings_database` | Empty | Optional sole database for queuing/applying global changes and holding their audit records. |
| `policy.recommendation_workers_max` | `16` | Ceiling on recommended autovacuum workers. |
| `policy.manage_global_settings` | `true` | Set false to retain global advice without applying it. |
| `policy.manage_table_costs` | `false` | Optional table-level cost boosts. |
| `policy.high_wal_mbps` | `0` | Optional WAL-rate pressure threshold; disabled by default. |

`policy.*` means columns in `adaptive_autovacuum.policy`, not server GUCs. Full defaults and constraints are in the [SQL schema](sql/adaptive_autovacuum--1.1.0.sql).

**Many databases:** increase `max_tracked_databases` for larger fleets. Summary overflow blocks automatic global applications until capacity is sufficient; inspect `cluster_summary_status()`.

**Windows CPU pressure:** Windows reports CPU busy fraction rather than Unix load average. To engage the CPU gate near 85% busy, use `UPDATE adaptive_autovacuum.policy SET high_load_per_cpu = 0.85;`. The default `1.5` threshold does not engage that gate on Windows.

### Table-specific policies

Exclude a table from normal management:

```sql
INSERT INTO adaptive_autovacuum.table_policy (relid, enabled, note)
VALUES ('app.audit_archive'::regclass, false, 'Managed manually')
ON CONFLICT (relid) DO UPDATE SET enabled = false;
```

Give a hot table a tighter dead-tuple target:

```sql
INSERT INTO adaptive_autovacuum.table_policy (relid, target_dead_tuple_ratio, note)
VALUES ('app.orders'::regclass, 0.005, 'Tighter maintenance target')
ON CONFLICT (relid) DO UPDATE SET target_dead_tuple_ratio = 0.005;
```

Policies use relation OIDs and name fingerprints. Reapply them after logical dump/restore; after a rename, explicitly re-adopt the row with `UPDATE adaptive_autovacuum.table_policy SET enabled = enabled WHERE relid = 'app.new_name'::regclass;`.

## Emergency protection

Emergency vacuum is enabled by default, with separate age and progress checks:

- **No vacuum started:** dangerous age exceeds the failure line derived from `1.5 ×` the forced-vacuum trigger, capped by the configured emergency age (default XID/MXID cap: **1 billion**).
- **Forced autovacuum is stalled:** dangerous age, at least **one hour** runtime, and **five consecutive unchanged progress samples** are required before takeover. Age growth alone is not proof of a stall.
- **XID cleanup horizon is blocked:** the XID escalation path is held and the blocker is reported. Independent MXID danger can still qualify for intervention.

Human-started vacuums and vacuums making observable progress are not takeover targets. The separate safety scan includes small tables, excluded schemas, and opted-out tables, but does not cancel running vacuums.

Emergency work uses a dedicated worker, serialized across the cluster, with its own timeout, memory/cost settings, short lock timeout, and retry backoff. It prioritizes freezing and skips index cleanup. Normal host-pressure limits are not an absolute prohibition on emergency intervention.

The extension does not remove blocking transactions, prepared transactions, or replication slots for you. To disable emergency intervention in this database:

```sql
UPDATE adaptive_autovacuum.policy SET emergency_vacuum_enabled = false;
```

## Compatibility and operational notes

| Area | Behavior |
| :--- | :--- |
| **PostgreSQL 17 / 18** | Both support cost tuning, table triggers, missing-statistics repair, and emergency protection. Binaries are major-specific. |
| **PG18 additions** | Reloadable worker-count increases, vacuum maximum thresholds, delay-time measurements, and emergency eager-freeze tuning. PG17 worker increases are advice-only. |
| **Global scope** | Cluster setting changes affect all databases, including those without the extension. |
| **Operator ownership** | Conflicting manual edits to managed table options make the controller back off. Unrelated GUCs are not changed. |
| **Standbys** | Automation waits for a writable server. Maintain binaries and configuration consistently through your HA tooling. |
| **Configuration managers** | Coordinate Patroni/operators/configuration tooling separately; setup rejects detected managed environments. |
| **Privileges** | Installation and workers require superuser privileges. Selected health APIs are exposed to `pg_monitor`. |
| **History** | `decisions` and `global_recommendations` are UNLOGGED and can lose history after a crash. Policy and rollback state remain durable. |
| **Relations** | Normal policy watches ordinary tables, not materialized views. |

## Upgrade and removal

**Upgrade:** install the new package/files for your PostgreSQL major, restart when replacing the preloaded library, and update each managed database:

```sql
ALTER EXTENSION adaptive_autovacuum UPDATE;
```

The setup helper handles supported activation/upgrades. The supplied **1.0.0 → 1.1.0** migration preserves policy values. Existing database dry-run or disabled policies are not reset to active mode by an upgrade.

**Remove:** first review and restore any global/table tuning you do not want to retain, disable the controller, and coordinate outstanding maintenance. On Linux:

```bash
sudo adaptive-autovacuum-setup remove-preload
```

Complete the restart before removing packages. If several clusters share the installation, ensure none still needs the library. Optionally remove SQL objects in each database:

```sql
-- Removes extension-owned policy, state, and history
DROP EXTENSION adaptive_autovacuum;
```

Dropping the extension does not reverse prior global or table-option changes. Windows removal commands are documented in the [Windows installation guide](docs/INSTALL-WINDOWS.md).

## Testing and documentation

CI covers PostgreSQL 17 and 18 regression and upgrade tests, Linux installer tests, and Windows helper checks. The badge shows current status. Run regression tests on a dedicated test cluster with the files installed and the launcher explicitly disabled for deterministic results:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

Live integration tests exercise activation and restart behavior separately. [VALIDATION.md](VALIDATION.md) records workload drills and observed results; these are not promised performance gains on other systems.

| Guide | Contents |
| :--- | :--- |
| [Linux installation](docs/INSTALL-LINUX.md) | Discovery, packages, authentication, offline setup, and exit codes. |
| [Windows installation](docs/INSTALL-WINDOWS.md) | Native installation, credentials, services, and DLL handling. |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Installation and runtime diagnosis. |
| [Architecture](docs/ARCHITECTURE.md) | Workers and controller implementation. |
| [Installer security](docs/INSTALLER-SECURITY.md) | Verification, privileges, and recovery. |

## License

[PostgreSQL License](LICENSE).
