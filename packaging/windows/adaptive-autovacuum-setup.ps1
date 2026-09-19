#Requires -Version 5.1
<#
.SYNOPSIS
  adaptive_autovacuum setup helper for Windows: check, install, doctor, enable, disable, remove-preload, remove-files.
.DESCRIPTION
  Same behavioural contract and exit codes as the Linux adaptive-autovacuum-setup. Run from an elevated PowerShell.
  Exit codes: 0 ok, 2 arguments, 3 no supported PostgreSQL, 4 ambiguous, 5 unsupported, 6 download/integrity,
              7 privileges, 8 configuration failed (rolled back), 9 restart failed, 10 health check failed.
.EXAMPLE
  .\adaptive-autovacuum-setup.ps1 check
  .\adaptive-autovacuum-setup.ps1 install -Database mydb -Credential (Get-Credential postgres) -Yes
  .\adaptive-autovacuum-setup.ps1 doctor -Format json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('check', 'install', 'doctor', 'enable', 'disable', 'remove-preload', 'remove-files', 'version', 'help')][string]$Command = 'help',
    [string]$SourceDir,
    [string[]]$Database = @(),
    [switch]$AllDatabases,
    [switch]$SkipCreateExtension,
    [switch]$NoEnable,
    [switch]$NoRestart,
    [switch]$Yes,
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
    [int]$RestartTimeout = 60,
    [ValidateSet('text', 'json')][string]$Format = 'text',
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Command -eq 'help') { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
if ($PSBoundParameters['Verbose']) { $env:AAV_VERBOSE = '1' }
Import-Module (Join-Path $PSScriptRoot 'AdaptiveAutovacuum.Setup.psm1') -Force
if ($Command -eq 'version') { Write-Output $SetupVersion; exit 0 }
if ($PgPassFile -and -not (Test-Path $PgPassFile)) { Write-Error "-PgPassFile not found: $PgPassFile"; exit 2 }

$P = @{
    SourceDir = $SourceDir; Database = $Database; AllDatabases = [bool]$AllDatabases; SkipCreateExtension = [bool]$SkipCreateExtension
    NoEnable = [bool]$NoEnable; NoRestart = [bool]$NoRestart; Yes = [bool]$Yes; DryRun = [bool]$DryRun; PgMajor = $PgMajor
    PgRoot = $PgRoot; ServiceName = $ServiceName; DataDirectory = $DataDirectory; Port = $Port; DbUser = $DbUser
    Credential = $Credential; PgPassFile = $PgPassFile; StartupWait = $StartupWait; RestartTimeout = $RestartTimeout
    Json = ($Json -or $Format -eq 'json')
}
try {
    $rc = switch ($Command) {
        'check' { Invoke-AavCheck -P $P }
        'install' { Invoke-AavInstall -P $P }
        'doctor' { Invoke-AavDoctor -P $P }
        'enable' { Set-AavControllerEnabled -P $P -Enabled $true }
        'disable' { Set-AavControllerEnabled -P $P -Enabled $false }
        'remove-preload' { Remove-AavPreload -P $P }
        'remove-files' { Remove-AavFiles -P $P }
    }
    # Functions may emit JSON text before the return code; the code is the last value.
    if ($rc -is [array]) { $rc | Select-Object -SkipLast 1 | ForEach-Object { Write-Output $_ }; $rc = $rc[-1] }
    exit [int]$rc
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $code = Get-AavExitCode $_
    if ($null -eq $code) { if ($VerbosePreference -ne 'SilentlyContinue') { Write-Host $_.ScriptStackTrace }; $code = 8 }
    exit $code
}
