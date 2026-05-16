# Shared test helpers. Dot-source from each Test-*.ps1.
# Tracks pass/fail counts in script-scope and exposes a tiny assertion DSL.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Suppress Invoke-WebRequest progress bars that otherwise mangle captured output.
$ProgressPreference = 'SilentlyContinue'

$script:TestsRun     = 0
$script:TestsFailed  = 0
$script:Failures     = New-Object System.Collections.Generic.List[string]
$script:CurrentSuite = ''

function Start-TestSuite {
    param([Parameter(Mandatory)][string]$Name)
    $script:CurrentSuite = $Name
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Assert-Test {
    <#
    .SYNOPSIS
        Run a scriptblock; PASS if it does not throw and returns anything that
        is not explicitly $false. FAIL on throw or on $false return.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Test
    )
    $script:TestsRun++
    $label = "  [$($script:CurrentSuite)] $Name"
    try {
        $result = & $Test
        if ($result -is [bool] -and -not $result) {
            $script:TestsFailed++
            $script:Failures.Add("$label  (returned `$false)") | Out-Null
            Write-Host "  FAIL: $Name (returned `$false)" -ForegroundColor Red
            return
        }
        Write-Host "  PASS: $Name" -ForegroundColor Green
    } catch {
        $script:TestsFailed++
        $script:Failures.Add("$label  threw: $($_.Exception.Message)") | Out-Null
        Write-Host "  FAIL: $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual, [string]$Hint = '')
    if ($Expected -ne $Actual) {
        $msg = "expected [$Expected] but got [$Actual]"
        if ($Hint) { $msg += " ($Hint)" }
        throw $msg
    }
    return $true
}

function Assert-True {
    param([Parameter(Mandatory)]$Condition, [string]$Hint = 'condition was false')
    if (-not $Condition) { throw $Hint }
    return $true
}

function Assert-Match {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Pattern, [string]$Hint = '')
    if ($Text -notmatch $Pattern) {
        $msg = "expected text to match /$Pattern/ but it did not. Text was:`n$Text"
        if ($Hint) { $msg = "$Hint`n$msg" }
        throw $msg
    }
    return $true
}

function Assert-NotMatch {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Pattern, [string]$Hint = '')
    if ($Text -match $Pattern) {
        $msg = "expected text to NOT match /$Pattern/ but it did. Text was:`n$Text"
        if ($Hint) { $msg = "$Hint`n$msg" }
        throw $msg
    }
    return $true
}

function Write-TestSummary {
    Write-Host ""
    Write-Host "--- Summary: $($script:CurrentSuite) ---" -ForegroundColor Cyan
    Write-Host "  Ran    : $($script:TestsRun)"
    if ($script:TestsFailed -eq 0) {
        Write-Host "  Passed : $($script:TestsRun)  (all)" -ForegroundColor Green
        Write-Host "  Failed : 0" -ForegroundColor Green
    } else {
        Write-Host "  Passed : $($script:TestsRun - $script:TestsFailed)" -ForegroundColor Green
        Write-Host "  Failed : $($script:TestsFailed)" -ForegroundColor Red
        foreach ($f in $script:Failures) {
            Write-Host "    - $f" -ForegroundColor Red
        }
    }
    return $script:TestsFailed
}

# Locate the repo root from this helper's path: <repo>\tests\_TestHelpers.ps1
function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}
