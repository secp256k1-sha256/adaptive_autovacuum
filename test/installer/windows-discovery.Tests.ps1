# Pester 5+ unit tests for AdaptiveAutovacuum.Setup.psm1: pure functions and selection rules.
# No PostgreSQL needed. Run: Invoke-Pester test/installer/windows-discovery.Tests.ps1
BeforeAll {
    $env:AAV_STATE_DIR = Join-Path $TestDrive 'state'
    Import-Module (Join-Path $PSScriptRoot '..\..\packaging\windows\AdaptiveAutovacuum.Setup.psm1') -Force
}

Describe 'Split-AavServicePath' {
    It 'parses a quoted EDB service path with spaces' {
        $r = Split-AavServicePath '"C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe" runservice -N "postgresql-x64-18" -D "C:\Program Files\PostgreSQL\18\data" -w'
        $r.Exe | Should -Be 'C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe'
        $r.DataDirectory | Should -Be 'C:\Program Files\PostgreSQL\18\data'
    }
    It 'parses an unquoted path without spaces' {
        $r = Split-AavServicePath 'C:\pg\bin\pg_ctl.exe runservice -N pg18 -D C:\pgdata -w'
        $r.Exe | Should -Be 'C:\pg\bin\pg_ctl.exe'
        $r.DataDirectory | Should -Be 'C:\pgdata'
    }
    It 'returns no data directory when -D is absent' {
        (Split-AavServicePath '"C:\pg\bin\postgres.exe"').DataDirectory | Should -BeNullOrEmpty
    }
}

Describe 'preload list helpers' {
    It 'recognises plain, quoted, $libdir and suffixed entries' {
        Test-AavPreloadLists 'adaptive_autovacuum' | Should -BeTrue
        Test-AavPreloadLists 'pg_stat_statements, adaptive_autovacuum' | Should -BeTrue
        Test-AavPreloadLists '"$libdir/adaptive_autovacuum"' | Should -BeTrue
        Test-AavPreloadLists 'adaptive_autovacuum.dll' | Should -BeTrue
    }
    It 'rejects absent, empty and near-miss names' {
        Test-AavPreloadLists '' | Should -BeFalse
        Test-AavPreloadLists 'pg_stat_statements,auto_explain' | Should -BeFalse
        Test-AavPreloadLists 'adaptive_autovacuum_extra' | Should -BeFalse
    }
    It 'appends without touching existing entries' {
        Get-AavPreloadAppend '' | Should -Be 'adaptive_autovacuum'
        Get-AavPreloadAppend 'pg_stat_statements,auto_explain' | Should -Be 'pg_stat_statements,auto_explain,adaptive_autovacuum'
    }
    It 'removes only our library and preserves order' {
        Get-AavPreloadRemove 'pg_stat_statements, adaptive_autovacuum, auto_explain' | Should -Be 'pg_stat_statements,auto_explain'
        Get-AavPreloadRemove 'adaptive_autovacuum' | Should -Be ''
        Get-AavPreloadRemove 'pg_stat_statements' | Should -Be 'pg_stat_statements'
    }
}

Describe 'ConvertTo-AavArgumentString' {
    It 'quotes arguments with spaces and escapes embedded quotes' {
        ConvertTo-AavArgumentString @('-d', 'my db', 'plain') | Should -Be '-d "my db" plain'
        ConvertTo-AavArgumentString @('say "hi"') | Should -Be '"say \"hi\""'
        ConvertTo-AavArgumentString @('C:\path\') | Should -Be 'C:\path\'
        ConvertTo-AavArgumentString @('C:\dir with space\') | Should -Be '"C:\dir with space\\"'
        ConvertTo-AavArgumentString @('') | Should -Be '""'
    }
}

Describe 'Compare-AavVersion' {
    It 'orders dotted versions and ignores tags' {
        Compare-AavVersion '1.0.0' '1.1.0' | Should -BeLessThan 0
        Compare-AavVersion '1.1.0' '1.1.0' | Should -Be 0
        Compare-AavVersion '1.2.0-beta' '1.1.9' | Should -BeGreaterThan 0
    }
}

Describe 'Select-AavCandidate' {
    BeforeAll {
        function NewCand([string]$id, [int]$major, [string]$state, [int]$port, [string]$svc) {
            [ordered]@{ candidate_id = $id; postgres_major = $major; postgres_full_version = "$major.6"; running_state = $state; port = $port; service_name = $svc
                        data_directory = "C:\pg\$id"; install_root = "C:\pg\$id"; supported = ($major -in @(17, 18)); inconsistent = $null; discovery_sources = @('test') }
        }
    }
    It 'selects the single supported candidate' {
        $c = @((NewCand 'a' 16 'running' 5432 'pg16'), (NewCand 'b' 18 'running' 5433 'pg18'))
        (Select-AavCandidate -Candidates $c -Yes).candidate_id | Should -Be 'b'
    }
    It 'prefers the only running one among several supported candidates' {
        $c = @((NewCand 'a' 18 'stopped' 5432 'pgA'), (NewCand 'b' 18 'running' 5433 'pgB'))
        (Select-AavCandidate -Candidates $c -Yes).candidate_id | Should -Be 'b'
    }
    It 'exits 4 when two supported candidates run and no filter is given' {
        $c = @((NewCand 'a' 18 'running' 5432 'pgA'), (NewCand 'b' 18 'running' 5433 'pgB'))
        try { Select-AavCandidate -Candidates $c -Yes; throw 'no error' } catch { Get-AavExitCode $_ | Should -Be 4 }
    }
    It 'resolves the ambiguity with -ServiceName, -Port or -DataDirectory' {
        $c = @((NewCand 'a' 18 'running' 5432 'pgA'), (NewCand 'b' 18 'running' 5433 'pgB'))
        (Select-AavCandidate -Candidates $c -ServiceName pgB -Yes).candidate_id | Should -Be 'b'
        (Select-AavCandidate -Candidates $c -Port 5432 -Yes).candidate_id | Should -Be 'a'
        (Select-AavCandidate -Candidates $c -DataDirectory 'C:\pg\b' -Yes).candidate_id | Should -Be 'b'
    }
    It 'exits 3 when no supported candidate exists' {
        $c = @((NewCand 'a' 16 'running' 5432 'pg16'))
        try { Select-AavCandidate -Candidates $c -Yes; throw 'no error' } catch { Get-AavExitCode $_ | Should -Be 3 }
    }
    It 'ignores inconsistent candidates' {
        $bad = NewCand 'a' 18 'running' 5432 'pgA'; $bad.inconsistent = 'server major 17 but binaries major 18'
        try { Select-AavCandidate -Candidates @($bad) -Yes; throw 'no error' } catch { Get-AavExitCode $_ | Should -Be 3 }
    }
}

Describe 'Get-AavCandidates (host integration, read-only)' {
    It 'returns records with the shared data model keys' {
        $c = @(Get-AavCandidates)
        foreach ($x in $c) {
            foreach ($k in 'candidate_id', 'postgres_major', 'install_root', 'data_directory', 'service_name', 'running_state', 'connection_verified', 'discovery_sources', 'supported') { $x.Contains($k) | Should -BeTrue }
        }
        @($c | Where-Object { $_.data_directory }) | Group-Object { $_.data_directory.ToLowerInvariant() } | Where-Object Count -gt 1 | Should -BeNullOrEmpty
    }
}
