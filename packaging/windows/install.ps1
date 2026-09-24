#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  adaptive_autovacuum bootstrap installer for Windows (PostgreSQL 17 or 18 x64, EDB-style installation).
.DESCRIPTION
  Downloads the release manifest, selects the Windows ZIP for this host, verifies its SHA-256,
  expands it to a unique temporary directory, verifies every file against artifact-manifest.json,
  and hands over to adaptive-autovacuum-setup.ps1 (inside the ZIP) for file installation,
  shared_preload_libraries, restart, CREATE EXTENSION and health checks.

    Invoke-WebRequest https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.ps1 -OutFile install.ps1
    Get-Content .\install.ps1
    .\install.ps1 -Credential (Get-Credential postgres)                      # control database postgres
    .\install.ps1 -ControlDatabase app -Credential (Get-Credential postgres)

  Exit codes: 0 ok, 2 arguments, 3 no supported PostgreSQL, 4 ambiguous, 5 unsupported platform,
              6 download/integrity failure, 7 privileges, 8 installation failure, 9 restart failed, 10 health check failed.
.PARAMETER Version
  Extension release to install (default: latest).
.PARAMETER Manifest
  Path or URL of a release manifest to use instead of the GitHub release asset.
.PARAMETER ArtifactDir
  Take the ZIP from this directory instead of downloading it (offline install; still checksum-verified).
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$Manifest,
    [string]$ArtifactDir,
    [string]$ControlDatabase,
    [string[]]$Database = @(),
    [switch]$AllDatabases,
    [switch]$SkipCreateExtension,
    [switch]$NoEnable,
    [switch]$NoRestart,
    [switch]$Yes,
    [switch]$Check,
    [switch]$DryRun,
    [int]$PgMajor,
    [string]$PgRoot,
    [string]$ServiceName,
    [string]$DataDirectory,
    [int]$Port,
    [string]$DbUser,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$PgPassFile,
    [int]$StartupWait = 90,
    [int]$RestartTimeout = 60
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Any unexpected error is an installation failure with a defined exit code, never a silent exit 0.
trap { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 8 }

$InstallerVersion = '1.2.0'
$Repo = if ($env:AAV_REPO) { $env:AAV_REPO } else { 'secp256k1-sha256/adaptive_autovacuum' }
$ReleaseBase = "https://github.com/$Repo/releases"
$AllowedHosts = @('github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
$SupportedMajors = @(17, 18)
$Ex = @{ Ok = 0; Args = 2; NoPg = 3; Ambiguous = 4; Unsupported = 5; Download = 6; Privilege = 7; ConfigFailed = 8 }

function Fail([int]$Code, [string]$Message) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit $Code }
function Say([string]$Text) { Write-Host $Text }
# Final URI after redirects: HttpWebResponse (Windows PowerShell 5.1) vs HttpResponseMessage (PowerShell 7).
function Get-FinalUri($Response, [string]$Requested) {
    $b = $Response.BaseResponse
    if ($b -and $b.PSObject.Properties['ResponseUri'] -and $b.ResponseUri) { return [uri]$b.ResponseUri }
    if ($b -and $b.PSObject.Properties['RequestMessage'] -and $b.RequestMessage.RequestUri) { return [uri]$b.RequestMessage.RequestUri }
    return [uri]$Requested
}

