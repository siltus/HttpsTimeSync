<#
.SYNOPSIS
    Installs HttpsTimeSync: copies scripts to ProgramData and registers a
    Scheduled Task that syncs the system clock from HTTPS Date headers.

.DESCRIPTION
    Designed for the one-liner pattern:
        iex (irm https://raw.githubusercontent.com/siltus/HttpsTimeSync/main/Install.ps1)

    The script is self-elevating: if not already Administrator, it re-downloads
    itself to %TEMP% and re-launches under UAC so the user sees the standard
    Windows elevation prompt once.

    When run from a cloned repo (i.e. files are next to this script), it uses
    those local files instead of downloading. This makes the same Install.ps1
    work for both the one-liner case and the "clone + run" case.

.PARAMETER IntervalMinutes
    How often the Scheduled Task fires. Default: 15.

.PARAMETER Ref
    Git ref (branch / tag / commit) to download from. Default: main.
    Can also be set via $env:HTTPSTIMESYNC_REF.

.PARAMETER Repo
    GitHub repo in 'owner/name' form. Default: siltus/HttpsTimeSync.

.PARAMETER InstallDir
    Where to install scripts. Default: C:\ProgramData\HttpsTimeSync.

.PARAMETER SkipImmediateRun
    Don't trigger an immediate sync at the end of install (useful for testing).

.PARAMETER DryElevate
    Test-only. If running non-elevated, performs the safe-property probe and
    prints what WOULD be passed to Start-Process, then exits with code 99
    without invoking UAC. Used by the test suite to verify the elevation
    path doesn't choke under the iex/strict-mode invocation pattern.

.PARAMETER TaskName
    Scheduled Task name to register. Default: HttpsTimeSync. Override only
    if you want multiple parallel installs (e.g., for testing).
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 15,
    [string]$Ref = $(if ($env:HTTPSTIMESYNC_REF) { $env:HTTPSTIMESYNC_REF } else { 'main' }),
    [string]$Repo = 'siltus/HttpsTimeSync',
    [string]$InstallDir = "$env:ProgramData\HttpsTimeSync",
    [string]$TaskName = 'HttpsTimeSync',
    [switch]$SkipImmediateRun,
    [switch]$DryElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# TLS 1.2 for PS 5.1.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$RawBase  = "https://raw.githubusercontent.com/$Repo/$Ref"
$Files    = @('Sync-HttpsTime.ps1', 'config.default.json', 'Show-Log.ps1')

function Write-Section([string]$Msg) {
    Write-Host ''
    Write-Host "=== $Msg ===" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Self-elevate ---
if (-not (Test-IsAdmin)) {
    Write-Section "Elevating"
    Write-Host "Not running as Administrator. Re-launching with UAC prompt..."

    # When run via `irm | iex`, $MyInvocation.MyCommand has no .Path property
    # at all (it's a ScriptBlock-like context), so direct access throws under
    # Set-StrictMode. Probe safely via try/catch.
    $selfPath = $null
    try { $selfPath = $MyInvocation.MyCommand.Path } catch { }

    if ($DryElevate) {
        # Test mode: prove the property probe survived, do NOT spawn UAC.
        Write-Host "DryElevate: selfPath = [$selfPath]"
        Write-Host "DryElevate: would Start-Process -Verb RunAs with above as -File arg"
        Write-Host "DryElevate: exiting 99 (test marker) before any system change."
        exit 99
    }

    $tempScript = Join-Path $env:TEMP "HttpsTimeSync-Install-$([guid]::NewGuid().Guid.Substring(0,8)).ps1"
    if ($selfPath -and (Test-Path $selfPath)) {
        Copy-Item -LiteralPath $selfPath -Destination $tempScript -Force
    } else {
        Invoke-WebRequest -Uri "$RawBase/Install.ps1" -OutFile $tempScript -UseBasicParsing
    }

    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$tempScript,
        '-IntervalMinutes', $IntervalMinutes,
        '-Ref', $Ref,
        '-Repo', $Repo,
        '-InstallDir', $InstallDir,
        '-TaskName', $TaskName
    )
    if ($SkipImmediateRun) { $argList += '-SkipImmediateRun' }

    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                           -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-Error "Elevation was cancelled or failed: $($_.Exception.Message)"
        exit 1
    } finally {
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force -ErrorAction SilentlyContinue }
    }
}

