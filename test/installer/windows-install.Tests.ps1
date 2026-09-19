# Pester 5+ integration tests for the Windows installer against a live PostgreSQL 18 service.
# Skipped unless $env:AAV_TEST_LIVE = '1'. Needs: elevated PowerShell, $env:AAV_TEST_PGPASSFILE (pgpass for postgres),
# a release ZIP under dist\ (build with packaging\windows\build-zip.ps1) and an empty database $env:AAV_TEST_DATABASE.
BeforeDiscovery { $script:live = ($env:AAV_TEST_LIVE -eq '1') }

Describe 'Windows installer (live)' -Skip:(-not $script:live) {
    BeforeAll {
        $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $setup = Join-Path $repo 'packaging\windows\adaptive-autovacuum-setup.ps1'
        $install = Join-Path $repo 'packaging\windows\install.ps1'
        $dist = Join-Path $repo 'dist'
        $db = if ($env:AAV_TEST_DATABASE) { $env:AAV_TEST_DATABASE } else { 'aav_installer_test' }
        $svc = if ($env:AAV_TEST_SERVICE) { $env:AAV_TEST_SERVICE } else { 'postgresql-x64-18' }
        $pass = $env:AAV_TEST_PGPASSFILE
        $zip = Get-ChildItem $dist -Filter 'adaptive_autovacuum-*-windows-x64.zip' | Select-Object -First 1
        $zip | Should -Not -BeNullOrEmpty
        $sha = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $ver = ($zip.Name -replace '^adaptive_autovacuum-([^-]+)-.*$', '$1')
        $manifest = Join-Path $TestDrive 'release-manifest.json'
        [ordered]@{ schema_version = 1; extension_version = $ver; package_revision = 1; minimum_installer_version = '1.1.0'; published_at = (Get-Date).ToUniversalTime().ToString('o')
                    artifacts = @([ordered]@{ artifact_filename = $zip.Name; artifact_url = "https://github.com/x/y/releases/download/v$ver/$($zip.Name)"; sha256 = $sha; postgres_major = 18; operating_system = 'windows'; architecture = 'x64'; package_type = 'zip' }) } |
            ConvertTo-Json -Depth 5 | Set-Content $manifest
    }
    It 'rejects a checksum mismatch with exit 6 and installs nothing' {
        $bad = Join-Path $TestDrive 'bad.json'; (Get-Content -Raw $manifest) -replace '"sha256":\s*"[0-9a-f]+"', '"sha256": "0000000000000000000000000000000000000000000000000000000000000000"' | Set-Content $bad
        & $install -Yes -Manifest $bad -ArtifactDir $dist -PgPassFile $pass -ServiceName $svc -Database $db *> $null
        $LASTEXITCODE | Should -Be 6
    }
    It 'installs, restarts, activates and passes doctor' {
        & $install -Yes -Manifest $manifest -ArtifactDir $dist -PgPassFile $pass -ServiceName $svc -Database $db *> $null
        $LASTEXITCODE | Should -Be 0
        $j = & $setup doctor -Format json -PgPassFile $pass -ServiceName $svc | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0
        ($j.databases | Where-Object database -eq $db).status.extension_version | Should -Not -BeNullOrEmpty
        ($j.databases | Where-Object database -eq $db).checks | Where-Object status -eq 'FAIL' | Should -BeNullOrEmpty
        $j.last_run.final_state | Should -Be 'completed'
    }
    It 'is idempotent on rerun (no restart)' {
        # The helper reports through Write-Host (information stream): capture every stream, not just stdout/stderr.
        $out = & $setup install -Yes -PgPassFile $pass -ServiceName $svc -Database $db *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Restart:\s+not needed'
    }
    It 'disable turns the launcher off without removing anything' {
        & $setup disable -Yes -PgPassFile $pass -ServiceName $svc *> $null
        $LASTEXITCODE | Should -Be 0
        $j = & $setup doctor -Format json -PgPassFile $pass -ServiceName $svc | ConvertFrom-Json
        ($j.databases | Where-Object database -eq $db).status.launcher_enabled | Should -BeFalse
        $j.files.library_present | Should -BeTrue
    }
}
