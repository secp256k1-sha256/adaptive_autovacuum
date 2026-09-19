#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Disable adaptive_autovacuum, remove it from shared_preload_libraries, and optionally delete its files.
.DESCRIPTION
  Three separate, explicit steps (none of them drops database objects):
    1. controller off   (adaptive_autovacuum.enabled = off, reload)
    2. remove-preload   (shared_preload_libraries without adaptive_autovacuum, other entries preserved; restart)
    3. -RemoveFiles     (DLL, control and SQL files; only after the running server no longer loads the library)
  DROP EXTENSION adaptive_autovacuum deletes the policy and history tables and is never run by this script;
  the SQL is printed for you to run per database if you want that.
#>
[CmdletBinding()]
param(
    [switch]$RemoveFiles,
    [switch]$NoRestart,
    [switch]$Yes,
    [switch]$DryRun,
    [string]$ServiceName,
    [string]$PgRoot,
    [string]$DataDirectory,
    [int]$Port,
    [string]$DbUser,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$PgPassFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$setup = Join-Path $PSScriptRoot 'adaptive-autovacuum-setup.ps1'
$common = @{ Yes = $Yes; DryRun = $DryRun; ServiceName = $ServiceName; PgRoot = $PgRoot; DataDirectory = $DataDirectory; DbUser = $DbUser; Credential = $Credential; PgPassFile = $PgPassFile }
if ($Port) { $common.Port = $Port }
foreach ($k in @($common.Keys)) { if ($null -eq $common[$k] -or $common[$k] -eq '') { $common.Remove($k) } }

Write-Host '== 1/3 controller off =='
& $setup disable @common; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host '== 2/3 remove from shared_preload_libraries =='
& $setup remove-preload @common -NoRestart:$NoRestart; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($RemoveFiles) {
    Write-Host '== 3/3 remove files =='
    & $setup remove-files @common; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
    Write-Host '== 3/3 files kept (pass -RemoveFiles to delete the DLL, control and SQL files) =='
}
Write-Host ''
Write-Host 'Database objects were not touched. To delete the policy and history in a database, run there:'
Write-Host '    DROP EXTENSION adaptive_autovacuum;'
exit 0
