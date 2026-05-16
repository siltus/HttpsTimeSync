# Validating the install

[← Back to README](../README.md)

> **Heads-up:** the Scheduled Task is registered as
> `NT AUTHORITY\SYSTEM` with `RunLevel=Highest`. With default ACLs, querying
> or triggering it requires **Administrator**. As a regular user, you can
> still verify the install via the log file and the `Show-Log.ps1` helper —
> see [Non-admin verification](#non-admin-verification-no-uac) below.

## Trigger schedule (so you know what to expect)

After `Install.ps1` completes, the task will fire:

1. **Immediately** — one sync triggered by `Install.ps1`'s post-install kick-off.
2. **+1 minute** — the registered `Once` trigger fires.
3. Then **every 15 minutes** thereafter (or whatever `-IntervalMinutes` you passed).

So within 1–2 minutes of install you should see two log entries.

---

## Non-admin verification (no UAC)

These commands work as a regular user.

### 1. Log file exists and shows recent syncs

```powershell
powershell -File "$env:ProgramData\HttpsTimeSync\Show-Log.ps1"
```

Healthy output:

```
2026-05-16T21:00:12.345+03:00 [INFO] Starting sync (dryRun=False, sources=4)
2026-05-16T21:00:12.567+03:00 [INFO]   https://www.google.com           rtt=  118.3ms delta=    -42.1ms
2026-05-16T21:00:12.733+03:00 [INFO]   https://www.cloudflare.com       rtt=   95.2ms delta=    -39.8ms
2026-05-16T21:00:12.901+03:00 [INFO]   https://www.microsoft.com        rtt=  142.6ms delta=    -45.2ms
2026-05-16T21:00:13.087+03:00 [INFO]   https://www.apple.com            rtt=  109.4ms delta=    -41.5ms
2026-05-16T21:00:13.088+03:00 [INFO] Median drift across 4 sources: -41.8 ms (threshold 250 ms)
2026-05-16T21:00:13.089+03:00 [INFO] Within threshold; no clock change.
```

### 2. Log timestamp is recent

```powershell
Get-Item C:\ProgramData\HttpsTimeSync\sync.log |
    Select-Object Name, Length, LastWriteTime
```

`LastWriteTime` should be within the last ~15 minutes (one interval).

### 3. Standalone dry-run probe (no system changes)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
    -File "$env:ProgramData\HttpsTimeSync\Sync-HttpsTime.ps1" -DryRun
```

Prints the live drift to console without touching the clock. Useful to test
connectivity or to see "if a sync ran right now, what would it do?".

### 4. Proof-of-life: the log file is SYSTEM-owned

```powershell
(Get-Acl C:\ProgramData\HttpsTimeSync\sync.log).Owner
```

Should print `NT AUTHORITY\SYSTEM`. If you (a non-admin user) cannot write to
the file but it keeps growing, that's proof the SYSTEM-owned task is the one
appending to it. Confirm you cannot write:

```powershell
Add-Content C:\ProgramData\HttpsTimeSync\sync.log 'test' -ErrorAction SilentlyContinue
# (should silently fail / show "Access denied")
```

---

## Admin verification (one UAC)

For the canonical task-status query, open **PowerShell as Administrator** and run:

```powershell
Get-ScheduledTaskInfo -TaskName HttpsTimeSync |
    Select-Object LastRunTime, NextRunTime, LastTaskResult, NumberOfMissedRuns
```

Healthy output:

```
LastRunTime          NextRunTime          LastTaskResult  NumberOfMissedRuns
-----------          -----------          --------------  ------------------
5/16/2026 9:00:12 PM 5/16/2026 9:15:12 PM              0                   0
```

`LastTaskResult` codes:

| Code         | Meaning |
|--------------|---------|
| `0`          | Last run succeeded. |
| `0x41301`    | Task is **currently running** — query again in a few seconds. |
| `0x41306`    | Previous run was still going when the next trigger fired (collision). Harmless if rare. |
| `0x2`        | Sync exited 2 (fewer than `minValidSources` succeeded). See log. |
| `0x3`        | Sync exited 3 (Set-Date failed). See log. |

Trigger a sync immediately (admin only):

```powershell
Start-ScheduledTask -TaskName HttpsTimeSync
```

Or use the GUI:

```powershell
taskschd.msc        # navigate to Task Scheduler Library -> HttpsTimeSync
```

---

## What "first sync" looks like if your clock is off

If your clock is drifted by more than the threshold (250 ms), the first sync
will report a large `Median drift` and step the clock to correct it:

```
[INFO] Median drift across 4 sources: +163249.6 ms (threshold 250 ms)
[INFO] Clock adjusted by +163249.6 ms. New local time: 2026-05-16T22:53:01...
```

Subsequent syncs should then stay within threshold and just log
`Within threshold; no clock change.`
