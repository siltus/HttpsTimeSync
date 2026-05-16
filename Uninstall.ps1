<#
.SYNOPSIS
    Removes HttpsTimeSync: unregisters the Scheduled Task and (optionally)
    deletes the install directory.

.DESCRIPTION
    One-liner:
        iex (irm https://raw.githubusercontent.com/siltus/HttpsTimeSync/main/Uninstall.ps1)

.PARAMETER InstallDir
    Where the scripts were installed. Default: C:\ProgramData\HttpsTimeSync.

.PARAMETER TaskName
    Scheduled Task name to remove. Default: HttpsTimeSync. Override only
    if you installed with a non-default task name (e.g. for testing).

.PARAMETER KeepFiles
    Keep the install directory (script, config, log). By default they are removed.

.PARAMETER DryElevate
    Test-only. If running non-elevated, performs the safe-property probe
    and exits with code 99 without invoking UAC.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramData\HttpsTimeSync",
    [string]$TaskName = 'HttpsTimeSync',
    [switch]$KeepFiles,
    [switch]$DryElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Not running as Administrator. Re-launching with UAC prompt..."
    # Safe property probe — see Install.ps1 for rationale.
    $selfPath = $null
    try { $selfPath = $MyInvocation.MyCommand.Path } catch { }

    if ($DryElevate) {
        Write-Host "DryElevate: selfPath = [$selfPath]"
        Write-Host "DryElevate: would Start-Process -Verb RunAs to elevate."
        Write-Host "DryElevate: exiting 99 (test marker) before any system change."
        exit 99
    }

    $tempScript = Join-Path $env:TEMP "HttpsTimeSync-Uninstall-$([guid]::NewGuid().Guid.Substring(0,8)).ps1"
    if ($selfPath -and (Test-Path $selfPath)) {
        Copy-Item -LiteralPath $selfPath -Destination $tempScript -Force
    } else {
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/siltus/HttpsTimeSync/main/Uninstall.ps1' `
            -OutFile $tempScript -UseBasicParsing
    }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$tempScript,
                 '-InstallDir',$InstallDir,'-TaskName',$TaskName)
    if ($KeepFiles) { $argList += '-KeepFiles' }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } finally {
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host "=== HttpsTimeSync Uninstaller ===" -ForegroundColor Cyan
Write-Host "Task name  : $TaskName"
Write-Host "Install dir: $InstallDir"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed Scheduled Task '$TaskName'."
} else {
    Write-Host "No Scheduled Task '$TaskName' found."
}

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir"
} elseif ($KeepFiles) {
    Write-Host "Kept $InstallDir (per -KeepFiles)."
}

Write-Host "Done."
