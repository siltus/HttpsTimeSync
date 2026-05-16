<#
.SYNOPSIS
    Top-level test runner. Discovers tests/Test-*.ps1, invokes each in a
    fresh child shell, aggregates pass/fail counts, exits non-zero if any
    test fails.

.PARAMETER Filter
    Only run tests whose name (without "Test-" prefix and ".ps1" suffix) matches.

.PARAMETER PowerShellPath
    Which powershell.exe to use. Default: Windows PowerShell 5.1.

.PARAMETER IncludeElevated
    Also run tests/Test-Elevated-*.ps1 which exercise the REAL admin
    privileged path (install + scheduled task + Set-Date). When set and
    the runner is not already admin, self-elevates with a single UAC
    prompt; the elevated child runs all suites (default + elevated).

    Default behavior (without -IncludeElevated): elevated tests are
    excluded, no UAC prompt is shown.

.EXAMPLE
    .\Run-Tests.ps1

.EXAMPLE
    .\Run-Tests.ps1 -Filter Rotation

.EXAMPLE
    .\Run-Tests.ps1 -IncludeElevated
#>
[CmdletBinding()]
param(
    [string]$Filter = '*',
    [string]$PowerShellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    [switch]$IncludeElevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Self-elevate ONLY when -IncludeElevated is requested and we're not already admin.
# Default runs never trigger UAC.
if ($IncludeElevated -and -not (Test-IsAdmin)) {
    Write-Host "Re-launching test runner with elevated privileges (single UAC prompt incoming)..." -ForegroundColor Yellow
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
              '-Filter',$Filter,'-PowerShellPath',$PowerShellPath,'-IncludeElevated')
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args `
                           -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-Error "Elevation cancelled or failed: $($_.Exception.Message)"
        exit 1
    }
}

if (-not (Test-Path $PowerShellPath)) {
    throw "PowerShell executable not found: $PowerShellPath"
}

# Discover tests, then exclude Test-Elevated-*.ps1 unless explicitly included.
$all = Get-ChildItem -Path $PSScriptRoot -Filter 'Test-*.ps1' -File |
       Where-Object { ($_.BaseName -replace '^Test-','') -like $Filter } |
       Sort-Object Name
$tests = @($all | Where-Object {
    if ($IncludeElevated) { return $true }
    return ($_.BaseName -notlike 'Test-Elevated-*')
})
$excluded = @($all | Where-Object { $_ -notin $tests })

if ($tests.Count -eq 0) {
    Write-Host "No tests matched filter '$Filter'." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host " HttpsTimeSync Test Suite" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "PowerShell : $PowerShellPath"
Write-Host "Filter     : $Filter"
Write-Host "Admin      : $((Test-IsAdmin))"
Write-Host "Elevated   : $($IncludeElevated.IsPresent)"
Write-Host "Tests      : $($tests.Count)"
if ($excluded.Count -gt 0) {
    Write-Host "Excluded   : $($excluded.Count)  (run with -IncludeElevated to include)" -ForegroundColor Yellow
    foreach ($e in $excluded) { Write-Host "             - $($e.Name)" -ForegroundColor Yellow }
}
Write-Host ""

$results = @()
$totalStart = Get-Date

foreach ($t in $tests) {
    $start = Get-Date
    Write-Host ">>> $($t.Name)" -ForegroundColor White
    $tmpOut = Join-Path $env:TEMP "runtests-$($t.BaseName)-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        $proc = Start-Process -FilePath $PowerShellPath `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$t.FullName) `
            -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
            -Wait -PassThru -NoNewWindow
        $stdout = ''
        $stderr = ''
        if (Test-Path $tmpOut)       { $c = Get-Content -Raw $tmpOut;       if ($c) { $stdout = $c } }
        if (Test-Path "$tmpOut.err") { $c = Get-Content -Raw "$tmpOut.err"; if ($c) { $stderr = $c } }
        Write-Host $stdout
        if ($stderr.Trim()) {
            Write-Host "--- STDERR ---" -ForegroundColor Yellow
            Write-Host $stderr -ForegroundColor Yellow
        }
        $results += [pscustomobject]@{
            Name      = $t.BaseName
            ExitCode  = $proc.ExitCode
            DurationS = ((Get-Date) - $start).TotalSeconds
        }
    } finally {
        Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
        Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
    }
}

$totalDur = ((Get-Date) - $totalStart).TotalSeconds
$failures = @($results | Where-Object { $_.ExitCode -ne 0 })

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host " Final Results" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
$results | Format-Table @{n='Suite';e={$_.Name}}, @{n='Exit';e={$_.ExitCode}}, @{n='Sec';e={'{0:N1}' -f $_.DurationS}} -AutoSize | Out-Host

if ($failures.Count -eq 0) {
    Write-Host "ALL SUITES PASSED ($($results.Count) suites, $('{0:N1}' -f $totalDur)s total)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) SUITE(S) FAILED (of $($results.Count)):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $($f.Name) (exit $($f.ExitCode))" -ForegroundColor Red
    }
    exit $failures.Count
}
