<#
.SYNOPSIS
    Install into a sandbox, trigger the Scheduled Task, wait for it to run,
    and verify it executed successfully as SYSTEM with the log written.

    Requires Administrator. Run via Run-Tests.ps1 -IncludeElevated.

    Proves the full SYSTEM-context execution path: the task launches under
    SYSTEM, has network access, parses HTTPS Date headers, computes drift,
    and writes the log file with SYSTEM-level permissions.
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'ElevatedScheduled'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "    SKIPPED: not running elevated" -ForegroundColor Yellow
    exit 0
}

$repoRoot      = Get-RepoRoot
$installScript = Join-Path $repoRoot 'Install.ps1'
$uninstScript  = Join-Path $repoRoot 'Uninstall.ps1'
$psExe         = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$sandboxId   = [guid]::NewGuid().Guid.Substring(0,8)
$sandboxDir  = Join-Path $env:TEMP "HttpsTimeSync-Sched-$sandboxId"
$sandboxTask = "HttpsTimeSync-Sched-$sandboxId"
$sandboxLog  = Join-Path $sandboxDir 'sync.log'

Write-Host "  Sandbox dir  : $sandboxDir"
Write-Host "  Sandbox task : $sandboxTask"

function Invoke-Cleanup {
    try {
        if (Get-ScheduledTask -TaskName $sandboxTask -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $sandboxTask -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        if (Test-Path $sandboxDir) { Remove-Item -LiteralPath $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}

try {
    # Install into sandbox first (this is verified by Test-Elevated-Install too;
    # we just re-do it here for self-containment).
    Assert-Test 'install completes (prerequisite)' {
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installScript,
                            '-InstallDir',$sandboxDir,'-TaskName',$sandboxTask,'-SkipImmediateRun') `
            -Wait -PassThru -NoNewWindow
        Assert-Equal 0 $proc.ExitCode "install exited $($proc.ExitCode)"
    }

    # Point the sandboxed config's log path at the sandbox dir (so SYSTEM writes there,
    # not at C:\ProgramData\HttpsTimeSync\sync.log which a real install would use).
    Assert-Test 'rewrite sandbox config.json to log into sandbox dir' {
        $cfgPath = Join-Path $sandboxDir 'config.json'
        $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
        $cfg.logPath = $sandboxLog
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        Assert-True (Test-Path $cfgPath) 'config.json must still exist after rewrite'
    }

    Assert-Test 'task can be triggered and completes within 60s' {
        # Make sure no prior log exists so we can detect a fresh write.
        if (Test-Path $sandboxLog) { Remove-Item $sandboxLog -Force }

        # Replace the install-registered trigger (which fires +1 min then every 15)
        # with a far-future one. Eliminates the race where the auto-trigger fires
        # mid-test and leaves the task in 'Running' state when the deadline hits.
        $farFuture = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(24)
        Set-ScheduledTask -TaskName $sandboxTask -Trigger $farFuture | Out-Null

        $beforeRun = Get-Date
        Start-ScheduledTask -TaskName $sandboxTask

        # Two-phase poll: wait to see Running (or log written), then wait for not-Running.
        $deadline   = (Get-Date).AddSeconds(60)
        $sawRunning = $false
        $info = $null
        $task = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $info = Get-ScheduledTaskInfo -TaskName $sandboxTask
            $task = Get-ScheduledTask     -TaskName $sandboxTask
            if ($task.State -eq 'Running') { $sawRunning = $true; continue }
            $logFresh = (Test-Path $sandboxLog) -and ((Get-Item $sandboxLog).LastWriteTime -gt $beforeRun)
            if (($sawRunning -or $logFresh) -and $task.State -ne 'Running') { break }
        }

        Assert-True ($null -ne $info) 'failed to get task info'
        Assert-True ($task.State -ne 'Running') `
            "task still 'Running' at deadline (LastResult=0x$('{0:X8}' -f $info.LastTaskResult))"

        if ($info.LastTaskResult -ne 0) {
            $logTail = if (Test-Path $sandboxLog) { Get-Content -Raw $sandboxLog } else { '<no log>' }
            throw "LastTaskResult was 0x$('{0:X8}' -f $info.LastTaskResult) (not 0). State=$($task.State). Log was:`n$logTail"
        }
    }

    Assert-Test 'log file was written by SYSTEM and contains expected lines' {
        Assert-True (Test-Path $sandboxLog) "log file not written: $sandboxLog"
        $content = Get-Content -Raw $sandboxLog
        Assert-Match $content 'Starting sync'         'log should contain start banner'
        Assert-Match $content 'Median drift across'   'log should contain median-drift line'
        # ACL check: file should exist and be readable; SYSTEM owns it.
        $owner = (Get-Acl $sandboxLog).Owner
        Assert-True ($owner -match 'SYSTEM|Administrators') "log owner unexpected: $owner"
    }

    Assert-Test 'log timestamp is recent (within last 60s)' {
        $age = (Get-Date) - (Get-Item $sandboxLog).LastWriteTime
        Assert-True ($age.TotalSeconds -lt 60) "log too old: $($age.TotalSeconds) seconds"
    }

    # Verify a SECOND run also works (proves the task is robustly re-triggerable).
    Assert-Test 'second trigger also succeeds' {
        $sizeBefore = (Get-Item $sandboxLog).Length
        $beforeRun  = Get-Date
        Start-ScheduledTask -TaskName $sandboxTask
        $deadline = (Get-Date).AddSeconds(60)
        $sawRunning = $false
        $info = $null
        $task = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $info = Get-ScheduledTaskInfo -TaskName $sandboxTask
            $task = Get-ScheduledTask     -TaskName $sandboxTask
            if ($task.State -eq 'Running') { $sawRunning = $true; continue }
            $logGrew = (Get-Item $sandboxLog).Length -gt $sizeBefore
            if (($sawRunning -or $logGrew) -and $task.State -ne 'Running') { break }
        }
        Assert-True ($task.State -ne 'Running') "still Running at deadline"
        Assert-Equal 0 $info.LastTaskResult "second run LastTaskResult (state=$($task.State))"
        $sizeAfter = (Get-Item $sandboxLog).Length
        Assert-True ($sizeAfter -gt $sizeBefore) 'log should have grown after second run'
    }

    # THE regression test for the v1 trigger-Duration bug. Install with a 1-minute
    # interval into a SEPARATE sandbox, wait ~150 s, count actual scheduled runs.
    # If trigger.Repetition.Duration is empty (the bug), we'll see 0-1 runs; with
    # the fix we should see 2+ (the +1-min initial fire and at least one repetition).
    Assert-Test 'scheduled trigger fires REPEATEDLY (not just once) with -IntervalMinutes 1' {
        $repId   = [guid]::NewGuid().Guid.Substring(0,8)
        $repDir  = Join-Path $env:TEMP "HttpsTimeSync-Rep-$repId"
        $repTask = "HttpsTimeSync-Rep-$repId"
        $repLog  = Join-Path $repDir 'sync.log'
        try {
            $tmpOut = Join-Path $env:TEMP "rep-install-$repId.txt"
            $proc = Start-Process -FilePath $psExe `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installScript,
                                '-InstallDir',$repDir,'-TaskName',$repTask,'-SkipImmediateRun',
                                '-IntervalMinutes',1) `
                -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
                -Wait -PassThru -NoNewWindow
            Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
            Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
            Assert-Equal 0 $proc.ExitCode "1-min install exited $($proc.ExitCode)"

            # Redirect log to sandbox so the production log isn't polluted.
            $cfgPath = Join-Path $repDir 'config.json'
            $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
            $cfg.logPath = $repLog
            $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

            # Wait 150 s. The +1-min trigger fires at ~T+60s, then repetition every 60s
            # should fire at T+120s. So we expect >=2 scheduled (non-manual) runs in 150s.
            Write-Host "    Waiting 150s for scheduled trigger to fire >=2 times..."
            Start-Sleep -Seconds 150

            Assert-True (Test-Path $repLog) "log file not created at $repLog"
            $allLines = Get-Content $repLog
            $starts = @($allLines | Where-Object { $_ -match 'Starting sync \(dryRun=False' })
            if ($starts.Count -lt 2) {
                throw "Expected >=2 scheduled runs in 150s with -IntervalMinutes 1, got $($starts.Count). This is the v1 trigger-Duration bug. Full log:`n$($allLines -join [Environment]::NewLine)"
            }
        } finally {
            try {
                if (Get-ScheduledTask -TaskName $repTask -ErrorAction SilentlyContinue) {
                    Unregister-ScheduledTask -TaskName $repTask -Confirm:$false -ErrorAction SilentlyContinue
                }
            } catch { }
            try {
                if (Test-Path $repDir) { Remove-Item -LiteralPath $repDir -Recurse -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
    }
} finally {
    Invoke-Cleanup
}

exit (Write-TestSummary)
