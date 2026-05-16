# How HttpsTimeSync works

[← Back to README](../README.md)

## The algorithm

For each configured HTTPS source the script:

1. Starts a high-resolution stopwatch, records local UTC.
2. Issues a `HEAD` request (falls back to `GET` if the CDN rejects HEAD).
3. Stops the stopwatch → measured **round-trip time (RTT)**.
4. Parses the response's `Date:` header (RFC 7231 IMF-fixdate, e.g.
   `Sat, 16 May 2026 18:00:00 GMT`).
5. Computes per-source offset using the standard NTP-style symmetric-delay
   assumption:

   ```
   offset = serverDate − (localStart + RTT/2)
   ```

After all sources are queried it:

- **Drops** sources that failed or whose RTT exceeded `maxRttSec`.
- **Refuses to act** if fewer than `minValidSources` survived (default 2 — guards against one bad CDN or captive-portal poisoning).
- Computes the **median** offset across surviving sources.
- If `|median| < thresholdMs` (default 250 ms): logs "in sync", does nothing.
- Otherwise: calls `Set-Date -Adjust <TimeSpan>` to step the clock.

## Accuracy ceiling: ~0.5 seconds

The HTTP `Date` header has 1-second precision. This approach can never beat
that. If you can use real NTP, do — HttpsTimeSync exists for networks that
block UDP/123.

## Why median, not mean?

A single bad source (captive portal, CDN with wrong clock, MITM) can shift
the mean arbitrarily far. The median ignores such outliers as long as fewer
than half of the surviving sources are bad.

## Why a per-source RTT cap?

When RTT is large (>5 s by default), the symmetric-delay assumption is
unreliable — the request and response paths might have very different
latencies. Dropping high-RTT samples improves the median's accuracy.

## Why a drift threshold?

Without a threshold the script would adjust the clock by a few ms on every
run, generating noise. The 250 ms default keeps the clock stable while still
catching real drift quickly.

## Trigger schedule

After `Install.ps1` completes, the registered task fires:

1. **Immediately** — one sync triggered by `Install.ps1`'s post-install kick-off (so you see results during install).
2. **+1 minute** — the registered `Once` trigger fires for the first time.
3. **Every 15 minutes** thereafter (or whatever `-IntervalMinutes` you passed).

The task runs as `NT AUTHORITY\SYSTEM` with `RunLevel=Highest`, so it can call
`Set-Date` and write to `C:\ProgramData\HttpsTimeSync\` regardless of which
user is logged in (or no one is). With default Windows ACLs this also means
non-admin users can't query or trigger the task — see
[Validation §non-admin](VALIDATION.md#non-admin-verification-no-uac) for
user-level checks.

## What the script does NOT do

- It does not act as an NTP server.
- It does not store credentials or tokens of any kind.
- It does not phone home — every HTTP request goes to a URL you configured.
- It does not change time zones, DST, or system locale.
