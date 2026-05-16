<#
.SYNOPSIS
    Full integration test: run Sync-HttpsTime.ps1 -DryRun against real HTTPS
    sources, assert at least 2 succeed and the median-drift line appears.

    Skipped gracefully (warn, not fail) if network is unreachable.
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'EndToEnd'

$repoRoot = Get-RepoRoot
$syncScript = Join-Path $repoRoot 'Sync-HttpsTime.ps1'
$cfgPath = Join-Path $repoRoot 'config.default.json'

# Quick connectivity check
$networkOk = $false
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $null = Invoke-WebRequest -Uri 'https://www.cloudflare.com' -Method Head `
        -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    $networkOk = $true
} catch {
    Write-Host "    (skipping: cloudflare HEAD failed - no network?)" -ForegroundColor Yellow
}

Assert-Test 'config.default.json exists and parses' {
    Assert-True (Test-Path $cfgPath) "config.default.json missing"
    $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
    Assert-True ($cfg.sources.Count -ge 2) 'should have at least 2 sources'
    Assert-True ($cfg.thresholdMs -gt 0) 'thresholdMs must be positive'
}

if (-not $networkOk) {
    Write-Host "  network unreachable; skipping live-sync test" -ForegroundColor Yellow
    exit (Write-TestSummary)
}

Assert-Test 'PS 5.1 dry-run exits 0 and reports >=2 OK sources' {
    $tmpOut = Join-Path $env:TEMP "e2e-51-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        $wrapper = "`$ProgressPreference='SilentlyContinue'; & '$syncScript' -DryRun -ConfigPath '$cfgPath' *>&1 | Out-File '$tmpOut' -Encoding UTF8 ; exit `$LASTEXITCODE"
        $proc = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$wrapper) `
            -Wait -PassThru -NoNewWindow
        Assert-Equal 0 $proc.ExitCode "exit code"

        $out = Get-Content -Raw $tmpOut
        Assert-Match $out 'Starting sync' 'should print start banner'
        Assert-Match $out 'Median drift across \d+ sources' 'should report median'

        # Count INFO source lines (rtt= prefix)
        $okCount = ([regex]::Matches($out, '\[INFO\][^\n]*rtt=')).Count
        Assert-True ($okCount -ge 2) "expected >=2 OK sources, got $okCount. Output:`n$out"
    } finally { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
}

Assert-Test 'PS 7 dry-run exits 0 and reports >=2 OK sources' {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Host "    (skipping: pwsh.exe not found)" -ForegroundColor Yellow
        return $true
    }
    $tmpOut = Join-Path $env:TEMP "e2e-7-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        $wrapper = "`$ProgressPreference='SilentlyContinue'; & '$syncScript' -DryRun -ConfigPath '$cfgPath' *>&1 | Out-File '$tmpOut' -Encoding UTF8 ; exit `$LASTEXITCODE"
        $proc = Start-Process -FilePath $pwsh.Path `
            -ArgumentList @('-NoProfile','-Command',$wrapper) `
            -Wait -PassThru -NoNewWindow
        Assert-Equal 0 $proc.ExitCode "exit code"

        $out = Get-Content -Raw $tmpOut
        Assert-Match $out 'Median drift across \d+ sources' 'should report median'
        $okCount = ([regex]::Matches($out, '\[INFO\][^\n]*rtt=')).Count
        Assert-True ($okCount -ge 2) "expected >=2 OK sources, got $okCount. Output:`n$out"
    } finally { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
}

Assert-Test 'dry-run does NOT call Set-Date' {
    # If Set-Date had been called the wall clock would jump.
    # We verify negatively by checking the output mentions "DryRun: would step" or "Within threshold".
    $tmpOut = Join-Path $env:TEMP "e2e-noSet-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        $wrapper = "`$ProgressPreference='SilentlyContinue'; & '$syncScript' -DryRun -ConfigPath '$cfgPath' *>&1 | Out-File '$tmpOut' -Encoding UTF8 ; exit `$LASTEXITCODE"
        $proc = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$wrapper) `
            -Wait -PassThru -NoNewWindow
        $out = Get-Content -Raw $tmpOut
        Assert-NotMatch $out 'Clock adjusted by' 'DryRun must not adjust the clock'
        Assert-Match $out 'DryRun: would step|Within threshold' 'DryRun must report intended action'
    } finally { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
}

exit (Write-TestSummary)
