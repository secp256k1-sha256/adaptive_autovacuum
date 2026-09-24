# Installing on Windows

Supported by the packaged installer: PostgreSQL 17 and 18 x64 installed the EDB way (a Windows service, the
`HKLM\SOFTWARE\PostgreSQL` registry keys, `C:\Program Files\PostgreSQL\<major>`). Windows PowerShell 5.1 and
PowerShell 7 both work; run from an **elevated** prompt.

## Quick install

```powershell
Invoke-WebRequest https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
.\install.ps1 -Credential (Get-Credential postgres)
```

The extension is created once per cluster, in the control database (`postgres` by default; `-ControlDatabase NAME`
chooses another one and sets `adaptive_autovacuum.control_database`). Every database of the cluster is managed from
there. `install.ps1` downloads `release-manifest.json`, validates it, picks the Windows x64 ZIP for the PostgreSQL major found on the host (the running one when both 17 and 18 are installed; `-PgMajor N` when both run),
verifies its SHA-256, expands it into a unique temporary directory, checks every file against the
`artifact-manifest.json` inside the ZIP, and then runs `adaptive-autovacuum-setup.ps1 install` from the
package. Add `-Yes` for unattended runs, `-Check` for discovery only, `-DryRun` for the plan.
Offline: `-Manifest FILE -ArtifactDir DIR`.

If the execution policy blocks the script, run it with `powershell -ExecutionPolicy Bypass -File .\install.ps1 ...`
for that one invocation instead of lowering the machine policy.

## Authentication

EDB installations use password authentication, so the installer needs a PostgreSQL superuser:

- `-Credential (Get-Credential postgres)` prompts securely;
- `-PgPassFile C:\path\pgpass.conf` for unattended runs (a `host:port:*:user:password` file; protect it with
  ACLs). The installer itself writes a temporary pgpass file readable only by the current user, points
  `PGPASSFILE` at it and deletes it in a `finally` block. The password is never on a command line or in a log.

## What the installer does

Same contract as Linux (see `INSTALL-LINUX.md`), with these Windows specifics:

- **Discovery** merges Windows services (`Win32_Service`, paths with spaces parsed properly), the EDB
  registry (64-bit and 32-bit views; stale entries pointing at missing directories are ignored), the
  `C:\Program Files\PostgreSQL\*` directories and `postmaster.pid`, then confirms facts over SQL with the
  matching `psql.exe`. Four installed majors (14, 15, 17, 18) with only PostgreSQL 18 running select 18 automatically.
- **Files** go to `pg_config --pkglibdir` (DLL) and `pg_config --sharedir\extension` (control and SQL). A
  DLL mapped by the running postmaster cannot be overwritten, so it is renamed aside and the new file moved
  into place; the old copy is deleted after the restart. Helper scripts land in
  `C:\Program Files\adaptive_autovacuum\<version>\`.
- **Restart** is `Restart-Service <name>` for the selected service only, after a prompt (`-Yes` accepts,
  `-NoRestart` defers). Failure to come back triggers the same `postgresql.auto.conf` rollback as on Linux.
- **Journal**: `%ProgramData%\adaptive_autovacuum\installer-state.json` (Administrators and SYSTEM only).
  Log: `%ProgramData%\adaptive_autovacuum\setup.log`.

## Helper commands

The helper is installed by the package; use the copy in `C:\Program Files\adaptive_autovacuum\<version>\`.

```powershell
.\adaptive-autovacuum-setup.ps1 check [-Json]
.\adaptive-autovacuum-setup.ps1 doctor [-Format json]
.\adaptive-autovacuum-setup.ps1 install [-ControlDatabase NAME] -Credential (Get-Credential postgres) [-Yes]
.\adaptive-autovacuum-setup.ps1 disable | enable
.\adaptive-autovacuum-setup.ps1 remove-preload
.\adaptive-autovacuum-setup.ps1 remove-files      # only after remove-preload; never drops database objects
```

Selection filters when several PostgreSQL 18 instances run: `-ServiceName`, `-DataDirectory`, `-PgRoot`, `-Port`.

## Uninstall

```powershell
.\uninstall.ps1 -Credential (Get-Credential postgres)               # disable + remove-preload (+restart)
.\uninstall.ps1 -Credential (Get-Credential postgres) -RemoveFiles  # ... and delete the files afterwards
```

Database objects are never dropped by the scripts. In the control database, if you want that:
`DROP EXTENSION adaptive_autovacuum;` (deletes policy and history). Upgrading from 1.1.0 has no upgrade script: the
installer re-creates the extension in the control database after confirmation.

## Windows notes

Windows has no load average; the extension uses CPU busy % instead (`load1` in `host_metrics()`), which
cannot exceed the core count. To have the host-pressure gate engage, set
`UPDATE adaptive_autovacuum.policy SET high_load_per_cpu = 0.85;` (see README, "Windows").
