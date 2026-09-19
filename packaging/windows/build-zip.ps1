#Requires -Version 5.1
<#
.SYNOPSIS
  Assemble the Windows release ZIP: adaptive_autovacuum-<version>-pg<major>-windows-x64.zip
.DESCRIPTION
  Collects the DLL (built by windows\build_windows.bat), the control file, every SQL script, the setup
  helper scripts and LICENSE, writes artifact-manifest.json with a SHA-256 per file, and zips them.
  Prints the ZIP path and its SHA-256 (for release-manifest.json).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$Dll = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'windows\adaptive_autovacuum.dll'),
    [int]$PgMajor = 18,
    [string]$OutDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'dist')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$control = Join-Path $RepoRoot 'adaptive_autovacuum.control'
$version = (Select-String -Path $control -Pattern "^default_version\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
if (-not (Test-Path $Dll)) { throw "DLL not found: $Dll (run windows\build_windows.bat first)" }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('aav-zip-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $files = @()
    foreach ($src in @($Dll, $control) + @(Get-ChildItem (Join-Path $RepoRoot 'sql') -Filter 'adaptive_autovacuum--*.sql' | ForEach-Object { $_.FullName }) +
                     @((Join-Path $PSScriptRoot 'adaptive-autovacuum-setup.ps1'), (Join-Path $PSScriptRoot 'AdaptiveAutovacuum.Setup.psm1'), (Join-Path $PSScriptRoot 'uninstall.ps1'), (Join-Path $RepoRoot 'LICENSE'))) {
        $leaf = Split-Path $src -Leaf
        Copy-Item $src (Join-Path $stage $leaf)
        $files += [ordered]@{ path = $leaf; sha256 = (Get-FileHash -LiteralPath (Join-Path $stage $leaf) -Algorithm SHA256).Hash.ToLowerInvariant(); size_bytes = (Get-Item (Join-Path $stage $leaf)).Length }
    }
    $manifest = [ordered]@{ schema_version = 1; extension_version = $version; postgres_major = $PgMajor; operating_system = 'windows'; architecture = 'x64'
                            built_at = (Get-Date).ToUniversalTime().ToString('o'); files = $files }
    [IO.File]::WriteAllText((Join-Path $stage 'artifact-manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
    $zipName = "adaptive_autovacuum-$version-pg$PgMajor-windows-x64.zip"
    $zipPath = Join-Path $OutDir $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject]@{ zip = $zipPath; sha256 = $sha; extension_version = $version; postgres_major = $PgMajor; files = $files.Count }
} finally { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
