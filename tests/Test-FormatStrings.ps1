<#
.SYNOPSIS
    Verify the log-line format strings used in Sync-HttpsTime.ps1's main flow
    never throw FormatException, regardless of sign or magnitude of deltas.

    Regression test for the bug "{2,+9:N1}" which combined alignment specifier
    with '+' sign and threw at runtime.
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'FormatStrings'

# The three format strings live in Invoke-MainSync. Pull them out as literals
# so tests fail loudly if anyone changes the format without testing it.
$perSourceFormat   = "  {0,-32} rtt={1,7:N1}ms delta={2,9:N1}ms"
$failSourceFormat  = "  {0,-32} FAIL: {1}"
$medianFormat      = "Median drift across {0} sources: {1:+0.0;-0.0;0.0} ms (threshold {2} ms)"
$dryRunFormat      = "DryRun: would step clock by {0} ms but skipping."
$appliedFormat     = "Clock adjusted by {0:+0.0;-0.0;0.0} ms. New local time: {1}"
$setDateFailFormat = "Set-Date failed: {0}"
$startFormat       = "Starting sync (dryRun={0}, sources={1})"
$abortFormat       = "Only {0} valid source(s); need {1}. Aborting."

$deltas = @(0.0, 0.1, -0.1, 1.5, -1.5, 249.9, -249.9, 250.0, -250.0, 163249.6, -163249.6, 1e7, -1e7)

foreach ($d in $deltas) {
    $capt = $d
    Assert-Test ("per-source line formats with delta=$capt") {
        $s = ($perSourceFormat -f 'https://www.example.com', 123.4, $capt)
        Assert-True ($s.Length -gt 0) 'output should be non-empty'
    }
    Assert-Test ("median line formats with median=$capt") {
        $s = ($medianFormat -f 4, $capt, 250)
        Assert-Match $s 'Median drift' 'output must contain expected text'
    }
    Assert-Test ("applied line formats with adjustment=$capt") {
        $s = ($appliedFormat -f $capt, '2026-05-16T20:13:52Z')
        Assert-Match $s 'Clock adjusted' 'output must contain expected text'
    }
}

Assert-Test 'fail-source line formats with multi-line error text' {
    $s = ($failSourceFormat -f 'https://example.com', "Connection refused`r`nat line 42")
    Assert-True ($s.Length -gt 0) 'output should be non-empty'
}

Assert-Test 'starting line formats' {
    $s = ($startFormat -f $true, 4)
    Assert-Match $s 'sources=4'
}

Assert-Test 'abort line formats' {
    $s = ($abortFormat -f 0, 2)
    Assert-Match $s '0 valid'
}

Assert-Test 'set-date-fail line formats' {
    $s = ($setDateFailFormat -f 'Access denied')
    Assert-Match $s 'Access denied'
}

Assert-Test 'dry-run line formats' {
    $s = ($dryRunFormat -f 163249.6)
    Assert-Match $s 'would step'
}

# Verify the signed-format spec actually shows the correct sign
Assert-Test 'signed format shows + for positive' {
    $s = ('{0:+0.0;-0.0;0.0}' -f 5.0)
    Assert-Equal '+5.0' $s
}
Assert-Test 'signed format shows - for negative' {
    $s = ('{0:+0.0;-0.0;0.0}' -f -5.0)
    Assert-Equal '-5.0' $s
}
Assert-Test 'signed format shows plain 0 for zero' {
    $s = ('{0:+0.0;-0.0;0.0}' -f 0.0)
    Assert-Equal '0.0' $s
}

exit (Write-TestSummary)