Write-Section "HttpsTimeSync Installer"
Write-Host "Repo        : $Repo @ $Ref"
Write-Host "InstallDir  : $InstallDir"
Write-Host "Interval    : $IntervalMinutes minute(s)"
Write-Host "Task name   : $TaskName"

# --- Sanity checks ---
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.0+ required; found $($PSVersionTable.PSVersion)."
}

# --- Stage files into InstallDir ---
Write-Section "Staging files"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Host "Created $InstallDir"
}

# If running from a cloned repo (files next to this script), use them; else download.
$selfDir = $null
try {
    if ($MyInvocation.MyCommand.Path) {
        $selfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
} catch { }
$useLocal = $selfDir -and (Test-Path (Join-Path $selfDir 'Sync-HttpsTime.ps1'))

foreach ($f in $Files) {
    $dest = Join-Path $InstallDir $f
    if ($useLocal) {
        $src = Join-Path $selfDir $f
        Copy-Item -LiteralPath $src -Destination $dest -Force
        Write-Host "Copied  $f  (from $selfDir)"
    } else {
        $url = "$RawBase/$f"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        Write-Host "Fetched $f  ($url)"
    }
}

# config.json is ALWAYS overwritten from defaults. Running Install.ps1 is
# explicit user intent to "install", which resets state. Customize config.json
# AFTER install if needed; do not re-run Install.ps1 to keep customizations.
$cfgDefault = Join-Path $InstallDir 'config.default.json'
$cfgActive  = Join-Path $InstallDir 'config.json'
Copy-Item -LiteralPath $cfgDefault -Destination $cfgActive -Force
Write-Host "config.json written from defaults."

# --- Verify with a dry run ---
Write-Section "Verifying (dry run)"
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$syncScript = Join-Path $InstallDir 'Sync-HttpsTime.ps1'
$dryArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$syncScript,'-DryRun')
$dryRun = Start-Process -FilePath $psExe -ArgumentList $dryArgs -Wait -PassThru -NoNewWindow
if ($dryRun.ExitCode -ne 0) {
    Write-Warning "Dry run exited with code $($dryRun.ExitCode). Continuing install anyway; check log:"
    Write-Warning "  C:\ProgramData\HttpsTimeSync\sync.log"
}

# --- Register the Scheduled Task as SYSTEM ---
Write-Section "Registering Scheduled Task"
$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $syncScript)

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 9999)
# 9999 days (~27 years) is the documented sweet spot. Anything larger is
# rejected by Windows ("Duration:P<N>D out of range" because the XSD limits
# the days field to 4 digits). Omitting -RepetitionDuration was the v1 bug —
# despite Microsoft docs claiming it produces indefinite repetition, on
# Windows 10/11 the trigger fires only once and never repeats.
# Sources:
#   https://learn.microsoft.com/en-us/answers/questions/145419/
#   https://stackoverflow.com/questions/29953897/

$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest -LogonType ServiceAccount

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed existing task '$TaskName'."
}

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Sync system clock via HTTPS Date headers (NTP-blocked networks)." | Out-Null
Write-Host "Registered task '$TaskName' (every $IntervalMinutes min, runs as SYSTEM)."

# --- Trigger once now, watch result ---
if (-not $SkipImmediateRun) {
    Write-Section "Triggering immediate sync"
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ("LastRunTime  : {0}" -f $info.LastRunTime)
    Write-Host ("LastResult   : 0x{0:X8} ({0})" -f $info.LastTaskResult)
}

Write-Section "Done"
$logPath = (Get-Content -Raw -LiteralPath $cfgActive | ConvertFrom-Json).logPath
Write-Host ""
Write-Host "  Install dir : $InstallDir"
Write-Host "  Log file    : $logPath"
Write-Host "  Config      : $cfgActive"
Write-Host ""
Write-Host "  View log    : powershell -File `"$InstallDir\Show-Log.ps1`""
Write-Host "  Live tail   : powershell -File `"$InstallDir\Show-Log.ps1`" -Follow"
Write-Host "  List zips   : powershell -File `"$InstallDir\Show-Log.ps1`" -List"
Write-Host "  Open folder : powershell -File `"$InstallDir\Show-Log.ps1`" -Open"
Write-Host "  Run now     : Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Task status : Get-ScheduledTaskInfo -TaskName $TaskName"
Write-Host "  Uninstall   : iex (irm https://raw.githubusercontent.com/$Repo/$Ref/Uninstall.ps1)"
Write-Host ""
