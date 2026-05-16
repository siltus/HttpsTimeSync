<#
.SYNOPSIS
    Verify the try/catch pattern for $MyInvocation.MyCommand.Path under
    Set-StrictMode -Version Latest.

    Regression test for the bug:
        "The property 'Path' cannot be found on this object."
    seen when Install.ps1 was invoked via `iex (irm ...)`.
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'PropertyAccess'

Assert-Test 'direct access throws under strict mode on a ScriptBlock-like context' {
    # Simulate: a scriptblock created from a string has no .Path property.
    # Direct access under Set-StrictMode -Version Latest throws.
    $sb = [scriptblock]::Create({
        Set-StrictMode -Version Latest
        $threw = $false
        try {
            $null = $MyInvocation.MyCommand.Path
        } catch {
            $threw = $true
        }
        $threw
    }.ToString())
    $threw = & $sb
    Assert-True $threw 'expected direct access to throw, but it did not'
}

Assert-Test 'try/catch wrapper yields $null safely' {
    $sb = [scriptblock]::Create({
        Set-StrictMode -Version Latest
        $p = $null
        try { $p = $MyInvocation.MyCommand.Path } catch { }
        # On a scriptblock with no backing file, $p must be $null and we must NOT have thrown.
        $null -eq $p
    }.ToString())
    $result = & $sb
    Assert-True $result 'expected safe-probe to return $null on script-block invocation'
}

Assert-Test 'try/catch wrapper returns real path when script IS a file' {
    # Write a tiny temp script, run it with -File, capture output.
    $tmp = Join-Path $env:TEMP "propaccess-test-$([guid]::NewGuid().Guid.Substring(0,8)).ps1"
    @'
Set-StrictMode -Version Latest
$p = $null
try { $p = $MyInvocation.MyCommand.Path } catch { }
Write-Output $p
'@ | Set-Content -LiteralPath $tmp -Encoding UTF8
    try {
        $out = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -NoProfile -ExecutionPolicy Bypass -File $tmp
        Assert-Equal $tmp $out '$MyInvocation.MyCommand.Path should equal the script file when invoked via -File'
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

exit (Write-TestSummary)
