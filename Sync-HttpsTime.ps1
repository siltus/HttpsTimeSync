<#
.SYNOPSIS
    Synchronizes the Windows system clock using HTTPS Date headers.

.DESCRIPTION
    For networks where UDP/123 (NTP) is blocked. Queries several HTTPS
    endpoints, parses the RFC 7231 Date: header from each response,
    compensates for round-trip time, takes the median offset across
    valid sources, and steps the local clock if the absolute drift
    exceeds the configured threshold.

    Accuracy ceiling is ~0.5 second because the HTTP Date header has
    1-second precision. Use real NTP if you can; this is a fallback.

    Requires Administrator (Set-Date is privileged). Designed to run
    as NT AUTHORITY\SYSTEM from a Scheduled Task; see Install.ps1.

    The file is structured so that dot-sourcing (e.g. from tests) loads
    the functions WITHOUT running the main flow. The main flow only runs
    when the script is invoked directly (e.g. via -File).

.PARAMETER ConfigPath
    Path to config.json. Defaults to <script-dir>\config.json.

.PARAMETER DryRun
    Query sources and compute drift, but do NOT call Set-Date. Used
    by the installer to verify connectivity before registering the task.

.PARAMETER Quiet
    Suppress console output (still writes to log file).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Sync-HttpsTime.ps1 -DryRun

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script-scope state set by Invoke-MainSync; Write-SyncLog reads it.
# When dot-sourced for tests, these stay null/false and Write-SyncLog
# degrades to console-only (no file logging).
$script:SyncConfig = $null
$script:SyncQuiet  = $false

