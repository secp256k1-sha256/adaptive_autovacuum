# Pester 5+ integration tests for the Windows installer against a live PostgreSQL service.
# Skipped unless $env:AAV_TEST_LIVE = '1'. Needs: elevated PowerShell, $env:AAV_TEST_PGPASSFILE (pgpass for postgres),
# a release ZIP under dist\ (build with packaging\windows\build-zip.ps1) and a database $env:AAV_TEST_DATABASE used as the control database.
# Optional: $env:AAV_TEST_SERVICE (default postgresql-x64-18).
BeforeDiscovery { $script:live = ($env:AAV_TEST_LIVE -eq '1') }

Describe 'Windows installer (live)' -Skip:(-not $script:live) {
    BeforeAll {
        $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $script:setup = Join-Path $repo 'packaging\windows\adaptive-autovacuum-setup.ps1'
        $script:install = Join-Path $repo 'packaging\windows\install.ps1'
        $script:dist = Join-Path $repo 'dist'
        $script:db = if ($env:AAV_TEST_DATABASE) { $env:AAV_TEST_DATABASE } else { 'aav_installer_test' }
        $script:svc = if ($env:AAV_TEST_SERVICE) { $env:AAV_TEST_SERVICE } else { 'postgresql-x64-18' }
        $script:pass = $env:AAV_TEST_PGPASSFILE
        $major = [int]($script:svc -replace '^.*-(\d+)$', '$1')
        $zip = Get-ChildItem $script:dist -Filter "adaptive_autovacuum-*-pg$major-windows-x64.zip" | Select-Object -First 1
        if (-not $zip) { $zip = Get-ChildItem $script:dist -Filter 'adaptive_autovacuum-*-windows-x64.zip' | Select-Object -First 1 }
        $zip | Should -Not -BeNullOrEmpty
        $sha = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $ver = ($zip.Name -replace '^adaptive_autovacuum-([^-]+)-.*$', '$1')
        $script:manifest = Join-Path $TestDrive 'release-manifest.json'
        [ordered]@{ schema_version = 1; extension_version = $ver; package_revision = 1; minimum_installer_version = '1.2.0'; published_at = (Get-Date).ToUniversalTime().ToString('o')
                    artifacts = @([ordered]@{ artifact_filename = $zip.Name; artifact_url = "https://github.com/x/y/releases/download/v$ver/$($zip.Name)"; sha256 = $sha; postgres_major = $major; operating_system = 'windows'; architecture = 'x64'; package_type = 'zip' }) } |
            ConvertTo-Json -Depth 5 | Set-Content $script:manifest

        # The scripts call exit; run them in a child pwsh so exit codes and every output stream are isolated from Pester.
        function script:Invoke-Script([string]$Path, [string[]]$Arguments) {
            $out = & pwsh -NoProfile -NonInteractive -File $Path @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }
    It 'rejects a checksum mismatch with exit 6 and installs nothing' {
        $bad = Join-Path $TestDrive 'bad.json'
        (Get-Content -Raw $script:manifest) -replace '"sha256":\s*"[0-9a-f]+"', '"sha256": "0000000000000000000000000000000000000000000000000000000000000000"' | Set-Content $bad
        $r = Invoke-Script $script:install @('-Yes', '-Manifest', $bad, '-ArtifactDir', $script:dist, '-PgPassFile', $script:pass, '-ServiceName', $script:svc, '-ControlDatabase', $script:db)
        $r.ExitCode | Should -Be 6 -Because $r.Output
        $r.Output | Should -Match 'checksum mismatch'
    }
    It 'installs, restarts, activates and passes doctor' {
        $r = Invoke-Script $script:install @('-Yes', '-Manifest', $script:manifest, '-ArtifactDir', $script:dist, '-PgPassFile', $script:pass, '-ServiceName', $script:svc, '-ControlDatabase', $script:db)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Installation complete'
        $d = Invoke-Script $script:setup @('doctor', '-Format', 'json', '-PgPassFile', $script:pass, '-ServiceName', $script:svc)
        $d.ExitCode | Should -Be 0 -Because $d.Output
        $j = $d.Output | ConvertFrom-Json
        ($j.databases | Where-Object database -eq $script:db).status.extension_version | Should -Not -BeNullOrEmpty
        ($j.databases | Where-Object database -eq $script:db).checks | Where-Object status -eq 'FAIL' | Should -BeNullOrEmpty
        $j.control_database | Should -Be $script:db
        $j.last_run.final_state | Should -Be 'completed'
    }
    It 'is idempotent on rerun (no restart)' {
        $r = Invoke-Script $script:setup @('install', '-Yes', '-PgPassFile', $script:pass, '-ServiceName', $script:svc, '-ControlDatabase', $script:db)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Restart:\s+not needed'
    }
    It 'disable turns the launcher off without removing anything' {
        $r = Invoke-Script $script:setup @('disable', '-Yes', '-PgPassFile', $script:pass, '-ServiceName', $script:svc)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $d = Invoke-Script $script:setup @('doctor', '-Format', 'json', '-PgPassFile', $script:pass, '-ServiceName', $script:svc)
        $j = $d.Output | ConvertFrom-Json
        ($j.databases | Where-Object database -eq $script:db).status.launcher_enabled | Should -BeFalse
        $j.files.library_present | Should -BeTrue
    }
}
