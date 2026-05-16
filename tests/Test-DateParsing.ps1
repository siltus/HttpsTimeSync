<#
.SYNOPSIS
    Verify ConvertFrom-HttpDate handles every Date header format we expect
    to encounter, plus malformed inputs.
#>
. $PSScriptRoot\_TestHelpers.ps1
. (Join-Path (Get-RepoRoot) 'Sync-HttpsTime.ps1')

Start-TestSuite 'DateParsing'

# Test cases: input, expectedUtcTicks ($null = expect parse failure)
$cases = @(
    @{ in = 'Sat, 16 May 2026 20:13:52 GMT'  ; expect = [DateTime]::new(2026,5,16,20,13,52,[DateTimeKind]::Utc).Ticks ; tag = 'RFC 7231 IMF-fixdate (primary)' },
    @{ in = 'Mon, 01 Jan 2024 00:00:00 GMT'  ; expect = [DateTime]::new(2024,1,1,0,0,0,[DateTimeKind]::Utc).Ticks      ; tag = 'IMF midnight Y-boundary' },
    @{ in = 'Tue, 31 Dec 2030 23:59:59 GMT'  ; expect = [DateTime]::new(2030,12,31,23,59,59,[DateTimeKind]::Utc).Ticks ; tag = 'IMF year-end' },
    @{ in = 'Sun, 06 Nov 1994 08:49:37 GMT'  ; expect = [DateTime]::new(1994,11,6,8,49,37,[DateTimeKind]::Utc).Ticks   ; tag = 'IMF historical' },
    @{ in = ''                                ; expect = $null ; tag = 'empty string' },
    @{ in = '   '                             ; expect = $null ; tag = 'whitespace only' },
    @{ in = 'not a date'                      ; expect = $null ; tag = 'garbage' },
    @{ in = 'Sat, 99 May 2026 20:13:52 GMT'  ; expect = $null ; tag = 'invalid day' },
    @{ in = 'Sat, 16 ZZZ 2026 20:13:52 GMT'  ; expect = $null ; tag = 'invalid month' }
)

foreach ($c in $cases) {
    $name = "parse: $($c.tag) -> $(if ($null -eq $c.expect) { '$null' } else { 'UTC DateTime' })"
    $captured = $c  # capture for closure
    Assert-Test $name {
        $r = ConvertFrom-HttpDate -DateString $captured.in
        if ($null -eq $captured.expect) {
            Assert-True ($null -eq $r) ("expected `$null but got [$r]")
        } else {
            Assert-True ($null -ne $r) ("expected DateTime but got `$null for input [$($captured.in)]")
            Assert-Equal ([DateTimeKind]::Utc) $r.Kind 'Kind must be Utc'
            Assert-Equal $captured.expect $r.Ticks 'Ticks mismatch'
        }
    }
}

# RFC 850 fallback — some legacy servers still emit this.
Assert-Test 'parse: RFC 850 fallback' {
    $r = ConvertFrom-HttpDate -DateString 'Sunday, 06-Nov-94 08:49:37 GMT'
    Assert-True ($null -ne $r) 'RFC 850 should parse via fallback'
    Assert-Equal ([DateTimeKind]::Utc) $r.Kind 'Kind must be Utc after fallback'
}

# Round-trip: format then parse must round-trip
Assert-Test 'round-trip: format then parse preserves UTC' {
    $now = [DateTime]::UtcNow
    $now = [DateTime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, $now.Second, [DateTimeKind]::Utc)
    $s = $now.ToString('r', [System.Globalization.CultureInfo]::InvariantCulture)
    $r = ConvertFrom-HttpDate -DateString $s
    Assert-Equal $now.Ticks $r.Ticks "round-trip failed for [$s]"
}

Assert-Test 'header value coercion: single string passes through' {
    $raw = 'Sat, 16 May 2026 20:13:52 GMT'
    $coerced = [string](@($raw)[0])
    Assert-Equal $raw $coerced 'single string should pass through unchanged'
    $r = ConvertFrom-HttpDate -DateString $coerced
    Assert-True ($null -ne $r) 'coerced single string must parse'
}

Assert-Test 'header value coercion: string array picks first element (PS 7 Invoke-WebRequest behavior)' {
    # PS 7's Invoke-WebRequest returns headers as IEnumerable[string] (per HTTP spec, headers can repeat).
    # The script must extract the first value to feed our [string]-typed parser.
    $raw = [string[]]@('Sat, 16 May 2026 20:13:52 GMT', 'shouldnt see this')
    $coerced = [string](@($raw)[0])
    Assert-Equal 'Sat, 16 May 2026 20:13:52 GMT' $coerced 'array should reduce to first value'
    $r = ConvertFrom-HttpDate -DateString $coerced
    Assert-True ($null -ne $r) 'coerced array-first must parse'
}

Assert-Test 'header value coercion: List[string] (Dictionary-typed PS 7 result)' {
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add('Sat, 16 May 2026 20:13:52 GMT')
    $coerced = [string](@($list)[0])
    Assert-Equal 'Sat, 16 May 2026 20:13:52 GMT' $coerced 'List<string> should reduce to first value'
}

exit (Write-TestSummary)
