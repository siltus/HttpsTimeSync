# Testing

[← Back to README](../README.md)

A test suite lives in [`tests/`](../tests). Pure PowerShell, no external
dependencies (no Pester, no modules). Run from the repo root.

## Quick reference

```powershell
.\tests\Run-Tests.ps1                          # default suites, no UAC, no admin
.\tests\Run-Tests.ps1 -Filter Rotation         # one suite
.\tests\Run-Tests.ps1 -PowerShellPath 'C:\Program Files\PowerShell\7\pwsh.exe'   # PS 7
.\tests\Run-Tests.ps1 -IncludeElevated         # all suites incl. real-admin privileged path
```

Each suite runs in a fresh child shell. The runner exits non-zero on any failure.

## Default suites (no admin, no UAC)

| Suite                | Tests | Covers |
|----------------------|-------|--------|
| `Test-DateParsing`   | 14    | `ConvertFrom-HttpDate` — IMF-fixdate, RFC 850, garbage, header coercion (PS 5.1 string vs PS 7 string[]) |
| `Test-Rotation`      | 5     | `Invoke-LogRotationIfNeeded` — no-op cases, content preservation, retention |
| `Test-FormatStrings` | 47    | Every log-line format string with positive/negative/zero/huge deltas |
| `Test-PropertyAccess`| 3     | The `$MyInvocation.MyCommand.Path` strict-mode pattern (the bug behind the original "no UAC" failure) |
| `Test-InstallIex`    | 4     | `Install.ps1` + `Uninstall.ps1` invoked via `[scriptblock]::Create` (mimics `irm \| iex`). Self-skips when runner is admin (the non-admin elevation path can't be exercised from an admin context) |
| `Test-EndToEnd`      | 4     | Full `Sync-HttpsTime.ps1 -DryRun` on PS 5.1 and PS 7 against live HTTPS sources |

Total: **77 tests** in the default mode. Typical runtime ~40 s.

## Elevated suites (`-IncludeElevated`, one UAC prompt up front)

These exercise the REAL privileged path against isolated sandbox install
dirs (`%TEMP%\HttpsTimeSync-Test-<guid>`) and unique task names
(`HttpsTimeSync-Test-<guid>`), so a pre-existing production install is
never touched.

| Suite                     | Tests | Covers |
|---------------------------|-------|--------|
| `Test-Elevated-Install`   | 9     | Real `Install.ps1`: assert files staged, `config.json` created, Scheduled Task registered as SYSTEM with correct trigger. Then real `Uninstall.ps1`: assert task gone, dir gone. |
| `Test-Elevated-Scheduled` | 6     | Replace the install-registered trigger with a far-future one (eliminates race), trigger task manually, wait, assert `LastTaskResult=0`, log written by SYSTEM with expected content, second trigger still succeeds. |
| `Test-Elevated-SetDate`   | 3     | `Set-Date` actually shifts the wall clock by ±50 ms (with `try/finally` restore). Verifies no Group Policy / AV is blocking time changes. |

Total: **92 tests** in elevated mode. Typical runtime ~90 s.

When `-IncludeElevated` is set and the runner is not already admin, it
self-elevates with a single UAC prompt; the elevated child then runs all
suites (default + elevated). Default invocations never trigger UAC.

## What the tests prove

- The parser handles every Date header format we expect (and some we don't).
- The rotation preserves content, compresses, and retains the right count.
- The format strings don't throw at any input.
- The strict-mode property-access pattern works in both `iex` and `-File`
  invocation modes (regression test for the `Path cannot be found` bug).
- The full Install → SYSTEM Scheduled Task → real sync → log file chain
  works end-to-end on the host machine.
- `Set-Date` is callable in this environment (not blocked by GPO or AV).

## Adding a new test

1. Create `tests/Test-MyThing.ps1`.
2. Dot-source `_TestHelpers.ps1` at the top.
3. Call `Start-TestSuite 'MyThing'`.
4. Use `Assert-Test 'name' { ...; Assert-Equal $expected $actual }` for each case.
5. End with `exit (Write-TestSummary)`.

The runner auto-discovers it on the next run. If the test requires admin,
name it `Test-Elevated-MyThing.ps1` and start with the admin check that the
other Elevated tests use.
