BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/LogFilter.ps1')
    $FixtureDir = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Parse-CiscoTimestamp' {
    It 'parses standard syslog format with asterisk' {
        $ts = Parse-CiscoTimestamp '*Nov  3 14:22:01.123' 2026
        $ts | Should -Not -BeNullOrEmpty
        $ts.Month | Should -Be 11
        $ts.Day | Should -Be 3
        $ts.Hour | Should -Be 14
        $ts.Year | Should -Be 2026
    }

    It 'parses format with dot prefix' {
        $ts = Parse-CiscoTimestamp '.Nov  3 14:22:01.123' 2026
        $ts | Should -Not -BeNullOrEmpty
        $ts.Month | Should -Be 11
    }

    It 'parses format with explicit year' {
        $ts = Parse-CiscoTimestamp '*Jan 15 2025 08:00:00.000' $null
        $ts | Should -Not -BeNullOrEmpty
        $ts.Year | Should -Be 2025
        $ts.Month | Should -Be 1
    }

    It 'infers year from reference when not in timestamp' {
        $ts = Parse-CiscoTimestamp '*Dec 25 10:00:00.000' 2026
        $ts.Year | Should -Be 2025 -Because 'Dec 25 is in the future relative to Nov 3 2026'
    }

    It 'returns null for non-timestamp strings' {
        $ts = Parse-CiscoTimestamp 'not a timestamp' 2026
        $ts | Should -BeNullOrEmpty
    }

    It 'handles sequence number prefix' {
        $ts = Parse-CiscoTimestamp '000123: *Nov  3 14:22:01.123' 2026
        $ts | Should -Not -BeNullOrEmpty
        $ts.Month | Should -Be 11
    }
}

Describe 'Parse-CiscoTimestamp with a reference date' {
    It 'puts a December entry in the previous year when the switch clock is in January' {
        $ref = [datetime]::new(2027, 1, 10, 12, 0, 0)
        $ts = Parse-CiscoTimestamp '*Dec 20 10:00:00.000' $ref
        $ts | Should -Be ([datetime]::new(2026, 12, 20, 10, 0, 0))
    }

    It 'keeps an entry from the same month in the reference year' {
        $ref = [datetime]::new(2027, 1, 10, 12, 0, 0)
        $ts = Parse-CiscoTimestamp '*Jan  9 08:00:00.000' $ref
        $ts | Should -Be ([datetime]::new(2027, 1, 9, 8, 0, 0))
    }

    It 'still accepts a plain year number' {
        (Parse-CiscoTimestamp '*Mar  1 00:00:00.000' 2026).Year | Should -Be 2026
    }
}

Describe 'Parse-ShowClock' {
    It 'parses standard show clock detail output' {
        $clockText = '*14:25:30.123 UTC Wed Nov 3 2026'
        $result = Parse-ShowClock $clockText
        $result | Should -Not -BeNullOrEmpty
        $result.DateTime.Year | Should -Be 2026
        $result.DateTime.Month | Should -Be 11
        $result.DateTime.Day | Should -Be 3
        $result.Authoritative | Should -BeTrue
    }

    It 'detects non-authoritative clock (no asterisk)' {
        $result = Parse-ShowClock '14:25:30.123 UTC Wed Nov 3 2026'
        $result | Should -Not -BeNullOrEmpty
        $result.Authoritative | Should -BeFalse
    }
}

Describe 'Get-LogEntries' {
    BeforeAll {
        $logText = Get-Content (Join-Path $FixtureDir 'show_logging_sample.txt') -Raw
    }

    It 'extracts syslog entries from buffer output' {
        $entries = Get-LogEntries $logText 2026
        $entries.Count | Should -BeGreaterOrEqual 7
    }

    It 'each entry has Timestamp, Facility, Severity, Mnemonic, Message' {
        $entries = Get-LogEntries $logText 2026
        $first = $entries[0]
        $first.Facility | Should -Not -BeNullOrEmpty
        $first.Severity | Should -BeGreaterOrEqual 0
        $first.Mnemonic | Should -Not -BeNullOrEmpty
    }

    It 'parses LINK-3-UPDOWN correctly' {
        $entries = Get-LogEntries $logText 2026
        $linkUp = $entries | Where-Object { $_.Mnemonic -eq 'UPDOWN' -and $_.Facility -eq 'LINK' } | Select-Object -First 1
        $linkUp | Should -Not -BeNullOrEmpty
        $linkUp.Severity | Should -Be 3
    }
}

Describe 'Filter-LogByDays' {
    BeforeAll {
        $logText = Get-Content (Join-Path $FixtureDir 'show_logging_sample.txt') -Raw
        $entries = Get-LogEntries $logText 2026
        $refDate = [datetime]::new(2026, 11, 3, 14, 25, 30)
    }

    It 'returns all entries when days=0' {
        $filtered = Filter-LogByDays $entries 0 $refDate
        $filtered.Count | Should -Be $entries.Count
    }

    It 'filters to last 3 days' {
        $filtered = Filter-LogByDays $entries 3 $refDate
        $filtered.Count | Should -BeGreaterOrEqual 3
        $filtered.Count | Should -BeLessOrEqual $entries.Count
    }

    It 'filters to last 30 days' {
        $filtered = Filter-LogByDays $entries 30 $refDate
        $filtered.Count | Should -BeGreaterOrEqual 4
    }
}

Describe 'Get-LogCoverage' {
    BeforeAll {
        $logText = Get-Content (Join-Path $FixtureDir 'show_logging_sample.txt') -Raw
        $entries = Get-LogEntries $logText 2026
        $refDate = [datetime]::new(2026, 11, 3, 14, 25, 30)
    }

    It 'reports oldest and newest timestamps' {
        $cov = Get-LogCoverage $entries $refDate 30
        $cov.OldestEntry | Should -Not -BeNullOrEmpty
        $cov.NewestEntry | Should -Not -BeNullOrEmpty
        $cov.TotalEntries | Should -Be $entries.Count
    }

    It 'reports whether requested window is covered' {
        $cov = Get-LogCoverage $entries $refDate 3
        $cov.RequestedDays | Should -Be 3
        $cov.Covered | Should -BeOfType [bool]
    }
}

Describe 'Get-SeveritySummary' {
    It 'counts entries by severity' {
        $logText = Get-Content (Join-Path $FixtureDir 'show_logging_sample.txt') -Raw
        $entries = Get-LogEntries $logText 2026
        $summary = Get-SeveritySummary $entries
        $summary | Should -Not -BeNullOrEmpty
        ($summary.Values | Measure-Object -Sum).Sum | Should -Be $entries.Count
    }
}

Describe 'Get-TopMnemonics' {
    It 'returns top N mnemonics by count' {
        $logText = Get-Content (Join-Path $FixtureDir 'show_logging_sample.txt') -Raw
        $entries = Get-LogEntries $logText 2026
        $top = Get-TopMnemonics $entries 5
        $top | Should -Not -BeNullOrEmpty
        $top[0].Count | Should -BeGreaterOrEqual $top[-1].Count
    }
}

Describe 'Parse-LogBufferHeader' {
    It 'extracts buffer size from show logging output' {
        $logText = Get-Content (Join-Path $FixtureDir 'show_logging_sample.txt') -Raw
        $header = Parse-LogBufferHeader $logText
        $header.BufferSize | Should -Be 16384
        $header.MessagesLogged | Should -Be 1247
    }
}
