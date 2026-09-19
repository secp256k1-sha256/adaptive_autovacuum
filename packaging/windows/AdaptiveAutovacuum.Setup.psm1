#Requires -Version 5.1
# AdaptiveAutovacuum.Setup: discovery, file installation, preload configuration, restart with
# rollback, activation and health checks for the adaptive_autovacuum extension on Windows.
# Same behavioural contract and exit codes as packaging/linux/adaptive-autovacuum-setup.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SetupVersion = '1.1.0'
$script:ExtName = 'adaptive_autovacuum'
$script:SupportedMajors = @(17, 18)
if ($env:AAV_SUPPORTED_MAJORS) { $script:SupportedMajors = @($env:AAV_SUPPORTED_MAJORS -split '[ ,]+' | ForEach-Object { [int]$_ }) }
$script:StateDir = if ($env:AAV_STATE_DIR) { $env:AAV_STATE_DIR } else { Join-Path $env:ProgramData 'adaptive_autovacuum' }
$script:StateFile = Join-Path $script:StateDir 'installer-state.json'
$script:LogFile = Join-Path $script:StateDir 'setup.log'
$script:ProgramDir = Join-Path $env:ProgramFiles 'adaptive_autovacuum'
$script:US = [char]0x1f
$script:RunId = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $PID
$script:Quiet = $false

$script:ExitCodes = @{
    Ok = 0; Args = 2; NoPg = 3; Ambiguous = 4; Unsupported = 5; Download = 6
    Privilege = 7; ConfigFailed = 8; Restart = 9; Health = 10
}

# Typed failure: the exit code travels in Exception.Data so callers outside the module can read it.
function Stop-Aav([int]$Code, [string]$Message) {
    $ex = New-Object System.InvalidOperationException $Message
    $ex.Data['AavExitCode'] = $Code
    throw $ex
}
function Get-AavExitCode($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e) { if ($e.Data -and $e.Data.Contains('AavExitCode')) { return [int]$e.Data['AavExitCode'] }; $e = $e.InnerException }
    return $null
}

