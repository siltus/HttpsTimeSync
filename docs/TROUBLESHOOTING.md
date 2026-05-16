# Troubleshooting and security

[← Back to README](../README.md)

## Common issues

| Symptom                                                | Diagnosis / fix                                                                                                |
|--------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `Get-ScheduledTask` returns "not found" / `Start-ScheduledTask` returns "Access denied" | **Expected for non-admin users.** The task is registered as SYSTEM with `RunLevel=Highest`; default ACL hides it from non-admins. Manage it via `taskschd.msc` or an elevated PowerShell. Daily-use commands like `Show-Log.ps1` work fine without admin. |
| `LastTaskResult = 0x41301`                             | Task is **currently running** — query again in a few seconds.                                                  |
| `LastTaskResult = 0x41306`                             | Previous run was still going when the next trigger fired. Harmless; increase `-IntervalMinutes` if frequent.   |
| `LastTaskResult = 0x2` (log: "Only 0/1 valid src")     | All HTTPS sources failed. Proxy/captive portal, firewall blocking 443, or your sources are unreachable.        |
| `LastTaskResult = 0x3` (log: "Set-Date failed")        | Task isn't running as SYSTEM (lost admin rights). Re-run `Install.ps1`.                                        |
| Time only ever drifts by ~1 second                     | That's the HTTP `Date` header precision floor. Use real NTP if you need sub-second.                            |
| Clock jumps backwards on every run                     | One source has bad time. Run `Show-Log.ps1`, find the offender, remove it from `config.json`.                  |
| One-liner fails with `Could not establish trust…`      | Outdated TLS roots — `winget upgrade Microsoft.WindowsTerminal` or run Windows Update.                         |
| `irm` fails with `404`                                 | Repo is private or the `-Ref` doesn't exist. Try `-Ref main` explicitly.                                       |
| Install hangs at "Re-launching with UAC prompt"        | UAC dialog is hidden behind another window. Click the taskbar icon or press Win+1.                             |

## Inspect everything in one shot

These work for any user:

```powershell
powershell -File "$env:ProgramData\HttpsTimeSync\Show-Log.ps1" -Lines 100
powershell -File "$env:ProgramData\HttpsTimeSync\Show-Log.ps1" -List
Get-Item C:\ProgramData\HttpsTimeSync\sync.log | Format-List Name, Length, LastWriteTime
```

These require an elevated PowerShell:

```powershell
Get-ScheduledTaskInfo -TaskName HttpsTimeSync | Format-List
Get-ScheduledTask     -TaskName HttpsTimeSync | Format-List
```

## Verify the script is unchanged after install

```powershell
$installed = Get-FileHash "$env:ProgramData\HttpsTimeSync\Sync-HttpsTime.ps1" -Algorithm SHA256
$upstream  = (Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://raw.githubusercontent.com/siltus/HttpsTimeSync/main/Sync-HttpsTime.ps1').Content |
    ForEach-Object { [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($_))).Replace('-','') }
'Installed: ' + $installed.Hash
'Upstream : ' + $upstream
```

(They should match unless you've customized.)

## Security model

- **TLS-verified downloads.** The installer fetches `Sync-HttpsTime.ps1`,
  `Show-Log.ps1`, and `config.default.json` from `raw.githubusercontent.com`
  over HTTPS. The TLS chain is validated by the system trust store.
- **No persistent listener.** The Scheduled Task runs as
  `NT AUTHORITY\SYSTEM`. Its only privileged action is `Set-Date`. No
  network listener, no inbound connections, no persistent file handles
  beyond the log.
- **Source URLs are queried over HTTPS.** `Invoke-WebRequest` validates each
  server's TLS cert. A MITM cannot forge `Date` headers without first
  compromising a CA your machine trusts.
- **No secrets stored or transmitted.** The script never reads credentials,
  tokens, or environment variables beyond `$env:TEMP` and `$env:ProgramData`.
  It transmits nothing other than the four configured HTTPS HEAD requests.
- **Read the code.** All scripts are short and unobfuscated. See the
  [disclaimer in the README](../README.md#%EF%B8%8F-disclaimer--read-before-installing).

## Reporting issues

Open an issue at <https://github.com/siltus/HttpsTimeSync/issues> with:
- Your Windows + PowerShell versions (`$PSVersionTable`)
- The output of `Get-ScheduledTaskInfo -TaskName HttpsTimeSync | Format-List`
- The last 50 lines of `sync.log`
