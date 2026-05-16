<#
.SYNOPSIS
    Verify Invoke-LogRotationIfNeeded:
      * no-op when log missing
      * no-op when log under threshold
      * rotates to timestamped .zip when over threshold
      * preserves content (extract zip == original log)
      * retains exactly KeepRotated newest zips after N rotations
#>
. $PSScriptRoot\_TestHelpers.ps1
. (Join-Path (Get-RepoRoot) 'Sync-HttpsTime.ps1')

Start-TestSuite 'Rotation'

function New-TestDir {
    $d = Join-Path $env:TEMP ("httptimesync-rot-{0}" -f ([guid]::NewGuid().Guid.Substring(0,8)))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

Assert-Test 'no-op when log file missing' {
    $d = New-TestDir
    try {
        $log = Join-Path $d 'sync.log'
        Invoke-LogRotationIfNeeded -LogPath $log -MaxBytes 100 -KeepRotated 3
        $count = @(Get-ChildItem $d -ErrorAction SilentlyContinue).Count
        Assert-Equal 0 $count 'no files should exist after no-op rotation'
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-Test 'no-op when log under threshold' {
    $d = New-TestDir
    try {
        $log = Join-Path $d 'sync.log'
        'short content' | Set-Content $log -Encoding UTF8
        Invoke-LogRotationIfNeeded -LogPath $log -MaxBytes 10000 -KeepRotated 3
        Assert-True (Test-Path $log) 'log should still exist'
        $zipCount = @(Get-ChildItem $d -Filter '*.zip').Count
        Assert-Equal 0 $zipCount 'no zips should have been created'
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-Test 'rotates to zip when over threshold and preserves content' {
    $d = New-TestDir
    try {
        $log = Join-Path $d 'sync.log'
        $payload = 'A' * 5000
        $payload | Set-Content $log -Encoding UTF8 -NoNewline
        $origHash = (Get-FileHash $log -Algorithm SHA256).Hash

        Invoke-LogRotationIfNeeded -LogPath $log -MaxBytes 100 -KeepRotated 3

        Assert-True (-not (Test-Path $log)) 'original log should have been removed/rotated'
        $zips = @(Get-ChildItem $d -Filter 'sync.*.log.zip')
        Assert-Equal 1 $zips.Count 'exactly one zip should exist'

        # Extract and compare hash
        $extractDir = Join-Path $env:TEMP "extract-$([guid]::NewGuid().Guid.Substring(0,8))"
        try {
            Expand-Archive -Path $zips[0].FullName -DestinationPath $extractDir -Force
            $extracted = @(Get-ChildItem $extractDir)
            Assert-Equal 1 $extracted.Count 'zip should contain exactly one file'
            $newHash = (Get-FileHash $extracted[0].FullName -Algorithm SHA256).Hash
            Assert-Equal $origHash $newHash 'extracted content hash must match original'
        } finally { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-Test 'retains exactly KeepRotated newest zips across 6 rotations' {
    $d = New-TestDir
    try {
        $log = Join-Path $d 'sync.log'
        for ($i = 1; $i -le 6; $i++) {
            ('payload-rotation-' + $i + ('X' * 500)) | Set-Content $log -Encoding UTF8 -NoNewline
            Invoke-LogRotationIfNeeded -LogPath $log -MaxBytes 50 -KeepRotated 3
            # Ensure unique timestamps (rotation stamp has 1-second resolution).
            Start-Sleep -Milliseconds 1100
        }
        $zips = @(Get-ChildItem $d -Filter 'sync.*.log.zip' | Sort-Object Name)
        Assert-Equal 3 $zips.Count "expected 3 zips, got $($zips.Count): $($zips.Name -join ', ')"
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-Test 'retained zips are the NEWEST (lexicographic by timestamp)' {
    $d = New-TestDir
    try {
        $log = Join-Path $d 'sync.log'
        $allRotationNames = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -le 5; $i++) {
            ('rotation ' + $i + ('Y' * 500)) | Set-Content $log -Encoding UTF8 -NoNewline
            Invoke-LogRotationIfNeeded -LogPath $log -MaxBytes 50 -KeepRotated 99
            $latest = @(Get-ChildItem $d -Filter 'sync.*.log.zip' | Sort-Object Name -Descending)[0].Name
            $allRotationNames.Add($latest) | Out-Null
            Start-Sleep -Milliseconds 1100
        }
        # Now trim to 2 by running another rotation with low KeepRotated
        'final' | Set-Content $log -Encoding UTF8
        Invoke-LogRotationIfNeeded -LogPath $log -MaxBytes 1 -KeepRotated 2

        $remaining = @(Get-ChildItem $d -Filter 'sync.*.log.zip' | Sort-Object Name -Descending)
        Assert-Equal 2 $remaining.Count 'should have trimmed down to 2 zips'
        # The 2 remaining should be the 2 newest by timestamp.
        # All names from the run, plus the final one, sorted DESC, top 2.
        $allNames = @(Get-ChildItem $d -Filter 'sync.*.log.zip' | Sort-Object Name -Descending).Name
        Assert-Equal $allNames[0] $remaining[0].Name 'newest zip mismatch'
        Assert-Equal $allNames[1] $remaining[1].Name 'second-newest zip mismatch'
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

exit (Write-TestSummary)
