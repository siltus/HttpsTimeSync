<#
.SYNOPSIS
    THE regression test for the bug user reported ("no UAC"):
    invoking Install.ps1 via iex (mimicking `irm | iex`) must NOT throw
    "The property 'Path' cannot be found on this object" under strict mode.

    Uses Install.ps1's -DryElevate switch so we can assert exit code 99
    without actually spawning UAC.
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'InstallIex'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# These tests specifically exercise Install.ps1/Uninstall.ps1's NON-ADMIN
# elevation code path. When the runner is already admin, the entire elevation
# block is skipped — there is no way to test it from inside an elevated
# process. The default (non-elevated) Run-Tests.ps1 invocation always
# provides coverage of this suite.
if (Test-IsAdmin) {
    Write-Host "    SKIPPED: Test-InstallIex exercises the non-admin elevation path." -ForegroundColor Yellow
    Write-Host "             It runs automatically via Run-Tests.ps1 (without -IncludeElevated)." -ForegroundColor Yellow
    exit 0
}

$repoRoot = Get-RepoRoot
$installPath = Join-Path $repoRoot 'Install.ps1'

Assert-Test 'Install.ps1 exists' {
    Assert-True (Test-Path $installPath) "Install.ps1 not found at $installPath"
}

# We need to invoke Install.ps1 in a way that reproduces the bug:
# - No backing file (so $MyInvocation.MyCommand.Path doesn't exist on the object)
# - Set-StrictMode -Version Latest active
# - Param-binding still works so we can pass -DryElevate
#
# `& ([scriptblock]::Create($code)) -DryElevate` matches `iex` behavior:
# both create a script block with no .Path property and bind params.
Assert-Test 'invocation via scriptblock with no .Path does not throw property error' {
    $tmpOut = Join-Path $env:TEMP "install-iex-test-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        # Build the wrapper that gets executed inside the child shell.
        # Using @' '@ here-string to avoid interpolation; we'll substitute paths via -ArgumentList.
        $wrapper = @"
`$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
`$installContent = Get-Content -Raw -LiteralPath '$installPath'
`$sb = [scriptblock]::Create(`$installContent)
& `$sb -DryElevate
exit `$LASTEXITCODE
"@
        $proc = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$wrapper) `
            -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
            -Wait -PassThru -NoNewWindow

        $stdout = if (Test-Path $tmpOut)      { Get-Content -Raw $tmpOut }      else { '' }
        $stderr = if (Test-Path "$tmpOut.err"){ Get-Content -Raw "$tmpOut.err" } else { '' }
        $combined = "$stdout`n$stderr"

        # Assertion 1: NO occurrence of the bug error
        Assert-NotMatch $combined 'property .Path. cannot be found' 'the strict-mode property bug has regressed'

        # Assertion 2: exit code 99 (the DryElevate marker)
        Assert-Equal 99 $proc.ExitCode "expected exit 99 from -DryElevate, got $($proc.ExitCode). Output was:`n$combined"

        # Assertion 3: DryElevate marker present in output (the script reached the elevation block)
        Assert-Match $stdout 'DryElevate: selfPath' 'DryElevate marker not in output - script did not reach elevation block'
    } finally {
        Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
        Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
    }
}

# Also test on PowerShell 7 if present
Assert-Test 'same invocation works under PowerShell 7' {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Host "    (skipping: pwsh.exe not found)" -ForegroundColor Yellow
        return $true
    }
    $tmpOut = Join-Path $env:TEMP "install-iex-test-pwsh-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        $wrapper = @"
`$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
`$installContent = Get-Content -Raw -LiteralPath '$installPath'
`$sb = [scriptblock]::Create(`$installContent)
& `$sb -DryElevate
exit `$LASTEXITCODE
"@
        $proc = Start-Process -FilePath $pwsh.Path `
            -ArgumentList @('-NoProfile','-Command',$wrapper) `
            -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
            -Wait -PassThru -NoNewWindow

        $stdout = if (Test-Path $tmpOut)      { Get-Content -Raw $tmpOut }      else { '' }
        $stderr = if (Test-Path "$tmpOut.err"){ Get-Content -Raw "$tmpOut.err" } else { '' }
        $combined = "$stdout`n$stderr"

        Assert-NotMatch $combined 'property .Path. cannot be found' 'PS7: property bug regression'
        Assert-Equal 99 $proc.ExitCode "PS7: expected exit 99, got $($proc.ExitCode). Output:`n$combined"
    } finally {
        Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
        Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
    }
}

# Also test Uninstall.ps1 (same bug, same fix) — uses its own -DryElevate.
Assert-Test 'Uninstall.ps1 via scriptblock with -DryElevate does not throw property error' {
    $uninstallPath = Join-Path $repoRoot 'Uninstall.ps1'
    Assert-True (Test-Path $uninstallPath) "Uninstall.ps1 not found at $uninstallPath"
    $tmpOut = Join-Path $env:TEMP "uninst-iex-test-$([guid]::NewGuid().Guid.Substring(0,8)).txt"
    try {
        $wrapper = @"
`$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
`$content = Get-Content -Raw -LiteralPath '$uninstallPath'
`$sb = [scriptblock]::Create(`$content)
& `$sb -DryElevate
exit `$LASTEXITCODE
"@
        $proc = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$wrapper) `
            -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
            -Wait -PassThru -NoNewWindow

        $stdout = ''; $stderr = ''
        if (Test-Path $tmpOut)       { $c = Get-Content -Raw $tmpOut;       if ($c) { $stdout = $c } }
        if (Test-Path "$tmpOut.err") { $c = Get-Content -Raw "$tmpOut.err"; if ($c) { $stderr = $c } }
        $combined = "$stdout`n$stderr"

        Assert-NotMatch $combined 'property .Path. cannot be found' 'Uninstall.ps1: property bug regression'
        Assert-Equal 99 $proc.ExitCode "expected exit 99 from Uninstall -DryElevate, got $($proc.ExitCode). Output:`n$combined"
        Assert-Match $stdout 'DryElevate: selfPath' 'DryElevate marker not in Uninstall output'
    } finally {
        Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
        Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
    }
}

exit (Write-TestSummary)
