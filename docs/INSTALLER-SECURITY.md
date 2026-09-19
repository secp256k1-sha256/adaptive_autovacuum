# Installer security

## Trust model

- Artifacts are immutable and named for their exact compatibility: PostgreSQL major, OS/distribution,
  architecture, extension version and package revision. A published file is never replaced; a fix is a new
  revision (`1.1.0-2`) or version (`1.1.1`).
- `release-manifest.json` is the machine-readable source of truth. Installers never scrape the release page
  or guess filenames. The manifest is validated against `packaging/common/release-manifest.schema.json`
  (types, regex allowlists for filenames, URLs, checksums, majors, architectures) before any value is used
  in a path or command. A manifest that fails validation, or points to a missing asset, is refused.
- The selected release is pinned for the whole run; `latest` is resolved once.
- Every download is compared with the manifest SHA-256 (exact hex comparison) before it is opened.
  The Windows ZIP additionally carries `artifact-manifest.json` with a SHA-256 per file, verified after
  expansion, and archive entries are checked to stay inside the expansion directory.
- Downloads use HTTPS only (`curl --proto '=https' --tlsv1.2`, TLS 1.2+ in PowerShell) and the final URL
  after redirects must be on `github.com` or `*.githubusercontent.com`.
- A checksum served from the same location as the artifact detects corruption and accidental mismatch,
  not a compromised publisher. Signing of `SHA256SUMS` / the manifest and Authenticode signing of the DLL
  and scripts are planned; until then, review `install.sh` / `install.ps1` before running them.

## What the installers never do

- Execute content straight from a pipe in the documented path (download, read, then run).
- Put passwords on command lines, in URLs, transcripts, logs or the journal. Linux prefers peer
  authentication over the local socket as the cluster owner; Windows writes a temporary pgpass file with an
  ACL for the current user only and deletes it in `finally`.
- Edit `postgresql.conf`. `shared_preload_libraries` is changed through `ALTER SYSTEM` with a psql variable
  literal (no shell string interpolation into SQL). The only file the installer writes in the data directory
  is the restore of `postgresql.auto.conf` during an offline rollback, and only after verifying the file is
  byte-identical to what the installer itself wrote.
- Lower the execution policy, disable signature checks, or write outside the PostgreSQL installation, the
  program directory and the state directory.
- Restart anything other than the selected service; restart without a prompt unless `--yes` was given.
- Run `DROP EXTENSION`, delete data directories, or remove files while a running postmaster still loads the
  library.
- Send telemetry. There is none.

## State and logs

- Linux journal `/var/lib/adaptive-autovacuum/installer-state.json` (0600, directory 0700, symlinks
  refused), log `/var/log/adaptive-autovacuum/setup.log` (0600). Backups of `postgresql.auto.conf` under
  `/var/lib/adaptive-autovacuum/backups/`.
- Windows journal and log under `%ProgramData%\adaptive_autovacuum\` with an ACL for Administrators and
  SYSTEM only.
- Journal contents: installer version and run id, selected cluster facts, previous
  `shared_preload_libraries`, hashes of `postgresql.auto.conf` before and after, hashes of replaced files,
  completed steps and the final state. No secrets.

## Shell and PowerShell hygiene

- Bash: `set -Eeuo pipefail`, `umask 077`, every variable quoted, commands built as arrays, no `eval`,
  JSON only through `jq`, temporary directories from `mktemp -d` removed by an `EXIT` trap.
- PowerShell: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, `#Requires -RunAsAdministrator`
  on the mutating scripts, `Get-FileHash -Algorithm SHA256`, child processes started with a properly quoted
  argument string (MSVCRT rules) and SQL passed on stdin, temporary files removed in `finally`.

## Reporting

Please report security issues privately through the repository's security advisory form rather than a
public issue. Include the installer version, `adaptive-autovacuum-setup doctor --format json` output with
hostnames redacted, and the journal's `steps` array.
