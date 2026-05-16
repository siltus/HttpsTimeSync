# Logs

[← Back to README](../README.md)

## Where they live

`C:\ProgramData\HttpsTimeSync\sync.log` (overridable via `config.json`'s `logPath`).

## Easy access via `Show-Log.ps1`

A small helper installed alongside the sync script:

```powershell
$tool = "$env:ProgramData\HttpsTimeSync\Show-Log.ps1"

powershell -File $tool                # last 50 lines
powershell -File $tool -Lines 200     # last 200 lines
powershell -File $tool -Follow        # live tail (Ctrl+C to stop)
powershell -File $tool -List          # list rotated zip archives
powershell -File $tool -Open          # open install folder in Explorer
```

The helper reads `config.json` to find the log path, so it works even if you
customized `logPath`.

## Rotation (zip archives, retention)

When `sync.log` grows past **`logMaxBytes`** (default **1 MiB**) the script:

1. Renames it to `sync.<UTC-timestamp>.log`, e.g. `sync.20260516T210012Z.log`.
2. Compresses it to `sync.<UTC-timestamp>.log.zip` (typically ~85–90% size reduction).
3. Deletes the un-zipped copy.
4. Trims oldest zips so at most **`logKeepRotated`** (default **10**) remain.

Worst-case disk usage: `logMaxBytes × (logKeepRotated + 1)` ≈ **11 MiB** with defaults.

List current archives:

```powershell
powershell -File "$env:ProgramData\HttpsTimeSync\Show-Log.ps1" -List
```

## Reading an archived log

Without extracting (read first entry from a zip directly):

```powershell
$zip = "$env:ProgramData\HttpsTimeSync\sync.20260516T210012Z.log.zip"
[IO.Compression.ZipFile]::OpenRead($zip).Entries[0].Open() |
    ForEach-Object { (New-Object IO.StreamReader $_).ReadToEnd() }
```

Or extract to a temp dir:

```powershell
Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
notepad "$env:TEMP\sync.20260516T210012Z.log"
```

## Line format

```
2026-05-16T21:00:12.345+03:00 [INFO] Starting sync (dryRun=False, sources=4)
^ ISO 8601 local timestamp     ^level ^ message
```

Levels in use: `INFO`, `WARN`, `ERROR`.
