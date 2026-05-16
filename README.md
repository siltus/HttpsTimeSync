# HttpsTimeSync

Sync the Windows system clock over HTTPS (port 443), for networks where NTP
(UDP/123) is blocked. Pure PowerShell, installs as a SYSTEM Scheduled Task.

---

> ## ⚠️ DISCLAIMER — READ BEFORE INSTALLING
>
> **This software was written by a large language model** (Claude, via the
> GitHub Copilot CLI), in collaboration with a human reviewer. It has automated
> tests but has not undergone formal security review.
>
> **Read the code before running it on your system.** All scripts are short
> and unobfuscated:
>
> - [`Install.ps1`](Install.ps1) — what the installer does (self-elevates, copies files, registers a SYSTEM Scheduled Task)
> - [`Sync-HttpsTime.ps1`](Sync-HttpsTime.ps1) — what runs every 15 minutes as SYSTEM (queries HTTPS, may call `Set-Date`)
> - [`Uninstall.ps1`](Uninstall.ps1) — how removal works
> - [`Show-Log.ps1`](Show-Log.ps1) — log viewer (non-privileged)
>
> The installer **modifies your system clock** and registers a Scheduled Task
> running as `NT AUTHORITY\SYSTEM`. By installing this software you accept
> that **you alone are responsible** for what runs on your machine — neither
> the author nor the LLM that wrote it provides any warranty or accepts any
> liability for damage, data loss, or other incidents resulting from its
> installation or use.

---

## Quick start

Open **PowerShell** (regular, not "as admin" — the installer self-elevates with a single UAC prompt):

```powershell
iex (irm https://raw.githubusercontent.com/siltus/HttpsTimeSync/main/Install.ps1)
```

Total time: ~5 seconds. One UAC click. Then it runs forever in the background.

To remove:

```powershell
iex (irm https://raw.githubusercontent.com/siltus/HttpsTimeSync/main/Uninstall.ps1)
```

## Documentation

| Doc | Read it if you want to… |
|---|---|
| [How it works](docs/HOW-IT-WORKS.md) | Understand the algorithm and its ~0.5 s accuracy ceiling |
| [Validate the install](docs/VALIDATION.md) | Confirm the task is registered and syncing correctly |
| [Configuration](docs/CONFIGURATION.md) | Tune sources, threshold, log size — `config.json` reference |
| [Logs](docs/LOGS.md) | Find logs, tail them, work with the zip-rotated archives |
| [Advanced install](docs/ADVANCED-INSTALL.md) | Custom interval, install dir, pin to a commit, clone-and-run |
| [Troubleshooting & security](docs/TROUBLESHOOTING.md) | Common errors, security model |
| [Testing](docs/TESTING.md) | Run the test suite (default and elevated modes) |

## License

[MIT](LICENSE).
