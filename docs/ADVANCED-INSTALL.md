# Advanced install

[← Back to README](../README.md)

The one-liner is the easy path. For everything else:

## Clone and run locally

```powershell
git clone https://github.com/siltus/HttpsTimeSync.git
cd HttpsTimeSync
.\Install.ps1 -IntervalMinutes 30 -InstallDir 'D:\Tools\HttpsTimeSync'
```

When `Install.ps1` is invoked from a cloned repo, it uses the files in the
clone instead of downloading from raw.githubusercontent.com.

## Re-installing

Just re-run the one-liner. Every install:
- Overwrites the scripts with the latest from `main`.
- **Overwrites `config.json` from `config.default.json`** — install means install. Customize `config.json` AFTER installing; don't re-run install if you want to keep edits.
- Re-registers the Scheduled Task with the latest trigger / settings.

## All installer parameters

| Parameter           | Default                          | Meaning                                                  |
|---------------------|----------------------------------|----------------------------------------------------------|
| `-IntervalMinutes`  | `15`                             | Scheduled task interval.                                 |
| `-InstallDir`       | `%ProgramData%\HttpsTimeSync`    | Where scripts are copied to.                             |
| `-TaskName`         | `HttpsTimeSync`                  | Scheduled Task name (override for parallel installs).    |
| `-Ref`              | `main`                           | Git ref to download from (one-liner mode).               |
| `-Repo`             | `siltus/HttpsTimeSync`           | GitHub repo (owner/name).                                |
| `-SkipImmediateRun` | off                              | Skip the post-install kick-off sync.                     |

## Pin the one-liner to a specific commit or tag

```powershell
$env:HTTPSTIMESYNC_REF = 'v1.0.0'   # or a 40-char commit SHA
iex (irm "https://raw.githubusercontent.com/siltus/HttpsTimeSync/$env:HTTPSTIMESYNC_REF/Install.ps1")
```

Useful if you want deterministic deployments across machines and don't want
to track `main`.

## Run multiple parallel installs

Different intervals, different log paths, different sources — all on the same machine:

```powershell
# "Fast" sync — every 5 min, separate task and dir
.\Install.ps1 -IntervalMinutes 5 -TaskName HttpsTimeSync-Fast `
              -InstallDir 'C:\ProgramData\HttpsTimeSync-Fast'

# "Slow" sync — every hour, separate task and dir
.\Install.ps1 -IntervalMinutes 60 -TaskName HttpsTimeSync-Slow `
              -InstallDir 'C:\ProgramData\HttpsTimeSync-Slow'
```

Uninstall each with matching args:

```powershell
.\Uninstall.ps1 -TaskName HttpsTimeSync-Fast -InstallDir 'C:\ProgramData\HttpsTimeSync-Fast'
```

## Uninstall options

| Parameter           | Default                          | Meaning                                                  |
|---------------------|----------------------------------|----------------------------------------------------------|
| `-InstallDir`       | `%ProgramData%\HttpsTimeSync`    | Where scripts were installed.                            |
| `-TaskName`         | `HttpsTimeSync`                  | Scheduled Task to remove.                                |
| `-KeepFiles`        | off                              | Keep log + config; remove only the Scheduled Task.       |