if ($Version -ne 'latest' -and $Version -notmatch '^v?\d+\.\d+\.\d+([.-][A-Za-z0-9.-]+)?$') { Fail $Ex.Args '-Version must look like 1.2.0' }
$Version = $Version -replace '^v', ''
if ($ArtifactDir -and -not (Test-Path $ArtifactDir -PathType Container)) { Fail $Ex.Args '-ArtifactDir is not a directory' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Fail $Ex.Unsupported "unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE (x64 only)" }
if ($PgMajor -and $PgMajor -notin $SupportedMajors) { Fail $Ex.Unsupported "PostgreSQL $PgMajor is not supported by this release (supported: $($SupportedMajors -join ', '))" }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Say "adaptive_autovacuum installer $InstallerVersion (Windows)"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aav-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # ---- manifest ----
    $manifestPath = Join-Path $tmp 'release-manifest.json'
    $src = $Manifest
    if (-not $src) { $src = if ($Version -eq 'latest') { "$ReleaseBase/latest/download/release-manifest.json" } else { "$ReleaseBase/download/v$Version/release-manifest.json" } }
    if ($src -match '^https://') {
        try { $resp = Invoke-WebRequest -Uri $src -OutFile $manifestPath -UseBasicParsing -MaximumRedirection 5 -PassThru } catch { Fail $Ex.Download "download failed: $src ($($_.Exception.Message))" }
        $final = Get-FinalUri $resp $src
        if ($final.Host -notin $AllowedHosts -and $final.Host -notlike '*.githubusercontent.com') { Fail $Ex.Download "download was redirected to an unexpected host: $($final.Host)" }
    } elseif (Test-Path $src) { Copy-Item $src $manifestPath } else { Fail $Ex.Args "manifest not found: $src" }
    try { $m = Get-Content -Raw $manifestPath | ConvertFrom-Json } catch { Fail $Ex.Download 'release manifest is not valid JSON' }
    # Validation: every value used in a path or command must match an allowlist.
    $valid = ($m.schema_version -is [int] -or $m.schema_version -is [long]) -and ($m.extension_version -match '^\d+\.\d+\.\d+([.-][A-Za-z0-9.-]+)?$') -and
             ($m.minimum_installer_version -match '^\d+\.\d+\.\d+$') -and ($m.artifacts -is [array]) -and ($m.artifacts.Count -gt 0)
    if ($valid) {
        foreach ($a in $m.artifacts) {
            if (-not ($a.artifact_filename -match '^[A-Za-z0-9._+-]+$' -and $a.artifact_url -match '^https://[A-Za-z0-9._-]+/[A-Za-z0-9._/+%-]+$' -and $a.sha256 -match '^[0-9a-f]{64}$' -and
                      ($a.postgres_major -is [int] -or $a.postgres_major -is [long]) -and $a.operating_system -match '^[a-z]+$' -and $a.architecture -match '^[a-z0-9_]+$' -and $a.package_type -match '^(deb|rpm|zip)$')) { $valid = $false }
        }
    }
    if (-not $valid) { Fail $Ex.Download 'release manifest failed validation (unexpected fields or values)' }
    if ([version]$m.minimum_installer_version -gt [version]$InstallerVersion) { Fail $Ex.Unsupported "this install.ps1 ($InstallerVersion) is older than the release requires ($($m.minimum_installer_version)); download the install.ps1 published with the release" }
    if ($Version -ne 'latest' -and $Version -ne $m.extension_version) { Fail $Ex.Download "manifest is for $($m.extension_version), not the requested $Version" }

    # ---- minimal major discovery for artifact selection (full discovery happens in the helper) ----
    $majors = @(); $runningMajors = @()
    function MajorOf([string]$root) { $pgc = Join-Path $root 'bin\pg_config.exe'; if (Test-Path $pgc) { $v = & $pgc --version; if ($v -match 'PostgreSQL (\d+)') { return [int]$Matches[1] } }; return $null }
    foreach ($svc in @(Get-CimInstance Win32_Service | Where-Object { $_.Name -like 'postgresql*' })) {
        if ($svc.PathName -match '^\s*"?([^"]+?)\\bin\\') { $mj = MajorOf $Matches[1]; if ($mj) { $majors += $mj; if ($svc.State -eq 'Running') { $runningMajors += $mj } } }
    }
    foreach ($d in @(Get-ChildItem "$env:ProgramFiles\PostgreSQL" -Directory -ErrorAction SilentlyContinue)) { $mj = MajorOf $d.FullName; if ($mj) { $majors += $mj } }
    if ($PgRoot) { $mj = MajorOf $PgRoot; if ($mj) { $majors += $mj } }
    $majors = @($majors | Sort-Object -Unique)
    $supported = @($majors | Where-Object { $_ -in $SupportedMajors })
    $runningSupported = @($runningMajors | Sort-Object -Unique | Where-Object { $_ -in $SupportedMajors })
    if ($PgMajor) { $major = $PgMajor }
    elseif ($supported.Count -eq 1) { $major = $supported[0] }
    elseif ($supported.Count -eq 0) { Fail $Ex.NoPg "no supported PostgreSQL installation found (present: $(if ($majors) { $majors -join ', ' } else { 'none' }); supported: $($SupportedMajors -join ', '))." }
    elseif ($runningSupported.Count -eq 1) { $major = $runningSupported[0]; Say "Several supported majors installed ($($supported -join ', ')); using the running one: $major" }
    else { Fail $Ex.Ambiguous "several supported PostgreSQL majors are installed ($($supported -join ', ')) and $($runningSupported.Count) of them run; pass -PgMajor N" }
    # The helper must not pick a different cluster than the package we install.
    $PgMajor = $major
    Say "Host: $((Get-CimInstance Win32_OperatingSystem).Caption) x64; PostgreSQL major: $major"

    $art = @($m.artifacts | Where-Object { $_.package_type -eq 'zip' -and $_.operating_system -eq 'windows' -and $_.architecture -eq 'x64' -and [int]$_.postgres_major -eq $major })
    if ($art.Count -eq 0) { Fail $Ex.Unsupported "release $($m.extension_version) has no Windows x64 package for PostgreSQL $major" }
    if ($art.Count -gt 1) { Fail $Ex.Download 'release manifest lists several packages for this host; refusing to guess' }
    $art = $art[0]
    Say "Release: $($m.extension_version); package: $($art.artifact_filename)"

    # ---- obtain and verify the ZIP ----
    $zip = Join-Path $tmp $art.artifact_filename
    if ($ArtifactDir) {
        $srcZip = Join-Path $ArtifactDir $art.artifact_filename
        if (-not (Test-Path $srcZip)) { Fail $Ex.Download "package not found in -ArtifactDir: $srcZip" }
        Copy-Item $srcZip $zip
    } else {
        try { $resp = Invoke-WebRequest -Uri $art.artifact_url -OutFile $zip -UseBasicParsing -MaximumRedirection 5 -PassThru } catch { Fail $Ex.Download "download failed: $($art.artifact_url) ($($_.Exception.Message))" }
        $final = Get-FinalUri $resp $art.artifact_url; if ($final.Host -notin $AllowedHosts -and $final.Host -notlike '*.githubusercontent.com') { Fail $Ex.Download "download was redirected to an unexpected host: $($final.Host)" }
    }
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $art.sha256) { Fail $Ex.Download "checksum mismatch for $($art.artifact_filename): expected $($art.sha256), got $actual. The download is corrupt or tampered with; nothing was installed." }
    Say "[OK]   artifact checksum verified ($($art.artifact_filename))"
    $expanded = Join-Path $tmp 'pkg'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    # Path traversal guard: every entry must stay under the expansion directory.
    $root = (Resolve-Path $expanded).Path
    foreach ($f in Get-ChildItem $expanded -Recurse -File) { if (-not $f.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail $Ex.Download 'archive contains an entry outside its root' } }
    $setup = Join-Path $expanded 'adaptive-autovacuum-setup.ps1'
    if (-not (Test-Path $setup) -or -not (Test-Path (Join-Path $expanded 'AdaptiveAutovacuum.Setup.psm1'))) { Fail $Ex.Download 'the package does not contain the setup helper' }

    # ---- hand over ----
    $fwd = @{ SourceDir = $expanded; ControlDatabase = $ControlDatabase; Database = $Database; AllDatabases = $AllDatabases; SkipCreateExtension = $SkipCreateExtension; NoEnable = $NoEnable
              NoRestart = $NoRestart; Yes = $Yes; DryRun = $DryRun; PgRoot = $PgRoot; ServiceName = $ServiceName; DataDirectory = $DataDirectory
              DbUser = $DbUser; Credential = $Credential; PgPassFile = $PgPassFile; StartupWait = $StartupWait; RestartTimeout = $RestartTimeout }
    if ($Port) { $fwd.Port = $Port }; if ($PgMajor) { $fwd.PgMajor = $PgMajor }
    foreach ($k in @($fwd.Keys)) { if ($null -eq $fwd[$k] -or $fwd[$k] -eq '') { $fwd.Remove($k) } }
    if ($Check) { & $setup check @fwd; exit $LASTEXITCODE }
    if (-not $Yes -and -not $DryRun) {
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $a = Read-Host "Install the package and configure PostgreSQL $major? [Y/n]"
            if (-not ([string]::IsNullOrWhiteSpace($a) -or $a -match '^[Yy]')) { Fail $Ex.Args 'cancelled' }
        } else { Fail $Ex.Args 'non-interactive session: pass -Yes to install' }
    }
    Say ''
    & $setup install @fwd
    exit $LASTEXITCODE
} finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