function Initialize-TlsForLegacy {
    # PS 5.1 defaults to TLS 1.0/1.1, which modern HTTPS endpoints reject.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

function ConvertFrom-HttpDate {
    <#
    .SYNOPSIS
        Parse an HTTP Date header into a UTC DateTime, or $null on failure.
    .DESCRIPTION
        Accepts RFC 7231 IMF-fixdate (the only modern-compliant format) and
        falls back to RFC 850 / asctime() for non-compliant servers.
        Always returns DateTime with Kind=Utc on success, $null on failure.
        Never throws — pure function suitable for unit testing.
    .EXAMPLE
        ConvertFrom-HttpDate 'Sat, 16 May 2026 20:13:52 GMT'
    #>
    [CmdletBinding()]
    [OutputType([Nullable[DateTime]])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$DateString)

    if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    [DateTime]$parsed = [DateTime]::MinValue

    # Primary: RFC 7231 IMF-fixdate via the 'r' specifier. Requires DateTimeStyles.None;
    # combining 'r' with AssumeUniversal/AdjustToUniversal fails.
    $ok = [DateTime]::TryParseExact($DateString, 'r', $inv,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)

    if (-not $ok) {
        # Fallback: RFC 850 ("Sunday, 06-Nov-94 08:49:37 GMT") and similar.
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
                  [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $ok = [DateTime]::TryParse($DateString, $inv, $styles, [ref]$parsed)
    }

    if (-not $ok) { return $null }

    if ($parsed.Kind -ne [DateTimeKind]::Utc) {
        return [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }
    return $parsed
}

function Get-MedianDelta {
    <#
    .SYNOPSIS
        Return the median of a numeric array, or $null for empty input.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[double]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Deltas)

    if ($null -eq $Deltas -or $Deltas.Count -eq 0) { return $null }
    $sorted = @($Deltas | Sort-Object)
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return [double]$sorted[[int](($n - 1) / 2)] }
    return [double](($sorted[$n/2 - 1] + $sorted[$n/2]) / 2.0)
}

function Invoke-LogRotationIfNeeded {
    <#
    .SYNOPSIS
        Rotate $LogPath to a timestamped .zip when it exceeds $MaxBytes;
        retain only the $KeepRotated newest rotated zips.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][int64]$MaxBytes,
        [Parameter(Mandatory)][int]$KeepRotated
    )
    if (-not (Test-Path $LogPath)) { return }
    if ((Get-Item $LogPath).Length -le $MaxBytes) { return }

    $logDir  = Split-Path -Parent $LogPath
    $base    = [IO.Path]::GetFileNameWithoutExtension($LogPath)   # 'sync'
    $ext     = [IO.Path]::GetExtension($LogPath)                  # '.log'
    $stamp   = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $staging = Join-Path $logDir ('{0}.{1}{2}' -f $base, $stamp, $ext)
    $zipPath = "$staging.zip"

    Move-Item -LiteralPath $LogPath -Destination $staging -Force
    try {
        Compress-Archive -LiteralPath $staging -DestinationPath $zipPath -Force -CompressionLevel Optimal
    } catch {
        # Compression failed: put the original back so we don't lose lines.
        if (Test-Path $staging) { Move-Item -LiteralPath $staging -Destination $LogPath -Force }
        throw
    }
    if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }

    # Retention: keep N most-recent rotated zips by lexicographic name (timestamp-ordered).
    $pattern = '{0}.*{1}.zip' -f $base, $ext
    $zips = @(Get-ChildItem -LiteralPath $logDir -Filter $pattern -File -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending)
    if ($zips.Count -gt $KeepRotated) {
        $zips | Select-Object -Skip $KeepRotated |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Write-SyncLog {
    <#
    .SYNOPSIS
        Log to console (unless $script:SyncQuiet) and to $script:SyncConfig.logPath
        (if config is loaded). Best-effort — never throws.
    #>
    param([string]$Level, [string]$Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $Message)
    if (-not $script:SyncQuiet) { Write-Host $line }
    if (-not $script:SyncConfig) { return }  # No config loaded — console-only
    try {
        $logDir = Split-Path -Parent $script:SyncConfig.logPath
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Invoke-LogRotationIfNeeded -LogPath $script:SyncConfig.logPath `
            -MaxBytes ([int64]$script:SyncConfig.logMaxBytes) `
            -KeepRotated ([int]$script:SyncConfig.logKeepRotated)
        Add-Content -LiteralPath $script:SyncConfig.logPath -Value $line -Encoding UTF8
    } catch {
        if (-not $script:SyncQuiet) { Write-Host "log-write-failed: $($_.Exception.Message)" }
    }
}

function Get-HttpsTimeSample {
    <#
    .SYNOPSIS
        Query one HTTPS source, return a sample object with Url, Ok, Error,
        RttMs, DeltaMs (server - localMidpoint), ServerUtc.
    #>
    [CmdletBinding()]
    param([string]$Url, [int]$TimeoutSec)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $preUtc = [DateTime]::UtcNow
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing `
            -TimeoutSec $TimeoutSec -MaximumRedirection 2 -ErrorAction Stop
    } catch {
        # Some CDNs reject HEAD; fall back to GET of root.
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing `
                -TimeoutSec $TimeoutSec -MaximumRedirection 2 -ErrorAction Stop
        } catch {
            return [pscustomobject]@{
                Url = $Url; Ok = $false; Error = $_.Exception.Message
                RttMs = $null; DeltaMs = $null; ServerUtc = $null
            }
        }
    }
    $sw.Stop()
    $rttMs = $sw.Elapsed.TotalMilliseconds

    $dateStr = $null
    if ($resp.Headers.ContainsKey('Date')) {
        # PS 5.1 returns string; PS 7 returns string[] (HTTP headers can repeat).
        # Coerce to single string by taking the first value.
        $raw = $resp.Headers['Date']
        if ($null -ne $raw) {
            $dateStr = [string](@($raw)[0])
        }
    }
    if ([string]::IsNullOrWhiteSpace($dateStr)) {
        return [pscustomobject]@{
            Url = $Url; Ok = $false; Error = 'No Date header in response'
            RttMs = $rttMs; DeltaMs = $null; ServerUtc = $null
        }
    }

    $serverUtc = ConvertFrom-HttpDate -DateString $dateStr
    if (-not $serverUtc) {
        return [pscustomobject]@{
            Url = $Url; Ok = $false; Error = "Unparseable Date: '$dateStr'"
            RttMs = $rttMs; DeltaMs = $null; ServerUtc = $null
        }
    }

    # NTP-style symmetric-delay assumption: server's reported time was
    # at the midpoint of the round trip.
    $localMid = $preUtc.AddMilliseconds($rttMs / 2.0)
    $deltaMs = ($serverUtc - $localMid).TotalMilliseconds

    [pscustomobject]@{
        Url = $Url; Ok = $true; Error = $null
        RttMs = $rttMs; DeltaMs = $deltaMs; ServerUtc = $serverUtc
    }
}

