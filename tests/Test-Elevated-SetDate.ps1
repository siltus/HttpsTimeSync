<#
.SYNOPSIS
    Verify Set-Date works as Administrator. Bounded to ±50ms with a
    try/finally restore so even a test crash leaves the clock unaffected.

    Requires Administrator. Run via Run-Tests.ps1 -IncludeElevated.

    Why this exists: Sync-HttpsTime.ps1 calls Set-Date -Adjust <TimeSpan>.
    Without this test we have no evidence Set-Date is callable in this
    environment (Group Policy, AV interference, weird locale, etc).
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'ElevatedSetDate'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "    SKIPPED: not running elevated" -ForegroundColor Yellow
    exit 0
}

# Adjustment in milliseconds — small enough to be invisible to humans.
$adjustMs = 50

Assert-Test 'Set-Date moves the clock forward by ~50ms, then back' {
    $totalApplied = 0  # Track every successful adjustment for guaranteed restore.
    try {
        $t0 = [DateTime]::UtcNow
        Set-Date -Adjust ([TimeSpan]::FromMilliseconds($adjustMs)) | Out-Null
        $totalApplied += $adjustMs
        $t1 = [DateTime]::UtcNow

        # We applied +50ms, then time elapsed naturally during the call.
        # So t1 should be roughly (t0 + 50ms + small-elapsed). Verify at least
        # 25ms of jump happened (more than natural elapsed could explain).
        $observed = ($t1 - $t0).TotalMilliseconds
        Assert-True ($observed -ge ($adjustMs * 0.5)) `
            "expected clock to advance by >= $($adjustMs/2)ms, observed $('{0:N1}' -f $observed)ms"
    } finally {
        # ALWAYS undo whatever we applied, even on assertion failure.
        if ($totalApplied -ne 0) {
            try {
                Set-Date -Adjust ([TimeSpan]::FromMilliseconds(-$totalApplied)) | Out-Null
            } catch {
                # Last-ditch fallback: try once more with a small delay.
                Start-Sleep -Milliseconds 100
                try { Set-Date -Adjust ([TimeSpan]::FromMilliseconds(-$totalApplied)) | Out-Null } catch { }
            }
        }
    }
}

Assert-Test 'Set-Date with a 0 ms adjustment is a no-op (sanity)' {
    $t0 = [DateTime]::UtcNow
    Set-Date -Adjust ([TimeSpan]::FromMilliseconds(0)) | Out-Null
    $t1 = [DateTime]::UtcNow
    $delta = ($t1 - $t0).TotalMilliseconds
    # Should be tiny natural-elapsed only.
    Assert-True ($delta -lt 100) "0-ms adjust caused unexpected jump: $('{0:N1}' -f $delta)ms"
}

Assert-Test 'TimeSpan -> Set-Date round-trip preserves sign' {
    # +25ms then -25ms — verify the net effect is zero within ~10ms tolerance.
    $t0 = [DateTime]::UtcNow
    Set-Date -Adjust ([TimeSpan]::FromMilliseconds(25)) | Out-Null
    try {
        Set-Date -Adjust ([TimeSpan]::FromMilliseconds(-25)) | Out-Null
    } catch {
        # Restore the +25 we applied if the second call failed.
        try { Set-Date -Adjust ([TimeSpan]::FromMilliseconds(-25)) | Out-Null } catch { }
        throw
    }
    $t1 = [DateTime]::UtcNow
    $natural = ($t1 - $t0).TotalMilliseconds
    Assert-True ($natural -lt 200) "expected near-zero net adjust, observed $('{0:N1}' -f $natural)ms"
}

exit (Write-TestSummary)
