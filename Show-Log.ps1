<#
.SYNOPSIS
    Show / tail / list HttpsTimeSync logs.

.DESCRIPTION
    Convenience helper so you don't have to remember the log path.
    Run with no args to print the last 50 lines.
    Add -Follow to live-tail.
    Add -List to enumerate rotated zip archives.
    Add -Open to launch the install folder in Explorer.

.PARAMETER Lines
    Trailing lines to show (default 50). Ignored with -List / -Open.

.PARAMETER Follow
    Keep tailing as new lines are written (Ctrl+C to stop).

.PARAMETER List
    List rotated log archives (sync.*.log.zip) with size + age.

.PARAMETER Open
    Open the install directory in Windows Explorer.

.PARAMETER InstallDir
    Override install dir. Default: C:\ProgramData\HttpsTimeSync.

.EXAMPLE
    # Last 50 lines
    .\Show-Log.ps1

.EXAMPLE
    # Live tail
    .\Show-Log.ps1 -Follow

.EXAMPLE
    # See what rotated archives exist
    .\Show-Log.ps1 -List
#>
[CmdletBinding(DefaultParameterSetName='Tail')]
param(
    [Parameter(ParameterSetName='Tail')][int]$Lines = 50,
    [Parameter(ParameterSetName='Tail')][switch]$Follow,
    [Parameter(ParameterSetName='List')][switch]$List,
    [Parameter(ParameterSetName='Open')][switch]$Open,
    [string]$InstallDir = "$env:ProgramData\HttpsTimeSync"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfgPath = Join-Path $InstallDir 'config.json'
if (Test-Path $cfgPath) {
    $LogPath = (Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json).logPath
} else {
    $LogPath = Join-Path $InstallDir 'sync.log'
}
$LogDir = Split-Path -Parent $LogPath

if ($Open) {
    if (-not (Test-Path $LogDir)) { Write-Warning "Directory not found: $LogDir"; return }
    Start-Process explorer.exe $LogDir
    return
}

if ($List) {
    if (-not (Test-Path $LogDir)) { Write-Warning "Directory not found: $LogDir"; return }
    $now = Get-Date
    $rows = Get-ChildItem -LiteralPath $LogDir -Filter 'sync.*.log.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object {
            $age = $now - $_.LastWriteTime
            [pscustomobject]@{
                Name      = $_.Name
                SizeKB    = '{0,8:N1}' -f ($_.Length / 1KB)
                Modified  = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                AgeDays   = '{0,5:N1}' -f $age.TotalDays
            }
        }
    if (-not $rows) {
        Write-Host "No rotated log archives in $LogDir."
        Write-Host "(They appear once sync.log grows past logMaxBytes.)"
    } else {
        $rows | Format-Table -AutoSize
    }
    # Also show the live log size.
    if (Test-Path $LogPath) {
        $live = Get-Item $LogPath
        Write-Host ""
        Write-Host ("Active : {0}  ({1:N1} KB, last write {2})" -f `
            $live.Name, ($live.Length/1KB), $live.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    }
    return
}

# Default: tail
if (-not (Test-Path $LogPath)) {
    Write-Warning "Log file not found: $LogPath"
    Write-Warning "Has the task run yet?  Try: Start-ScheduledTask -TaskName HttpsTimeSync"
    return
}

Write-Host "--- $LogPath (last $Lines lines) ---" -ForegroundColor Cyan
if ($Follow) {
    Get-Content -LiteralPath $LogPath -Tail $Lines -Wait
} else {
    Get-Content -LiteralPath $LogPath -Tail $Lines
}