function Invoke-MainSync {
    <#
    .SYNOPSIS
        Run one full sync cycle: load config, query sources, compute median
        offset, conditionally call Set-Date. Returns an integer exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$DryRun,
        [switch]$Quiet
    )

    Initialize-TlsForLegacy

    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
    $script:SyncConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    $script:SyncQuiet  = [bool]$Quiet

    Write-SyncLog 'INFO' ("Starting sync (dryRun={0}, sources={1})" -f $DryRun, $script:SyncConfig.sources.Count)

    $samples = @()
    foreach ($url in $script:SyncConfig.sources) {
        $s = Get-HttpsTimeSample -Url $url -TimeoutSec ([int]$script:SyncConfig.timeoutSec)
        if ($s.Ok) {
            Write-SyncLog 'INFO' ("  {0,-32} rtt={1,7:N1}ms delta={2,9:N1}ms" -f $url, $s.RttMs, $s.DeltaMs)
        } else {
            Write-SyncLog 'WARN' ("  {0,-32} FAIL: {1}" -f $url, $s.Error)
        }
        $samples += $s
    }

    $valid = @($samples | Where-Object { $_.Ok -and $_.RttMs -lt ([double]$script:SyncConfig.maxRttSec * 1000.0) })
    if ($valid.Count -lt [int]$script:SyncConfig.minValidSources) {
        Write-SyncLog 'ERROR' ("Only {0} valid source(s); need {1}. Aborting." -f $valid.Count, $script:SyncConfig.minValidSources)
        return 2
    }

    $deltas = [double[]]@($valid | ForEach-Object { [double]$_.DeltaMs })
    $medianMs = Get-MedianDelta -Deltas $deltas
    $absMs = [Math]::Abs($medianMs)
    Write-SyncLog 'INFO' ("Median drift across {0} sources: {1:+0.0;-0.0;0.0} ms (threshold {2} ms)" -f $valid.Count, $medianMs, $script:SyncConfig.thresholdMs)

    if ($absMs -lt [double]$script:SyncConfig.thresholdMs) {
        Write-SyncLog 'INFO' "Within threshold; no clock change."
        return 0
    }

    if ($DryRun) {
        Write-SyncLog 'INFO' "DryRun: would step clock by $([Math]::Round($medianMs,1)) ms but skipping."
        return 0
    }

    # Apply the offset. Set-Date can take a TimeSpan (relative adjust) —
    # safer than computing an absolute time because UtcNow may have drifted
    # further during this script's run.
    try {
        $adjust = [TimeSpan]::FromMilliseconds($medianMs)
        Set-Date -Adjust $adjust | Out-Null
        Write-SyncLog 'INFO' ("Clock adjusted by {0:+0.0;-0.0;0.0} ms. New local time: {1}" -f $medianMs, (Get-Date -Format 'o'))
        return 0
    } catch {
        Write-SyncLog 'ERROR' ("Set-Date failed: {0}" -f $_.Exception.Message)
        return 3
    }
}

# --- Entry point ---
# Run main flow only when invoked directly (not dot-sourced).
# Dot-source sets $MyInvocation.InvocationName to '.', file-invoke sets it
# to the script path. We also accept empty (some embedded hosts).
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    if (-not $ConfigPath) {
        $scriptDir = $null
        try { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
        if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
        $ConfigPath = Join-Path $scriptDir 'config.json'
    }
    $exitCode = Invoke-MainSync -ConfigPath $ConfigPath -DryRun:$DryRun -Quiet:$Quiet
    exit $exitCode
}
