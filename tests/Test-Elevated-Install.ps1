<#
.SYNOPSIS
    REAL admin-privileged round-trip: invoke Install.ps1 against a sandbox
    install dir and unique task name, verify state, then Uninstall.ps1
    and verify clean removal.

    Requires Administrator. Run via Run-Tests.ps1 -IncludeElevated.

    Sandbox isolation:
      - InstallDir : %TEMP%\HttpsTimeSync-Test-<guid>
      - TaskName   : HttpsTimeSync-Test-<guid>

    A pre-existing production install (TaskName=HttpsTimeSync, dir=
    ProgramData\HttpsTimeSync) is NEVER touched.
#>
. $PSScriptRoot\_TestHelpers.ps1
Start-TestSuite 'ElevatedInstall'

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

# Unique sandbox identifiers — guaranteed not to collide with a real install.
$sandboxId   = [guid]::NewGuid().Guid.Substring(0,8)
$sandboxDir  = Join-Path $env:TEMP "HttpsTimeSync-Test-$sandboxId"
$sandboxTask = "HttpsTimeSync-Test-$sandboxId"

Write-Host "  Sandbox dir  : $sandboxDir"
Write-Host "  Sandbox task : $sandboxTask"

# Always cleanup, even on test failure or interruption.
function Invoke-Cleanup {
    param([string]$Dir, [string]$Task)
    try {
        if (Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        if (Test-Path $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# Sanity: nothing must pre-exist with these names.
Assert-Test 'sandbox identifiers do not already exist' {
    Assert-True (-not (Test-Path $sandboxDir)) "sandbox dir already exists"
    Assert-True ($null -eq (Get-ScheduledTask -TaskName $sandboxTask -ErrorAction SilentlyContinue)) `
        "sandbox task already exists"
}

try {
    # --- INSTALL ---
    Assert-Test 'Install.ps1 (real admin invocation) completes with exit 0' {
        $tmpOut = Join-Path $env:TEMP "elinst-$sandboxId.txt"
        try {
            $proc = Start-Process -FilePath $psExe `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installScript,
                                '-InstallDir',$sandboxDir,'-TaskName',$sandboxTask,'-SkipImmediateRun') `
                -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
                -Wait -PassThru -NoNewWindow

            $stdout = ''; if (Test-Path $tmpOut)       { $c = Get-Content -Raw $tmpOut;       if ($c) { $stdout = $c } }
            $stderr = ''; if (Test-Path "$tmpOut.err") { $c = Get-Content -Raw "$tmpOut.err"; if ($c) { $stderr = $c } }

            if ($proc.ExitCode -ne 0) {
                throw "Install exited with code $($proc.ExitCode).`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
            }
            Assert-Match $stdout 'Registered task' 'install output should mention task registration'
        } finally {
            Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
            Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Test 'all 4 files were copied to InstallDir' {
        foreach ($f in 'Sync-HttpsTime.ps1','config.default.json','config.json','Show-Log.ps1') {
            $p = Join-Path $sandboxDir $f
            Assert-True (Test-Path $p) "missing: $f"
        }
    }

    Assert-Test 'config.json is valid JSON with required keys' {
        $cfg = Get-Content -Raw (Join-Path $sandboxDir 'config.json') | ConvertFrom-Json
        Assert-True ($cfg.sources.Count -ge 2) 'should have at least 2 sources'
        Assert-True ($cfg.thresholdMs -gt 0)   'thresholdMs must be positive'
        Assert-True ($cfg.logMaxBytes -gt 0)   'logMaxBytes must be positive'
    }

    Assert-Test 'Scheduled Task registered with correct principal=SYSTEM and RunLevel=Highest' {
        $task = Get-ScheduledTask -TaskName $sandboxTask -ErrorAction Stop
        # Windows normalizes UserId to either 'SYSTEM' or 'NT AUTHORITY\SYSTEM' depending
        # on PS version / API surface. Match either.
        Assert-Match $task.Principal.UserId 'SYSTEM' 'task UserId must include SYSTEM'
        Assert-Equal 'Highest' $task.Principal.RunLevel 'task must have Highest RunLevel'
        Assert-True ($task.Actions.Count -ge 1) 'task must have at least one action'
        $action = $task.Actions[0]
        Assert-Match $action.Execute 'powershell.exe' 'action should invoke powershell.exe'
        Assert-Match $action.Arguments ([regex]::Escape($sandboxDir)) 'action should reference sandbox dir'
    }

    Assert-Test 'Scheduled Task has repetition that will continue for years' {
        $task = Get-ScheduledTask -TaskName $sandboxTask -ErrorAction Stop
        Assert-True ($task.Triggers.Count -ge 1) 'task must have at least one trigger'
        $rep = $task.Triggers[0].Repetition
        Assert-True ($null -ne $rep) 'trigger must have repetition'
        Assert-Equal 'PT15M' $rep.Interval 'default repetition interval should be 15 minutes'
        # v1 bug catch: empty Duration on Windows 10/11 made the trigger fire only
        # once. Fix requires an explicit Duration (capped at 4-digit days by the XSD).
        Assert-True (-not [string]::IsNullOrEmpty($rep.Duration)) `
            "Duration must be non-empty - empty Duration causes the v1 trigger-fires-once bug on Windows 10/11"
        Assert-Match $rep.Duration '^P\d{2,4}D' "Duration should be in days form (2-4 digit P-N-D pattern)"
    }

    # --- UNINSTALL ---
    Assert-Test 'Uninstall.ps1 (real admin invocation) completes with exit 0' {
        $tmpOut = Join-Path $env:TEMP "eluninst-$sandboxId.txt"
        try {
            $proc = Start-Process -FilePath $psExe `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$uninstScript,
                                '-InstallDir',$sandboxDir,'-TaskName',$sandboxTask) `
                -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err" `
                -Wait -PassThru -NoNewWindow

            $stdout = ''; if (Test-Path $tmpOut)       { $c = Get-Content -Raw $tmpOut;       if ($c) { $stdout = $c } }
            $stderr = ''; if (Test-Path "$tmpOut.err") { $c = Get-Content -Raw "$tmpOut.err"; if ($c) { $stderr = $c } }

            if ($proc.ExitCode -ne 0) {
                throw "Uninstall exited with code $($proc.ExitCode).`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
            }
            Assert-Match $stdout 'Removed Scheduled Task' 'uninstall should report task removal'
        } finally {
            Remove-Item $tmpOut       -Force -ErrorAction SilentlyContinue
            Remove-Item "$tmpOut.err" -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Test 'Scheduled Task is gone after uninstall' {
        Assert-True ($null -eq (Get-ScheduledTask -TaskName $sandboxTask -ErrorAction SilentlyContinue)) `
            "task '$sandboxTask' still exists after uninstall"
    }

    Assert-Test 'install dir is gone after uninstall' {
        Assert-True (-not (Test-Path $sandboxDir)) "install dir still exists after uninstall"
    }

    # --- UPDATE-MODE tests ---
    # Re-installing on an existing install should: overwrite scripts AND config.json
    # (KISS: install means install, no preserve-customizations flag).
    $updId   = [guid]::NewGuid().Guid.Substring(0,8)
    $updDir  = Join-Path $env:TEMP "HttpsTimeSync-Upd-$updId"
    $updTask = "HttpsTimeSync-Upd-$updId"
    try {
        # First install (fresh).
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installScript,
                            '-InstallDir',$updDir,'-TaskName',$updTask,'-SkipImmediateRun') `
            -Wait -PassThru -NoNewWindow
        Assert-Test 'pre-update fresh install succeeds' {
            Assert-Equal 0 $proc.ExitCode "fresh install exited $($proc.ExitCode)"
        }

        # Customize config.json (change thresholdMs to something distinctive).
        $cfgUser = Join-Path $updDir 'config.json'
        $cfg = Get-Content -Raw $cfgUser | ConvertFrom-Json
        $cfg.thresholdMs = 999
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgUser -Encoding UTF8

        # Second install on same dir/task — should ALWAYS overwrite config.json.
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installScript,
                            '-InstallDir',$updDir,'-TaskName',$updTask,'-SkipImmediateRun') `
            -Wait -PassThru -NoNewWindow

        Assert-Test 're-install overwrites config.json (no preserve flag)' {
            Assert-Equal 0 $proc.ExitCode "re-install exited $($proc.ExitCode)"
            $cfgAfter = Get-Content -Raw $cfgUser | ConvertFrom-Json
            Assert-Equal 250 $cfgAfter.thresholdMs 're-install must reset thresholdMs to default (250)'
        }

        Assert-Test 're-install leaves task registered' {
            $task = Get-ScheduledTask -TaskName $updTask -ErrorAction Stop
            Assert-True ($null -ne $task) 'task must still exist after re-install'
        }
    } finally {
        Invoke-Cleanup -Dir $updDir -Task $updTask
    }
} finally {
    # Belt-and-suspenders cleanup.
    Invoke-Cleanup -Dir $sandboxDir -Task $sandboxTask
}

exit (Write-TestSummary)
