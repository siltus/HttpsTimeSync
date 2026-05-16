# Configuration

[← Back to README](../README.md)

Edit `C:\ProgramData\HttpsTimeSync\config.json`. Changes take effect on the
next scheduled run — no need to re-register the task.

> ⚠️ **Re-running `Install.ps1` overwrites `config.json`** from
> `config.default.json`. Customize *after* installing. If you want to keep
> custom settings, edit `config.json` once and don't re-run the installer.

## Defaults

```json
{
  "sources": [
    "https://www.apple.com",
    "https://www.amazon.com",
    "https://cdnjs.cloudflare.com",
    "https://www.microsoft.com",
    "https://speed.cloudflare.com",
    "https://www.google.com",
    "https://www.cloudflare.com"
  ],
  "timeoutSec": 5,
  "maxRttSec": 5,
  "minValidSources": 2,
  "thresholdMs": 250,
  "logPath": "C:\\ProgramData\\HttpsTimeSync\\sync.log",
  "logMaxBytes": 1048576,
  "logKeepRotated": 10
}
```

The 7 default sources are picked for **low latency, geographic diversity, and operator
independence**. Measurements from Israel (typical):

| Source | Why it's there |
|---|---|
| `www.apple.com` | Akamai-fronted, tier-1, ~65 ms |
| `www.amazon.com` | Amazon CloudFront, tier-1, ~70 ms |
| `cdnjs.cloudflare.com` | Cloudflare CDN edge (cdnjs serves JS libraries for millions of sites), ~85 ms |
| `www.microsoft.com` | Microsoft's own edge, ~90 ms |
| `speed.cloudflare.com` | Cloudflare's purpose-built speed-test endpoint, ~110 ms |
| `www.google.com` | Google operator independence, ~300 ms |
| `www.cloudflare.com` | Cloudflare marketing site (slower but independent of cdnjs/speed POPs), ~500 ms |

`github.com` was tried and removed: its `Date:` header is consistently 7–11 seconds behind reality (likely served from a cache layer not designed for accurate clock probes). The median was dropping it correctly but it was wasting a source slot.

The median across all 7 is robust against any 1–2 being slow, returning bogus data,
or being briefly unreachable.

## Keys

| Key               | Default                          | Meaning                                                                       |
|-------------------|----------------------------------|-------------------------------------------------------------------------------|
| `sources`         | google/cloudflare/microsoft/apple | HTTPS URLs to query. More = more robust, but slower.                          |
| `timeoutSec`      | `5`                              | Per-request timeout.                                                          |
| `maxRttSec`       | `5`                              | Drop samples slower than this (high RTT = noisy time estimate).               |
| `minValidSources` | `2`                              | Refuse to act if fewer sources returned good samples.                         |
| `thresholdMs`     | `250`                            | Don't touch the clock if drift is below this (avoids constant micro-adjusts). |
| `logPath`         | `…\sync.log`                     | Where to append run logs. The dir must be writable by SYSTEM.                |
| `logMaxBytes`     | `1048576` (1 MiB)                | Rotate when the active log exceeds this size.                                 |
| `logKeepRotated`  | `10`                             | How many rotated `.log.zip` files to keep.                                    |

## Tuning notes

- **Add more sources** to reduce the impact of any single misbehaving CDN.
  Aim for at least 3 unrelated operators (Google, Cloudflare, Apple,
  Microsoft, GitHub, Amazon, etc).
- **Lower `thresholdMs`** if you want tighter sync — but be aware the floor
  is ~250 ms because the HTTP `Date` header has 1-second precision.
- **Raise `timeoutSec`** if you're on a slow connection and sources are
  being dropped due to timeouts.
- **Raise `logKeepRotated`** if you want longer log retention — disk impact
  is `logMaxBytes × (logKeepRotated + 1)`.

## Picking your own sources

If you want to swap or extend the defaults:

- **Prefer tier-1 operators** (Google, Cloudflare, Microsoft, Apple, Amazon, GitHub, Akamai).
  They have global anycast networks, so the request resolves to a nearby POP automatically.
- **Prefer purpose-built probe endpoints** like `speed.cloudflare.com`, `cdnjs.cloudflare.com`,
  `captive.apple.com`. They're designed for lightweight requests and have tiny TLS handshakes.
- **Avoid news/portal sites** (even if locally fast). They redirect through tracking layers,
  change CDN providers, and sometimes block automated requests.
- **Verify the source actually returns a `Date:` header** before adding:

  ```powershell
  (Invoke-WebRequest -Uri 'https://your.candidate' -Method Head -UseBasicParsing).Headers.Date
  ```

- After editing `config.json`, the next scheduled run picks up the new list automatically — no reinstall needed.

## Pointing the log somewhere else

If you'd rather log to a different location:

```json
"logPath": "D:\\Logs\\HttpsTimeSync\\sync.log"
```

The directory will be auto-created on the next run if it doesn't exist. The
SYSTEM account must have write access to the chosen path.