# ---------------------------------------------------------------- output
function Write-AavLine([string]$Text) {
    if (-not $script:Quiet) { Write-Host $Text }
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
        Add-Content -Path $script:LogFile -Value ('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Text) -Encoding UTF8
    } catch { }
}
function Write-AavOk([string]$Text)   { Write-AavLine "[OK]   $Text" }
function Write-AavWarn([string]$Text) { Write-AavLine "[WARN] $Text" }
function Write-AavFail([string]$Text) { Write-AavLine "[FAIL] $Text" }
function Write-AavVerbose([string]$Text) {
    if ($VerbosePreference -ne 'SilentlyContinue' -or $env:AAV_VERBOSE -eq '1') { Write-AavLine "[..]   $Text" }
    else { try { Add-Content -Path $script:LogFile -Value ('{0} [..] {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Text) -Encoding UTF8 } catch { } }
}

function Test-AavInteractive { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
function Confirm-Aav([string]$Question, [bool]$Yes) {
    if ($Yes) { Write-AavLine "$Question [Y/n] yes (-Yes)"; return $true }
    if (-not (Test-AavInteractive)) { Write-AavLine "$Question [Y/n] no (non-interactive; pass -Yes)"; return $false }
    $a = Read-Host "$Question [Y/n]"
    return ([string]::IsNullOrWhiteSpace($a) -or $a -match '^[Yy]')
}
function Test-AavAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-AavAdministrator { if (-not (Test-AavAdministrator)) { Stop-Aav $script:ExitCodes.Privilege 'run this from an elevated (Administrator) PowerShell' } }

# ---------------------------------------------------------------- journal
$script:Journal = $null
function Set-AavRestrictedAcl([string]$Path) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $acl = New-Object System.Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = if (Test-Path -LiteralPath $Path -PathType Container) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    foreach ($sid in @([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, [Security.Principal.WellKnownSidType]::LocalSystemSid)) {
        $ident = New-Object System.Security.Principal.SecurityIdentifier($sid, $null)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($ident, 'FullControl', $inherit, 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Initialize-AavJournal([string]$Command) {
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null; Set-AavRestrictedAcl $script:StateDir }
    if (Test-Path $script:StateFile) {
        try {
            $prev = Get-Content -Raw $script:StateFile | ConvertFrom-Json
            $prevState = Get-AavProp $prev 'final_state'
            if ($prevState -notin @('completed', 'restart_required', 'disabled', 'preload_removed', 'dry_run', 'cancelled', 'aborted', 'rolled_back')) {
                Write-AavWarn "previous run $(Get-AavProp $prev 'run_id') ended in state '$prevState'; the host state is re-verified before every step"
            }
        } catch { Write-AavWarn 'previous installer state file is unreadable' }
        $hist = Join-Path $script:StateDir 'history'
        if (-not (Test-Path $hist)) { New-Item -ItemType Directory -Path $hist | Out-Null }
        Copy-Item $script:StateFile (Join-Path $hist ('installer-state.{0}.json' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')))
    }
    $script:Journal = [ordered]@{
        installer_version = $script:SetupVersion; run_id = $script:RunId; command = $Command
        started_at = (Get-Date).ToUniversalTime().ToString('o'); steps = @(); final_state = 'started'; mutated = $false
    }
    Save-AavJournal
}
function Save-AavJournal {
    if ($null -eq $script:Journal) { return }
    $tmp = "$($script:StateFile).tmp.$PID"
    [IO.File]::WriteAllText($tmp, ($script:Journal | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp $script:StateFile
}
function Set-AavJournal([string]$Key, $Value) { if ($null -ne $script:Journal) { $script:Journal[$Key] = $Value; Save-AavJournal } }
function Add-AavJournalStep([string]$Name, [string]$Status, [string]$Detail = '') {
    if ($null -eq $script:Journal) { return }
    $script:Journal.steps += @([ordered]@{ name = $Name; status = $Status; detail = $Detail; at = (Get-Date).ToUniversalTime().ToString('o') })
    Save-AavJournal
}
function Complete-AavJournal([string]$State) {
    if ($null -eq $script:Journal) { return }
    $script:Journal.final_state = $State; $script:Journal.finished_at = (Get-Date).ToUniversalTime().ToString('o'); Save-AavJournal
}
function Close-AavJournalOnExit {
    if ($null -ne $script:Journal -and $script:Journal.final_state -eq 'started') {
        Complete-AavJournal $(if ($script:Journal.mutated) { 'interrupted' } else { 'aborted' })
    }
}

# ---------------------------------------------------------------- discovery
function Get-AavCanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [IO.Path]::GetFullPath($Path.Trim().Trim('"')).TrimEnd('\') } catch { return $Path }
}
function Split-AavServicePath([string]$PathName) {
    # "C:\Program Files\...\pg_ctl.exe" runservice -N "postgresql-x64-18" -D "C:\Program Files\...\data" -w
    $exe = $null; $data = $null
    if ($PathName -match '^\s*"([^"]+)"') { $exe = $Matches[1] } elseif ($PathName -match '^\s*(\S+)') { $exe = $Matches[1] }
    if ($PathName -match '-D\s+"([^"]+)"') { $data = $Matches[1] } elseif ($PathName -match '-D\s+(\S+)') { $data = $Matches[1] }
    return @{ Exe = $exe; DataDirectory = $data }
}
function Invoke-AavTool([string]$Exe, [string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = (ConvertTo-AavArgumentString $Arguments)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Output = $out.Trim(); Error = $err.Trim() }
}
# Windows command-line quoting (MSVCRT rules) so paths with spaces and quotes survive intact.
function ConvertTo-AavArgumentString([string[]]$Arguments) {
    $parts = foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        if ($a -eq '' -or $a -match '[\s"]') {
            $sb = New-Object Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
            foreach ($ch in $a.ToCharArray()) {
                if ($ch -eq '\') { $bs++ }
                elseif ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0 }
                else { if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }; [void]$sb.Append($ch) }
            }
            if ($bs) { [void]$sb.Append('\' * ($bs * 2)) }
            [void]$sb.Append('"'); $sb.ToString()
        } else { $a }
    }
    return ($parts -join ' ')
}

function New-AavCandidate {
    return [ordered]@{
        candidate_id = $null; postgres_major = $null; postgres_full_version = $null; architecture = $env:PROCESSOR_ARCHITECTURE
        install_root = $null; pg_config_path = $null; psql_path = $null; pg_ctl_path = $null; pkglibdir = $null; sharedir = $null
        data_directory = $null; config_file = $null; port = $null; service_name = $null; service_manager = 'windows-service'
        service_account = $null; running_state = 'unknown'; connection_verified = $false; discovery_sources = @()
        pid = $null; shared_preload_libraries = $null; in_recovery = $null; db_user = $null; db_superuser = $null
        allow_alter_system = $null; postmaster_start_epoch = $null; supported = $false; inconsistent = $null
        conn_host = $null; conn_user = $null; sql_major = $null
    }
}
# Property read that tolerates a missing member under Set-StrictMode (JSON objects and hashtables).
function Get-AavProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $p = $Object.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null
}
function Merge-AavCandidate([System.Collections.ArrayList]$List, $New) {
    $key = Get-AavCanonicalPath $New.data_directory
    foreach ($c in $List) {
        if ($null -ne $key -and (Get-AavCanonicalPath $c.data_directory) -ieq $key) {
            foreach ($k in $New.Keys) { if ($k -ne 'discovery_sources' -and $null -ne $New[$k] -and $New[$k] -ne '' -and ($null -eq $c[$k] -or $c[$k] -eq '' -or $c[$k] -eq 'unknown')) { $c[$k] = $New[$k] } }
            $c.discovery_sources = @($c.discovery_sources + $New.discovery_sources | Select-Object -Unique)
            return
        }
        if ($null -eq $key -and $null -eq $c.data_directory -and $c.install_root -ieq $New.install_root) {
            $c.discovery_sources = @($c.discovery_sources + $New.discovery_sources | Select-Object -Unique); return
        }
    }
    [void]$List.Add($New)
}

function Get-AavCandidates {
    [CmdletBinding()]
    param([string]$PgRoot, [string]$ServiceName, [string]$DataDirectory, [int]$Port, [string]$DbUser = 'postgres',
          [System.Management.Automation.PSCredential]$Credential, [string]$PgPassFile, [string]$HostName = 'localhost')
    $list = New-Object System.Collections.ArrayList

    # 1. Windows services (CIM): the authoritative link between binaries, data directory and service name.
    foreach ($svc in @(Get-CimInstance Win32_Service | Where-Object { $_.Name -like 'postgresql*' -or $_.PathName -match 'postgres(\.exe)?|pg_ctl(\.exe)?' })) {
        $parsed = Split-AavServicePath $svc.PathName
        if (-not $parsed.Exe) { continue }
        $c = New-AavCandidate
        $c.service_name = $svc.Name; $c.service_account = $svc.StartName
        $c.running_state = if ($svc.State -eq 'Running') { 'running' } else { 'stopped' }
        $c.install_root = Get-AavCanonicalPath (Split-Path (Split-Path $parsed.Exe -Parent) -Parent)
        $c.data_directory = Get-AavCanonicalPath $parsed.DataDirectory
        if ($svc.ProcessId) { $c.pid = [int]$svc.ProcessId }
        $c.discovery_sources = @('service')
        Write-AavVerbose "service: $($svc.Name) $($svc.State) root=$($c.install_root) data=$($c.data_directory)"
        Merge-AavCandidate $list $c
    }
    # 2. EDB registry (both views): hints, validated below.
    foreach ($base in @('HKLM:\SOFTWARE\PostgreSQL\Installations', 'HKLM:\SOFTWARE\WOW6432Node\PostgreSQL\Installations')) {
        if (-not (Test-Path $base)) { continue }
        foreach ($k in Get-ChildItem $base) {
            $p = Get-ItemProperty $k.PSPath
            $c = New-AavCandidate
            $c.install_root = Get-AavCanonicalPath $p.'Base Directory'; $c.data_directory = Get-AavCanonicalPath $p.'Data Directory'
            $c.service_name = $p.'Service ID'; $c.service_account = $p.'Service Account'; $c.discovery_sources = @('registry')
            $svcKey = $base -replace 'Installations$', "Services\$($k.PSChildName)"
            if (Test-Path $svcKey) { $sp = Get-ItemProperty $svcKey; if ($sp.Port) { $c.port = [int]$sp.Port }; if ($sp.'Data Directory') { $c.data_directory = Get-AavCanonicalPath $sp.'Data Directory' } }
            if (-not $c.install_root -or -not (Test-Path (Join-Path $c.install_root 'bin\pg_config.exe'))) { Write-AavVerbose "registry: $($k.PSChildName) points to a missing installation ($($c.install_root)); stale entry ignored"; continue }
            Write-AavVerbose "registry: $($k.PSChildName) root=$($c.install_root) data=$($c.data_directory) port=$($c.port)"
            Merge-AavCandidate $list $c
        }
    }
    # 3. Deterministic fallback directories and explicit -PgRoot.
    $roots = @(Get-ChildItem "$env:ProgramFiles\PostgreSQL" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    if ($PgRoot) { $roots += $PgRoot }
    foreach ($r in $roots) {
        $root = Get-AavCanonicalPath $r
        if (-not (Test-Path (Join-Path $root 'bin\pg_config.exe'))) { continue }
        if ($list | Where-Object { $_.install_root -ieq $root }) { continue }
        $c = New-AavCandidate; $c.install_root = $root; $c.discovery_sources = @('directory')
        if (Test-Path (Join-Path $root 'data\PG_VERSION')) { $c.data_directory = Join-Path $root 'data' }
        Merge-AavCandidate $list $c
    }
    if ($DataDirectory) { $c = New-AavCandidate; $c.data_directory = Get-AavCanonicalPath $DataDirectory; $c.discovery_sources = @('argument'); Merge-AavCandidate $list $c }

    # 4. Validate binaries and read cluster facts from the data directory.
    foreach ($c in $list) {
        if ($c.install_root) {
            $pgc = Join-Path $c.install_root 'bin\pg_config.exe'
            if (Test-Path $pgc) {
                $c.pg_config_path = $pgc; $c.psql_path = Join-Path $c.install_root 'bin\psql.exe'; $c.pg_ctl_path = Join-Path $c.install_root 'bin\pg_ctl.exe'
                $v = Invoke-AavTool $pgc @('--version')
                if ($v.ExitCode -eq 0 -and $v.Output -match 'PostgreSQL (\d+)(\.\d+)?') { $c.postgres_major = [int]$Matches[1]; $c.postgres_full_version = ($v.Output -replace '^PostgreSQL\s+', '') -replace '\s.*$', '' }
                $c.pkglibdir = Get-AavCanonicalPath (Invoke-AavTool $pgc @('--pkglibdir')).Output
                $c.sharedir = Get-AavCanonicalPath (Invoke-AavTool $pgc @('--sharedir')).Output
                $pgexe = Join-Path $c.install_root 'bin\postgres.exe'
                if (Test-Path $pgexe) { $pv = Invoke-AavTool $pgexe @('--version'); if ($pv.ExitCode -eq 0 -and $pv.Output -match 'PostgreSQL (\d+)' -and $c.postgres_major -and [int]$Matches[1] -ne $c.postgres_major) { $c.inconsistent = "postgres.exe is major $($Matches[1]) but pg_config is $($c.postgres_major)" } }
            }
        }
        if ($c.data_directory -and (Test-Path $c.data_directory)) {
            $pgver = Join-Path $c.data_directory 'PG_VERSION'
            if (Test-Path $pgver) { $dm = [int]((Get-Content $pgver -Raw).Trim() -replace '\..*$', ''); if ($c.postgres_major -and $dm -ne $c.postgres_major) { $c.inconsistent = "data directory is major $dm but binaries are $($c.postgres_major)" } elseif (-not $c.postgres_major) { $c.postgres_major = $dm } }
            $pidfile = Join-Path $c.data_directory 'postmaster.pid'
            if (Test-Path $pidfile) {
                $lines = Get-Content $pidfile
                if ($lines.Count -ge 4 -and $lines[0] -match '^\d+$' -and (Get-Process -Id ([int]$lines[0]) -ErrorAction SilentlyContinue)) {
                    $c.pid = [int]$lines[0]; $c.port = [int]$lines[3]; $c.running_state = 'running'
                } elseif ($c.running_state -ne 'running') { $c.running_state = 'stopped' }
            } elseif ($c.running_state -eq 'unknown') { $c.running_state = 'stopped' }
            $c.config_file = Join-Path $c.data_directory 'postgresql.conf'
        }
        $c.supported = ($c.postgres_major -in $script:SupportedMajors)
    }
    # 5. SQL interrogation of running candidates (authoritative facts).
    $i = 0
    foreach ($c in $list) {
        $c.candidate_id = 'pg{0}-{1}-{2}' -f $(if ($c.postgres_major) { $c.postgres_major } else { 0 }), $(if ($c.port) { $c.port } else { 0 }), $i; $i++
        if ($c.running_state -ne 'running' -or -not $c.psql_path -or -not (Test-Path $c.psql_path)) { continue }
        $connPort = if ($Port) { $Port } elseif ($c.port) { $c.port } else { 5432 }
        try {
            $facts = Get-AavServerFacts -Candidate $c -HostName $HostName -Port $connPort -DbUser $DbUser -Credential $Credential -PgPassFile $PgPassFile
            if ($facts) {
                $c.connection_verified = $true; $c.port = $connPort; $c.conn_host = $HostName; $c.conn_user = $facts.user
                $c.postgres_full_version = $facts.server_version; $c.config_file = $facts.config_file; $c.shared_preload_libraries = $facts.shared_preload_libraries
                $c.in_recovery = $facts.in_recovery; $c.db_user = $facts.user; $c.db_superuser = $facts.superuser; $c.allow_alter_system = $facts.allow_alter_system
                $c.postmaster_start_epoch = $facts.start_epoch; $c.sql_major = [int]($facts.server_version_num / 10000)
                if ($c.postgres_major -and $c.sql_major -ne $c.postgres_major) { $c.inconsistent = "server major $($c.sql_major) but binaries major $($c.postgres_major)" }
                if ((Get-AavCanonicalPath $facts.data_directory) -ine (Get-AavCanonicalPath $c.data_directory)) { Write-AavVerbose "candidate $($c.candidate_id): SQL data_directory $($facts.data_directory) differs from discovered $($c.data_directory)" }
            }
        } catch { Write-AavVerbose "candidate $($c.candidate_id): no connection ($($_.Exception.Message))" }
    }
    return @($list)
}

# ---------------------------------------------------------------- psql
$script:FactsSql = "SELECT current_setting('server_version_num')::int, current_setting('server_version'), current_setting('data_directory'), current_setting('config_file'), current_setting('port')::int, current_setting('shared_preload_libraries'), pg_is_in_recovery(), current_setting('hba_file'), current_user, (SELECT rolsuper FROM pg_roles WHERE rolname = current_user), coalesce(current_setting('allow_alter_system', true), 'on'), extract(epoch FROM pg_postmaster_start_time())::bigint"

function New-AavPgPassFile([System.Management.Automation.PSCredential]$Credential, [string]$HostName, [int]$Port) {
    # Unique temp file, ACL restricted to the current user, deleted by the caller in finally.
    $path = Join-Path ([IO.Path]::GetTempPath()) ('aav-pgpass-' + [Guid]::NewGuid().ToString('N'))
    $esc = { param($s) ($s -replace '\\', '\\') -replace ':', '\:' }
    $pw = $Credential.GetNetworkCredential().Password
    $line = '{0}:{1}:*:{2}:{3}' -f (& $esc $HostName), $Port, (& $esc $Credential.UserName), (& $esc $pw)
    [IO.File]::WriteAllText($path, $line + "`n", (New-Object Text.UTF8Encoding $false))
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
    return $path
}

function Invoke-AavPsql {
    # SQL goes through stdin (-f -): no command-line quoting issues and psql variables work.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate, [string]$Database = 'postgres', [Parameter(Mandatory)][string]$Sql,
          [hashtable]$Variables = @{}, [string]$HostName = 'localhost', [int]$Port, [string]$DbUser,
          [System.Management.Automation.PSCredential]$Credential, [string]$PgPassFile, [switch]$NoPassword)
    if (-not $Port) { $Port = if ($Candidate.port) { $Candidate.port } else { 5432 } }
    if (-not $DbUser) { $DbUser = if ($Credential) { $Credential.UserName } elseif ($Candidate.conn_user) { $Candidate.conn_user } else { 'postgres' } }
    if ($Candidate.conn_host) { $HostName = $Candidate.conn_host }
    $argv = @('-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-F', [string]$script:US, '-h', $HostName, '-p', [string]$Port, '-U', $DbUser, '-d', $Database, '-f', '-')
    if ($NoPassword -or -not (Test-AavInteractive)) { $argv += '--no-password' }
    foreach ($k in $Variables.Keys) { $argv += @('-v', ('{0}={1}' -f $k, $Variables[$k])) }
    $tmpPass = $null
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Candidate.psql_path; $psi.Arguments = ConvertTo-AavArgumentString $argv
        $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        if ($Credential) { $tmpPass = New-AavPgPassFile $Credential $HostName $Port; $psi.EnvironmentVariables['PGPASSFILE'] = $tmpPass }
        elseif ($PgPassFile) { $psi.EnvironmentVariables['PGPASSFILE'] = $PgPassFile }
        elseif ($script:DefaultCredential) { $tmpPass = New-AavPgPassFile $script:DefaultCredential $HostName $Port; $psi.EnvironmentVariables['PGPASSFILE'] = $tmpPass }
        elseif ($script:DefaultPgPassFile) { $psi.EnvironmentVariables['PGPASSFILE'] = $script:DefaultPgPassFile }
        $psi.EnvironmentVariables['PGCLIENTENCODING'] = 'UTF8'
        Write-AavVerbose ("psql db={0} {1}" -f $Database, ($Sql -replace '\s+', ' ').Substring(0, [Math]::Min(120, $Sql.Length)))
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($Sql); $p.StandardInput.Write("`n"); $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "psql failed (exit $($p.ExitCode)): $($err.Trim())" }
        return $out.TrimEnd("`r", "`n")
    } finally { if ($tmpPass -and (Test-Path $tmpPass)) { Remove-Item -Force $tmpPass -ErrorAction SilentlyContinue } }
}
$script:DefaultCredential = $null
$script:DefaultPgPassFile = $null
function Set-AavDefaultAuthentication([System.Management.Automation.PSCredential]$Credential, [string]$PgPassFile) {
    $script:DefaultCredential = $Credential; $script:DefaultPgPassFile = $PgPassFile
}

function Get-AavServerFacts($Candidate, [string]$HostName, [int]$Port, [string]$DbUser, $Credential, [string]$PgPassFile) {
    $out = Invoke-AavPsql -Candidate $Candidate -Sql $script:FactsSql -HostName $HostName -Port $Port -DbUser $DbUser -Credential $Credential -PgPassFile $PgPassFile
    if (-not $out) { return $null }
    $f = $out.Split($script:US)
    return @{ server_version_num = [int]$f[0]; server_version = $f[1]; data_directory = $f[2]; config_file = $f[3]; port = [int]$f[4]
              shared_preload_libraries = $f[5]; in_recovery = ($f[6] -eq 't'); hba_file = $f[7]; user = $f[8]; superuser = ($f[9] -eq 't')
              allow_alter_system = $f[10]; start_epoch = [long]$f[11] }
}

# ---------------------------------------------------------------- selection
function Select-AavCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Candidates, [string]$PgRoot, [string]$ServiceName, [string]$DataDirectory, [int]$Port, [int]$PgMajor, [switch]$Yes)
    $f = @($Candidates)
    if ($PgMajor) { $f = @($f | Where-Object { $_.postgres_major -eq $PgMajor }) }
    if ($PgRoot) { $r = Get-AavCanonicalPath $PgRoot; $f = @($f | Where-Object { $_.install_root -ieq $r }) }
    if ($ServiceName) { $f = @($f | Where-Object { $_.service_name -ieq $ServiceName }) }
    if ($DataDirectory) { $d = Get-AavCanonicalPath $DataDirectory; $f = @($f | Where-Object { (Get-AavCanonicalPath $_.data_directory) -ieq $d }) }
    if ($Port) { $f = @($f | Where-Object { $_.port -eq $Port }) }
    $supported = @($f | Where-Object { $_.supported -and -not $_.inconsistent })
    if ($supported.Count -eq 0) {
        Write-AavLine "No supported PostgreSQL cluster found (supported majors: $($script:SupportedMajors -join ', ')). Discovered:"
        Format-AavCandidates $Candidates
        Stop-Aav $script:ExitCodes.NoPg 'no supported PostgreSQL cluster'
    }
    if ($supported.Count -eq 1) { return $supported[0] }
    $running = @($supported | Where-Object { $_.running_state -eq 'running' })
    if ($running.Count -eq 1) { return $running[0] }
    Write-AavLine 'Several supported clusters match; choose one:'
    Format-AavCandidates $supported
    if ((Test-AavInteractive) -and -not $Yes) {
        for ($i = 0; $i -lt $supported.Count; $i++) { Write-AavLine ("  {0}) {1}" -f ($i + 1), $supported[$i].candidate_id) }
        $choice = Read-Host 'Cluster number'
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $supported.Count) { return $supported[[int]$choice - 1] }
        Stop-Aav $script:ExitCodes.Ambiguous 'no cluster selected'
    }
    Stop-Aav $script:ExitCodes.Ambiguous 'ambiguous discovery: pass -ServiceName, -DataDirectory, -PgRoot or -Port to select one'
}
function Format-AavCandidates([object[]]$Candidates) {
    if (-not $Candidates -or $Candidates.Count -eq 0) { Write-AavLine '  (none)'; return }
    foreach ($c in $Candidates) {
        $flags = @(); if (-not $c.supported) { $flags += 'unsupported major' }; if ($c.inconsistent) { $flags += $c.inconsistent }
        Write-AavLine ("  [{0}] PostgreSQL {1}  port {2}  {3}  {4}  {5}{6}" -f $c.candidate_id, $(if ($c.postgres_full_version) { $c.postgres_full_version } else { $c.postgres_major }),
            $(if ($c.port) { $c.port } else { '?' }), $c.running_state, $(if ($c.service_name) { $c.service_name } else { 'no service' }),
            $(if ($c.data_directory) { $c.data_directory } else { $c.install_root + ' (no cluster)' }), $(if ($flags) { '  (' + ($flags -join '; ') + ')' } else { '' }))
    }
}
function Write-AavSelected($c) {
    Write-AavLine 'Detected PostgreSQL:'
    Write-AavLine "  Version:          $($c.postgres_full_version)"
    Write-AavLine "  Architecture:     $($c.architecture)"
    Write-AavLine "  Service:          $($c.service_name)"
    Write-AavLine "  Data directory:   $($c.data_directory)"
    Write-AavLine "  Config file:      $($c.config_file)"
    Write-AavLine "  Port:             $($c.port)  state: $($c.running_state)  connection: $(if ($c.connection_verified) { 'verified as ' + $c.conn_user } else { 'not verified' })"
    Write-AavLine "  Binaries:         $($c.install_root)  lib=$($c.pkglibdir)  share=$($c.sharedir)"
    Write-AavLine "  Preload now:      '$($c.shared_preload_libraries)'"
    if ($c.in_recovery) { Write-AavWarn '  this server is in recovery (standby)' }
}

# ---------------------------------------------------------------- preload helpers
function Test-AavPreloadLists([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($e in $Value.Split(',')) {
        $t = $e.Trim().Trim('"', "'") -replace '^\$libdir[/\\]', '' -replace '\.(so|dll)$', ''
        if ($t -eq $script:ExtName) { return $true }
    }
    return $false
}
function Get-AavPreloadAppend([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return $script:ExtName }; return ($Value.Trim() + ',' + $script:ExtName) }
function Get-AavPreloadRemove([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $keep = foreach ($e in $Value.Split(',')) { $t = $e.Trim(); if ($t -and -not (Test-AavPreloadLists $t)) { $t } }
    return (@($keep) -join ',')
}
function Set-AavPreloadValue($Candidate, [string]$Value) {
    # An empty list must be RESET: ALTER SYSTEM SET x = '' stores '""' and the server fails to start.
    if (-not [string]::IsNullOrEmpty($Value)) { Invoke-AavPsql -Candidate $Candidate -Sql "ALTER SYSTEM SET shared_preload_libraries = :'v';" -Variables @{ v = $Value } | Out-Null; return }
    $other = Invoke-AavPsql -Candidate $Candidate -Sql "SELECT coalesce((SELECT setting FROM pg_file_settings WHERE name = 'shared_preload_libraries' AND sourcefile NOT LIKE '%postgresql.auto.conf' ORDER BY seqno DESC LIMIT 1), '')"
    if ($other -and (Test-AavPreloadLists $other)) { Stop-Aav $script:ExitCodes.ConfigFailed "shared_preload_libraries = '$other' is also set outside postgresql.auto.conf; remove $($script:ExtName) there by hand and restart" }
    if ($other) { Write-AavWarn "postgresql.auto.conf entry removed; '$other' from the main configuration file applies after the restart" }
    Invoke-AavPsql -Candidate $Candidate -Sql 'ALTER SYSTEM RESET shared_preload_libraries;' | Out-Null
}
function Get-AavFileSha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# ---------------------------------------------------------------- files
function Get-AavInstalledDefaultVersion($Candidate) {
    $ctl = Join-Path $Candidate.sharedir "extension\$($script:ExtName).control"
    if (-not (Test-Path $ctl)) { return $null }
    $m = Select-String -Path $ctl -Pattern "^default_version\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}
function Test-AavFilesInstalled($Candidate) {
    return ((Test-Path (Join-Path $Candidate.pkglibdir "$($script:ExtName).dll")) -and (Test-Path (Join-Path $Candidate.sharedir "extension\$($script:ExtName).control")))
}
function Compare-AavVersion([string]$A, [string]$B) {
    $ka = [version](($A -replace '[^0-9.].*$', '') + $(if (($A -split '\.').Count -lt 2) { '.0' } else { '' }))
    $kb = [version](($B -replace '[^0-9.].*$', '') + $(if (($B -split '\.').Count -lt 2) { '.0' } else { '' }))
    return $ka.CompareTo($kb)
}
function Copy-AavFileAtomic([string]$Source, [string]$Destination) {
    # Copy to a temp name in the destination directory, verify, then rename into place.
    # A DLL mapped by a running postmaster cannot be replaced, but it can be renamed aside.
    $dir = Split-Path $Destination -Parent
    $tmp = Join-Path $dir ("$(Split-Path $Destination -Leaf).aav-new-$PID")
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    if ((Get-AavFileSha256 $tmp) -ne (Get-AavFileSha256 $Source)) { Remove-Item -Force $tmp; throw "copy verification failed for $Destination" }
    $renamedAside = $null
    if (Test-Path -LiteralPath $Destination) {
        try { Move-Item -LiteralPath $tmp -Destination $Destination -Force }
        catch {
            $renamedAside = "$Destination.old-$($script:RunId)"
            Move-Item -LiteralPath $Destination -Destination $renamedAside -Force
            Move-Item -LiteralPath $tmp -Destination $Destination -Force
        }
    } else { Move-Item -LiteralPath $tmp -Destination $Destination -Force }
    return $renamedAside
}
function Install-AavFiles {
    # SourceDir = expanded release ZIP with artifact-manifest.json; every file hash is verified first.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)][string]$SourceDir, [switch]$DryRun)
    $manifestPath = Join-Path $SourceDir 'artifact-manifest.json'
    if (-not (Test-Path $manifestPath)) { Stop-Aav $script:ExitCodes.Download "artifact-manifest.json missing in $SourceDir" }
    $m = Get-Content -Raw $manifestPath | ConvertFrom-Json
    if ([int]$m.postgres_major -ne [int]$Candidate.postgres_major) { Stop-Aav $script:ExitCodes.Unsupported "the package is built for PostgreSQL $($m.postgres_major) but the selected installation is $($Candidate.postgres_major)" }
    if ($m.architecture -ne 'x64' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Stop-Aav $script:ExitCodes.Unsupported "the package is $($m.architecture) but this host is $env:PROCESSOR_ARCHITECTURE" }
    foreach ($f in $m.files) {
        if ($f.path -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($f.path)) { Stop-Aav $script:ExitCodes.Download "artifact manifest contains an unsafe path: $($f.path)" }
        $p = Join-Path $SourceDir $f.path
        if (-not (Test-Path -LiteralPath $p)) { Stop-Aav $script:ExitCodes.Download "file listed in artifact manifest is missing: $($f.path)" }
        if ((Get-AavFileSha256 $p) -ne $f.sha256.ToLowerInvariant()) { Stop-Aav $script:ExitCodes.Download "checksum mismatch inside the package: $($f.path)" }
    }
    Write-AavOk "package contents verified ($($m.files.Count) files, extension $($m.extension_version) for PostgreSQL $($m.postgres_major))"
    $installedVer = Get-AavInstalledDefaultVersion $Candidate
    if ($installedVer -and (Compare-AavVersion $installedVer $m.extension_version) -gt 0) { Stop-Aav $script:ExitCodes.ConfigFailed "installed extension files are $installedVer, newer than the package ($($m.extension_version)); refusing to downgrade" }
    $plan = @()
    foreach ($f in $m.files) {
        $leaf = Split-Path $f.path -Leaf
        $dest = switch -Regex ($leaf) {
            '\.dll$' { Join-Path $Candidate.pkglibdir $leaf }
            '\.(control|sql)$' { Join-Path $Candidate.sharedir "extension\$leaf" }
            default { Join-Path (Join-Path $script:ProgramDir $m.extension_version) $leaf }
        }
        $plan += @{ Source = (Join-Path $SourceDir $f.path); Dest = $dest }
    }
    if ($DryRun) { foreach ($p in $plan) { Write-AavLine "  would install $($p.Dest)" }; return $m }
    $backups = @()
    foreach ($p in $plan) {
        $dir = Split-Path $p.Dest -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $p.Dest)) { $backups += @{ path = $p.Dest; sha256 = (Get-AavFileSha256 $p.Dest) } }
        $aside = Copy-AavFileAtomic $p.Source $p.Dest
        if ($aside) { Write-AavVerbose "in-use file renamed aside: $aside (removed after the restart)"; $backups[-1].renamed_to = $aside }
    }
    Set-AavJournal 'file_backups' $backups
    Set-AavJournal 'installed_files' @($plan | ForEach-Object { $_.Dest })
    Add-AavJournalStep 'files' 'done' "$($plan.Count) files"
    Write-AavOk "extension files installed ($($Candidate.pkglibdir), $($Candidate.sharedir)\extension, $script:ProgramDir\$($m.extension_version))"
    return $m
}
function Remove-AavRenamedAside {
    if ($null -eq $script:Journal -or -not $script:Journal.Contains('file_backups')) { return }
    foreach ($b in $script:Journal.file_backups) { $r = Get-AavProp $b 'renamed_to'; if ($r -and (Test-Path -LiteralPath $r)) { Remove-Item -LiteralPath $r -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------- restart
function Wait-AavReady($Candidate, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-AavPsql -Candidate $Candidate -Sql 'SELECT 1' -NoPassword:$false) -eq '1') { return $true } } catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}
function Restart-AavService($Candidate, [int]$TimeoutSeconds) {
    if (-not $Candidate.service_name) { Stop-Aav $script:ExitCodes.Restart 'the selected cluster has no Windows service; restart it by hand and rerun' }
    Write-AavLine "Restarting service $($Candidate.service_name) ..."
    try { Restart-Service -Name $Candidate.service_name -Force -ErrorAction Stop } catch { Write-AavWarn "Restart-Service failed: $($_.Exception.Message)" }
    return (Wait-AavReady $Candidate $TimeoutSeconds)
}
function Write-AavLogExcerpt($Candidate) {
    Write-AavLine '--- recent server log ---'
    $logdir = Join-Path $Candidate.data_directory 'log'
    if (Test-Path $logdir) { $latest = Get-ChildItem $logdir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($latest) { Get-Content $latest.FullName -Tail 25 | ForEach-Object { Write-AavLine "  $_" } } }
    try { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PostgreSQL' } -MaxEvents 10 -ErrorAction Stop | ForEach-Object { Write-AavLine "  [eventlog] $($_.TimeCreated) $($_.Message.Split("`n")[0])" } } catch { }
    Write-AavLine '--- end of log ---'
}

# ---------------------------------------------------------------- doctor
function Get-AavDoctor($Candidate, [string]$Database) {
    # A database still on a version without doctor() gets one synthetic row instead of aborting the run.
    try { $out = Invoke-AavPsql -Candidate $Candidate -Database $Database -Sql "SELECT check_name, status, detail, coalesce(remediation, '') FROM $($script:ExtName).doctor()" }
    catch {
        $ver = Get-AavExtensionVersion $Candidate $Database
        return @([pscustomobject]@{ check_name = 'doctor_api'; status = 'WARN'; detail = "installed extension $ver in $Database has no doctor() (pre-1.1.0 objects); health cannot be evaluated here"
                                    remediation = "ALTER EXTENSION $($script:ExtName) UPDATE;  (development snapshots older than 1.0.0 need DROP EXTENSION + CREATE EXTENSION)" })
    }
    $rows = @()
    foreach ($line in ($out -split "`r?`n")) { if (-not $line) { continue }; $f = $line.Split($script:US); $rows += [pscustomobject]@{ check_name = $f[0]; status = $f[1]; detail = $f[2]; remediation = $f[3] } }
    return $rows
}
function Write-AavDoctor($Candidate, [string]$Database) {
    $rows = Get-AavDoctor $Candidate $Database
    Write-AavLine "Health of database ${Database}:"
    $failed = $false
    foreach ($r in $rows) {
        $rem = if ($r.remediation) { "  -> $($r.remediation)" } else { '' }
        switch ($r.status) {
            'OK' { Write-AavLine "  [OK]   $($r.check_name): $($r.detail)" }
            'WARN' { Write-AavLine "  [WARN] $($r.check_name): $($r.detail)$rem" }
            default { Write-AavLine "  [$($r.status)] $($r.check_name): $($r.detail)$rem"; $failed = $true }
        }
    }
    return (-not $failed)
}
function Get-AavDatabases($Candidate) { return @((Invoke-AavPsql -Candidate $Candidate -Sql 'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname') -split "`r?`n" | Where-Object { $_ }) }
function Test-AavExtensionPresent($Candidate, [string]$Database) { return ((Invoke-AavPsql -Candidate $Candidate -Database $Database -Sql "SELECT count(*) FROM pg_extension WHERE extname = '$($script:ExtName)'") -eq '1') }
function Get-AavExtensionVersion($Candidate, [string]$Database) { return (Invoke-AavPsql -Candidate $Candidate -Database $Database -Sql "SELECT coalesce((SELECT extversion FROM pg_extension WHERE extname = '$($script:ExtName)'), '')") }

# ---------------------------------------------------------------- commands
function Invoke-AavDiscovery($P) {
    if ($P.Credential -or $P.PgPassFile) { Set-AavDefaultAuthentication $P.Credential $P.PgPassFile }
    $cands = Get-AavCandidates -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -DbUser $(if ($P.DbUser) { $P.DbUser } else { 'postgres' }) -Credential $P.Credential -PgPassFile $P.PgPassFile
    return $cands
}
function Invoke-AavCheck {
    [CmdletBinding()] param([hashtable]$P)
    $cands = Invoke-AavDiscovery $P
    if ($P.Json) {
        $sel = $null; try { $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes } catch { }
        $obj = [ordered]@{ helper_version = $script:SetupVersion; architecture = $env:PROCESSOR_ARCHITECTURE; os = (Get-CimInstance Win32_OperatingSystem).Caption
                           supported_majors = $script:SupportedMajors; clusters = $cands; selected = $sel }
        Write-Output ($obj | ConvertTo-Json -Depth 6)
        if (-not $sel) { return $script:ExitCodes.NoPg }
        return 0
    }
    Write-AavLine "adaptive-autovacuum-setup $($script:SetupVersion) check ($env:PROCESSOR_ARCHITECTURE)"
    Write-AavLine 'Discovered clusters:'; Format-AavCandidates $cands
    $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes:$P.Yes
    Write-AavLine ''; Write-AavSelected $sel
    if (Test-AavFilesInstalled $sel) { Write-AavOk "extension files present (control default_version $(Get-AavInstalledDefaultVersion $sel))" } else { Write-AavWarn "extension files not installed under $($sel.pkglibdir) / $($sel.sharedir)\extension" }
    if (Test-AavPreloadLists $sel.shared_preload_libraries) { Write-AavOk "shared_preload_libraries already lists $($script:ExtName)" } else { Write-AavLine "Preload change:   append $($script:ExtName)" }
    return 0
}

function Invoke-AavInstall {
    [CmdletBinding()] param([hashtable]$P)
    Assert-AavAdministrator
    Initialize-AavJournal 'install'
    try {
        $cands = Invoke-AavDiscovery $P
        $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes:$P.Yes
        Set-AavJournal 'selected' $sel
        Write-AavLine "adaptive_autovacuum installer (setup helper $($script:SetupVersion))"; Write-AavLine ''
        Write-AavSelected $sel; Write-AavLine ''

        # ---- preflight ----
        if ($sel.running_state -ne 'running') { Stop-Aav $script:ExitCodes.NoPg 'the selected cluster is not running; start it and rerun' }
        if (-not $sel.connection_verified) { Stop-Aav $script:ExitCodes.Privilege 'could not connect to the selected cluster; pass -Credential (Get-Credential postgres) or -PgPassFile, or fix pg_hba.conf' }
        if (-not $sel.db_superuser) { Stop-Aav $script:ExitCodes.Privilege "connected as $($sel.conn_user), which is not a superuser; ALTER SYSTEM and CREATE EXTENSION need one" }
        if ($sel.allow_alter_system -eq 'off') { Stop-Aav $script:ExitCodes.Unsupported 'allow_alter_system = off: the configuration is externally managed; add adaptive_autovacuum to shared_preload_libraries in that system' }
        if (-not $P.SourceDir -and -not (Test-AavFilesInstalled $sel)) { Stop-Aav $script:ExitCodes.ConfigFailed "extension files are not installed under $($sel.pkglibdir); run install.ps1 (or pass -SourceDir with an expanded release ZIP)" }
        $pkgManifest = $null
        if ($P.SourceDir) {
            $mp = Join-Path $P.SourceDir 'artifact-manifest.json'
            if (-not (Test-Path $mp)) { Stop-Aav $script:ExitCodes.Download "artifact-manifest.json missing in $($P.SourceDir)" }
            $pkgManifest = Get-Content -Raw $mp | ConvertFrom-Json
        }
        $extVersion = if ($pkgManifest) { $pkgManifest.extension_version } else { Get-AavInstalledDefaultVersion $sel }
        $preloadNow = [string]$sel.shared_preload_libraries
        $preloadChange = -not (Test-AavPreloadLists $preloadNow)
        $preloadPending = $false
        $preloadFile = Invoke-AavPsql -Candidate $sel -Sql "SELECT coalesce((SELECT setting FROM pg_file_settings WHERE name = 'shared_preload_libraries' ORDER BY seqno DESC LIMIT 1), '')"
        if ($preloadChange -and (Test-AavPreloadLists $preloadFile)) { $preloadChange = $false; $preloadPending = $true }

        $dbs = @()
        if (-not $P.SkipCreateExtension -and -not $sel.in_recovery) {
            $all = Get-AavDatabases $sel
            if ($P.AllDatabases) { $dbs = $all }
            elseif ($P.Database -and $P.Database.Count -gt 0) {
                foreach ($d in $P.Database) {
                    if ($d -notin $all) { Stop-Aav $script:ExitCodes.Args "database '$d' does not exist or does not allow connections" }
                    if ($d -in @('template0', 'template1')) { Stop-Aav $script:ExitCodes.Args "refusing to create the extension in $d" }
                    $dbs += $d
                }
            } elseif ((Test-AavInteractive) -and -not $P.Yes) {
                Write-AavLine 'Databases that can be managed (the extension is created per database):'
                for ($i = 0; $i -lt $all.Count; $i++) { Write-AavLine ("  {0}) {1}" -f ($i + 1), $all[$i]) }
                $pick = Read-Host 'Database numbers (space separated, empty = postgres)'
                if ([string]::IsNullOrWhiteSpace($pick)) { $dbs = @('postgres') } else { foreach ($n in ($pick -split '\s+')) { if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $all.Count) { $dbs += $all[[int]$n - 1] } else { Stop-Aav $script:ExitCodes.Args "bad selection: $n" } } }
            } else { Stop-Aav $script:ExitCodes.Args 'no activation target: pass -Database NAME (repeatable), -AllDatabases, or -SkipCreateExtension' }
        }
        $planAct = @()
        foreach ($d in $dbs) {
            $cur = Get-AavExtensionVersion $sel $d
            if (-not $cur) { $planAct += "${d}: CREATE EXTENSION $($script:ExtName) (version $extVersion)" }
            elseif ($cur -eq $extVersion) { $planAct += "${d}: already at $extVersion" }
            elseif ((Compare-AavVersion $cur $extVersion) -lt 0) { $planAct += "${d}: ALTER EXTENSION $($script:ExtName) UPDATE ($cur -> $extVersion)" }
            else { Stop-Aav $script:ExitCodes.ConfigFailed "database $d has $($script:ExtName) $cur, newer than the package ($extVersion); refusing to downgrade" }
        }
        $filesChange = $false
        if ($pkgManifest) {
            $dll = Join-Path $sel.pkglibdir "$($script:ExtName).dll"
            $newDll = $pkgManifest.files | Where-Object { $_.path -match '\.dll$' } | Select-Object -First 1
            $filesChange = (-not (Test-Path $dll)) -or ((Get-AavFileSha256 $dll) -ne $newDll.sha256.ToLowerInvariant()) -or ((Get-AavInstalledDefaultVersion $sel) -ne $extVersion)
        }
        $restartNeeded = $preloadChange -or $preloadPending
        if (-not $restartNeeded -and -not $preloadChange) {
            # Library file newer than the running postmaster (or about to be replaced) needs a restart to load.
            $dll = Join-Path $sel.pkglibdir "$($script:ExtName).dll"
            if ($filesChange) { $restartNeeded = $true }
            elseif ((Test-Path $dll) -and $sel.postmaster_start_epoch -and ([DateTimeOffset](Get-Item $dll).LastWriteTimeUtc).ToUnixTimeSeconds() -gt $sel.postmaster_start_epoch) { $restartNeeded = $true }
        }

        Write-AavLine 'Plan:'
        Write-AavLine ("  Extension files:  {0}" -f $(if ($pkgManifest) { "install $extVersion from package" + $(if ($filesChange) { '' } else { ' (already identical)' }) } else { "already installed ($extVersion)" }))
        Write-AavLine ("  Preload change:   {0}" -f $(if ($preloadChange) { "'$preloadNow' -> '$(Get-AavPreloadAppend $preloadNow)'" } elseif ($preloadPending) { "none (already '$preloadFile' in the configuration file; restart pending)" } else { "none ($($script:ExtName) already listed)" }))
        Write-AavLine ("  Restart:          {0}" -f $(if ($restartNeeded) { if ($P.NoRestart) { 'required, deferred (-NoRestart)' } else { "yes ($($sel.service_name))" } } else { 'not needed' }))
        if ($planAct.Count) { foreach ($a in $planAct) { Write-AavLine "  Database:         $a" } } else { Write-AavLine '  Database:         none (skipped)' }
        Write-AavLine ("  Enable controller: {0}" -f $(if ($P.NoEnable) { 'no' } else { 'yes (adaptive_autovacuum.enabled = on' + $(if ($sel.sql_major -ge 18) { ', track_cost_delay_timing = on' } else { '' }) + ')' }))
        if ($sel.in_recovery) { Write-AavWarn '  standby server: preload only; extension objects are created on the primary' }
        Write-AavLine ''
        if ($P.DryRun) { if ($pkgManifest) { Install-AavFiles -Candidate $sel -SourceDir $P.SourceDir -DryRun | Out-Null }; Write-AavLine 'Dry run: nothing changed.'; Complete-AavJournal 'dry_run'; return 0 }
        if (-not (Confirm-Aav 'Continue?' $P.Yes)) { Complete-AavJournal 'cancelled'; Stop-Aav $script:ExitCodes.Args 'cancelled' }

        # ---- 1. files ----
        if ($pkgManifest -and $filesChange) { $script:Journal.mutated = $true; Install-AavFiles -Candidate $sel -SourceDir $P.SourceDir | Out-Null }
        elseif ($pkgManifest) { Write-AavOk "extension files already identical to the package ($extVersion)" }

        # ---- 2. preload ----
        $autoConf = Join-Path $sel.data_directory 'postgresql.auto.conf'; $backup = $null; $postHash = $null
        if ($preloadChange) {
            $bdir = Join-Path $script:StateDir 'backups'; if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
            if (Test-Path $autoConf) { $backup = Join-Path $bdir "postgresql.auto.conf.$($script:RunId)"; Copy-Item $autoConf $backup; Set-AavJournal 'auto_conf_hash_before' (Get-AavFileSha256 $autoConf) }
            Set-AavJournal 'preload_before' $preloadNow; Set-AavJournal 'auto_conf_backup' $backup
            $newVal = Get-AavPreloadAppend $preloadNow
            $script:Journal.mutated = $true
            try { Set-AavPreloadValue $sel $newVal } catch { Add-AavJournalStep 'preload' 'failed' $_.Exception.Message; Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.ConfigFailed "ALTER SYSTEM SET shared_preload_libraries failed: $($_.Exception.Message)" }
            $ferr = Invoke-AavPsql -Candidate $sel -Sql "SELECT coalesce(string_agg(error, '; '), '') FROM pg_file_settings WHERE name = 'shared_preload_libraries' AND error IS NOT NULL AND error <> 'setting could not be applied'"
            if ($ferr) { Set-AavPreloadValue $sel $preloadNow; Add-AavJournalStep 'preload' 'failed' $ferr; Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.ConfigFailed "configuration error after ALTER SYSTEM: $ferr (previous value restored)" }
            $postHash = Get-AavFileSha256 $autoConf
            Set-AavJournal 'preload_after' $newVal; Set-AavJournal 'auto_conf_hash_after' $postHash
            Add-AavJournalStep 'preload' 'done' $newVal
            Write-AavOk 'existing preload libraries preserved'; Write-AavOk "$($script:ExtName) added to shared_preload_libraries"
        } elseif ($preloadPending) { Write-AavOk "shared_preload_libraries already configured ('$preloadFile'); applying it with the restart" }
        else { Write-AavOk "shared_preload_libraries already lists $($script:ExtName)" }

        # ---- 3. restart ----
        if ($restartNeeded) {
            if ($P.NoRestart) { Complete-AavJournal 'restart_required'; Write-AavWarn "restart deferred: run 'Restart-Service $($sel.service_name)' then rerun this installer to finish"; return 0 }
            Write-AavLine "The service $($sel.service_name) will be restarted; open connections are interrupted."
            if (-not (Confirm-Aav 'Restart now?' $P.Yes)) { Complete-AavJournal 'restart_required'; Write-AavWarn 'restart declined; state RESTART_REQUIRED'; return 0 }
            $startBefore = $sel.postmaster_start_epoch
            if (Restart-AavService $sel $P.RestartTimeout) {
                $startAfter = [long](Invoke-AavPsql -Candidate $sel -Sql 'SELECT extract(epoch FROM pg_postmaster_start_time())::bigint')
                if ($startAfter -le $startBefore) { Write-AavWarn 'pg_postmaster_start_time did not advance; verify the restart' }
                $effective = Invoke-AavPsql -Candidate $sel -Sql 'SHOW shared_preload_libraries'
                if (-not (Test-AavPreloadLists $effective)) { Add-AavJournalStep 'restart' 'failed' 'preload not effective'; Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.Restart "server restarted but shared_preload_libraries is '$effective'" }
                Add-AavJournalStep 'restart' 'done'; Write-AavOk 'PostgreSQL restarted and accepting connections'
                Remove-AavRenamedAside
            } else {
                Write-AavFail "PostgreSQL did not become ready within $($P.RestartTimeout) s"
                Write-AavLogExcerpt $sel
                if ($preloadChange -and $backup) {
                    Write-AavLine "Rolling back shared_preload_libraries to '$preloadNow' ..."
                    if ((Get-AavFileSha256 $autoConf) -eq $postHash) {
                        Copy-Item $backup "$autoConf.aav-restore"; Move-Item -Force "$autoConf.aav-restore" $autoConf
                        Start-Service -Name $sel.service_name -ErrorAction SilentlyContinue
                        if (Wait-AavReady $sel $P.RestartTimeout) { Add-AavJournalStep 'rollback' 'done'; Complete-AavJournal 'rolled_back'; Stop-Aav $script:ExitCodes.ConfigFailed "restart with $($script:ExtName) failed; previous configuration restored and the server is running again. Check the log excerpt above (library load error?)" }
                        Add-AavJournalStep 'rollback' 'failed'; Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.Restart "restart failed and automatic rollback did not restore service. Restore $backup to $autoConf and start $($sel.service_name) manually"
                    }
                    Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.Restart "postgresql.auto.conf changed since this installer wrote it; not overwriting. Restore manually: copy $backup to $autoConf, then start $($sel.service_name)"
                }
                Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.Restart "restart failed; no preload change was made by this run. Start $($sel.service_name) manually and check its log"
            }
        }

        # ---- 4. activation ----
        $actFailed = $false
        foreach ($d in $dbs) {
            $cur = Get-AavExtensionVersion $sel $d
            try {
                if (-not $cur) { Invoke-AavPsql -Candidate $sel -Database $d -Sql "CREATE EXTENSION $($script:ExtName);" | Out-Null; Write-AavOk "extension created in $d ($extVersion)"; Add-AavJournalStep "create:$d" 'done' }
                elseif ($cur -ne $extVersion) { Invoke-AavPsql -Candidate $sel -Database $d -Sql "ALTER EXTENSION $($script:ExtName) UPDATE;" | Out-Null; Write-AavOk "extension updated in $d ($cur -> $extVersion); policy and history preserved"; Add-AavJournalStep "update:$d" 'done' }
                else { Write-AavOk "extension already at $extVersion in $d" }
            } catch { Write-AavFail "activation failed in ${d}: $($_.Exception.Message)"; Add-AavJournalStep "activate:$d" 'failed' $_.Exception.Message; $actFailed = $true }
        }

        # ---- 5. enable controller ----
        if (-not $P.NoEnable -and -not $sel.in_recovery) {
            Set-AavJournal 'enabled_before' (Invoke-AavPsql -Candidate $sel -Sql "SELECT coalesce(current_setting('adaptive_autovacuum.enabled', true), '')")
            $script:Journal.mutated = $true
            Invoke-AavPsql -Candidate $sel -Sql 'ALTER SYSTEM SET adaptive_autovacuum.enabled = on;' | Out-Null
            if ($sel.sql_major -ge 18) { Set-AavJournal 'track_cost_delay_timing_before' (Invoke-AavPsql -Candidate $sel -Sql 'SHOW track_cost_delay_timing'); Invoke-AavPsql -Candidate $sel -Sql 'ALTER SYSTEM SET track_cost_delay_timing = on;' | Out-Null }
            Invoke-AavPsql -Candidate $sel -Sql 'SELECT pg_reload_conf()' | Out-Null
            Add-AavJournalStep 'enable' 'done'; Write-AavOk 'controller enabled (adaptive_autovacuum.enabled = on)'
        }

        # ---- 6. verify ----
        $failures = $actFailed
        $dll = Join-Path $sel.pkglibdir "$($script:ExtName).dll"; $ctl = Join-Path $sel.sharedir "extension\$($script:ExtName).control"; $sqlf = Join-Path $sel.sharedir "extension\$($script:ExtName)--$extVersion.sql"
        if ((Test-Path $dll) -and (Test-Path $ctl) -and (Test-Path $sqlf)) { Write-AavOk "extension files installed ($dll, $ctl, $(Split-Path $sqlf -Leaf))" } else { Write-AavFail 'extension files incomplete'; $failures = $true }
        if ($dbs.Count) {
            $deadline = (Get-Date).AddSeconds($P.StartupWait)
            while ((Get-Date) -lt $deadline) { try { if ((Invoke-AavPsql -Candidate $sel -Database $dbs[0] -Sql "SELECT launcher_running FROM $($script:ExtName).status()") -eq 't') { break } } catch { }; Start-Sleep -Seconds 2 }
            foreach ($d in $dbs) { if (Test-AavExtensionPresent $sel $d) { if (-not (Write-AavDoctor $sel $d)) { $failures = $true } } }
        }
        if (-not $failures) {
            Complete-AavJournal 'completed'
            Write-AavLine ''; Write-AavLine 'Installation complete.'; Write-AavLine ''
            Write-AavLine "Diagnose:      adaptive-autovacuum-setup.ps1 doctor"
            Write-AavLine "SQL status:    SELECT * FROM adaptive_autovacuum.doctor();"
            Write-AavLine "Disable:       adaptive-autovacuum-setup.ps1 disable    (controller off, nothing removed)"
            Write-AavLine "Remove preload: adaptive-autovacuum-setup.ps1 remove-preload"
            return 0
        }
        Complete-AavJournal 'health_failed'; Stop-Aav $script:ExitCodes.Health 'installation finished with failed checks (see above)'
    } finally { Close-AavJournalOnExit }
}

function Invoke-AavDoctor {
    [CmdletBinding()] param([hashtable]$P)
    $cands = Invoke-AavDiscovery $P
    $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes
    $rc = 0
    $dll = Join-Path $sel.pkglibdir "$($script:ExtName).dll"; $ctl = Join-Path $sel.sharedir "extension\$($script:ExtName).control"
    $ver = Get-AavInstalledDefaultVersion $sel
    $dbs = @(); if ($sel.connection_verified) { $dbs = Get-AavDatabases $sel }
    if ($P.Json) {
        $dbjson = @()
        foreach ($d in $dbs) {
            if (-not (Test-AavExtensionPresent $sel $d)) { continue }
            $checks = Get-AavDoctor $sel $d
            $st = $null; try { $st = Invoke-AavPsql -Candidate $sel -Database $d -Sql "SELECT row_to_json(s) FROM $($script:ExtName).status() s" | ConvertFrom-Json } catch { }
            $dbjson += [ordered]@{ database = $d; status = $st; checks = $checks }
            if ($checks | Where-Object { $_.status -in @('FAIL', 'RESTART_REQUIRED') }) { $rc = $script:ExitCodes.Health }
        }
        $last = $null; if (Test-Path $script:StateFile) { $j = Get-Content -Raw $script:StateFile | ConvertFrom-Json; $last = [ordered]@{ run_id = (Get-AavProp $j 'run_id'); final_state = (Get-AavProp $j 'final_state'); finished_at = (Get-AavProp $j 'finished_at'); installer_version = (Get-AavProp $j 'installer_version') } }
        Write-Output ([ordered]@{ helper_version = $script:SetupVersion; cluster = $sel; files = [ordered]@{ library_present = (Test-Path $dll); control_present = (Test-Path $ctl); default_version = $ver }; databases = $dbjson; last_run = $last } | ConvertTo-Json -Depth 8)
        return $rc
    }
    Write-AavLine "adaptive-autovacuum-setup $($script:SetupVersion) doctor"; Write-AavSelected $sel
    if ((Test-Path $dll) -and (Test-Path $ctl)) { Write-AavOk "extension files installed ($dll, $ctl, default_version $ver)" } else { Write-AavFail "extension files incomplete under $($sel.pkglibdir) / $($sel.sharedir)\extension"; $rc = $script:ExitCodes.Health }
    if (-not $sel.connection_verified) { Stop-Aav $script:ExitCodes.Privilege 'no database connection; pass -Credential or -PgPassFile' }
    $any = $false
    foreach ($d in $dbs) { if (Test-AavExtensionPresent $sel $d) { $any = $true; if (-not (Write-AavDoctor $sel $d)) { $rc = $script:ExitCodes.Health } } }
    if (-not $any) { Write-AavWarn 'the extension is not created in any database; run: adaptive-autovacuum-setup.ps1 install -Database NAME'; $rc = $script:ExitCodes.Health }
    if (Test-Path $script:StateFile) { $j = Get-Content -Raw $script:StateFile | ConvertFrom-Json; Write-AavLine "Last installer run: $(Get-AavProp $j 'run_id') $(Get-AavProp $j 'final_state')" }
    return $rc
}

function Set-AavControllerEnabled {
    [CmdletBinding()] param([hashtable]$P, [Parameter(Mandatory)][bool]$Enabled)
    Assert-AavAdministrator
    $cands = Invoke-AavDiscovery $P
    $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes:$P.Yes
    if (-not $sel.connection_verified) { Stop-Aav $script:ExitCodes.Privilege 'no database connection; pass -Credential or -PgPassFile' }
    if (-not $sel.db_superuser) { Stop-Aav $script:ExitCodes.Privilege 'superuser connection required' }
    $target = if ($Enabled) { 'on' } else { 'off' }
    $before = Invoke-AavPsql -Candidate $sel -Sql "SELECT coalesce(current_setting('adaptive_autovacuum.enabled', true), '<library not loaded>')"
    Write-AavLine "adaptive_autovacuum.enabled: $before -> $target on $($sel.service_name) ($($sel.data_directory))"
    if (-not (Test-AavPreloadLists $sel.shared_preload_libraries)) { Write-AavWarn 'the library is not preloaded in the running server; the setting takes effect once shared_preload_libraries lists adaptive_autovacuum and the server has restarted' }
    if ($P.DryRun) { return 0 }
    Initialize-AavJournal $(if ($Enabled) { 'enable' } else { 'disable' })
    try {
        Set-AavJournal 'selected' $sel; Set-AavJournal 'enabled_before' $before; $script:Journal.mutated = $true
        Invoke-AavPsql -Candidate $sel -Sql "ALTER SYSTEM SET adaptive_autovacuum.enabled = $target;" | Out-Null
        Invoke-AavPsql -Candidate $sel -Sql 'SELECT pg_reload_conf()' | Out-Null
        Add-AavJournalStep "enabled=$target" 'done'; Complete-AavJournal $(if ($Enabled) { 'completed' } else { 'disabled' })
        Write-AavOk $(if ($Enabled) { 'controller enabled' } else { 'controller disabled (files, preload and extension objects untouched)' })
        return 0
    } finally { Close-AavJournalOnExit }
}

function Remove-AavPreload {
    [CmdletBinding()] param([hashtable]$P)
    Assert-AavAdministrator
    $cands = Invoke-AavDiscovery $P
    $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes:$P.Yes
    if (-not $sel.connection_verified) { Stop-Aav $script:ExitCodes.Privilege 'no database connection; pass -Credential or -PgPassFile' }
    if (-not $sel.db_superuser) { Stop-Aav $script:ExitCodes.Privilege 'superuser connection required' }
    $now = [string]$sel.shared_preload_libraries
    if (-not (Test-AavPreloadLists $now)) { Write-AavOk "shared_preload_libraries does not list $($script:ExtName) ('$now'); nothing to do"; return 0 }
    $newVal = Get-AavPreloadRemove $now
    Write-AavLine "Preload change: '$now' -> '$newVal' (order of the other libraries preserved)"
    Write-AavLine "A restart of $($sel.service_name) is needed for the change to take effect."
    if ($P.DryRun) { return 0 }
    if (-not (Confirm-Aav 'Continue?' $P.Yes)) { Stop-Aav $script:ExitCodes.Args 'cancelled' }
    Initialize-AavJournal 'remove-preload'
    try {
        Set-AavJournal 'selected' $sel; Set-AavJournal 'preload_before' $now; $script:Journal.mutated = $true
        Set-AavPreloadValue $sel $newVal
        Add-AavJournalStep 'remove-preload' 'done' $newVal; Write-AavOk "shared_preload_libraries set to '$newVal'"
        Write-AavWarn "extension objects stay in every database; DROP EXTENSION $($script:ExtName) is a separate, destructive step (it deletes the policy and history tables)"
        if ($P.NoRestart -or -not (Confirm-Aav "Restart $($sel.service_name) now?" $P.Yes)) { Complete-AavJournal 'restart_required'; Write-AavWarn 'restart pending'; return 0 }
        if (-not (Restart-AavService $sel $P.RestartTimeout)) { Complete-AavJournal 'failed'; Stop-Aav $script:ExitCodes.Restart 'restart failed; check the service log' }
        Complete-AavJournal 'preload_removed'; Write-AavOk "PostgreSQL restarted without $($script:ExtName)"
        return 0
    } finally { Close-AavJournalOnExit }
}

function Remove-AavFiles {
    # Removes the extension files only when no running postmaster has the library loaded.
    [CmdletBinding()] param([hashtable]$P)
    Assert-AavAdministrator
    $cands = Invoke-AavDiscovery $P
    $sel = Select-AavCandidate -Candidates $cands -PgRoot $P.PgRoot -ServiceName $P.ServiceName -DataDirectory $P.DataDirectory -Port $P.Port -PgMajor $P.PgMajor -Yes:$P.Yes
    if ($sel.running_state -eq 'running' -and (Test-AavPreloadLists $sel.shared_preload_libraries)) { Stop-Aav $script:ExitCodes.ConfigFailed 'the running server still preloads the library; run remove-preload (with restart) first' }
    $files = @((Join-Path $sel.pkglibdir "$($script:ExtName).dll"), (Join-Path $sel.sharedir "extension\$($script:ExtName).control")) + @(Get-ChildItem (Join-Path $sel.sharedir 'extension') -Filter "$($script:ExtName)--*.sql" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Write-AavLine 'Files to remove:'; foreach ($f in $files) { if (Test-Path -LiteralPath $f) { Write-AavLine "  $f" } }
    Write-AavLine "Program directory: $script:ProgramDir"
    Write-AavWarn 'Extension objects (policy, history) stay in every database. To remove them run, per database: DROP EXTENSION adaptive_autovacuum;'
    if ($P.DryRun) { return 0 }
    if (-not (Confirm-Aav 'Remove the files?' $P.Yes)) { Stop-Aav $script:ExitCodes.Args 'cancelled' }
    foreach ($f in $files) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    if (Test-Path $script:ProgramDir) { Remove-Item -Recurse -Force $script:ProgramDir }
    Write-AavOk 'extension files removed; database objects untouched'
    return 0
}

Export-ModuleMember -Function Get-AavCandidates, Select-AavCandidate, Invoke-AavPsql, Invoke-AavCheck, Invoke-AavInstall, Invoke-AavDoctor,
    Set-AavControllerEnabled, Remove-AavPreload, Remove-AavFiles, Install-AavFiles, Test-AavPreloadLists, Get-AavPreloadAppend, Get-AavPreloadRemove,
    Split-AavServicePath, ConvertTo-AavArgumentString, Compare-AavVersion, Set-AavDefaultAuthentication, Get-AavFileSha256, Write-AavLine, Format-AavCandidates,
    Get-AavExitCode -Variable ExitCodes, SetupVersion
