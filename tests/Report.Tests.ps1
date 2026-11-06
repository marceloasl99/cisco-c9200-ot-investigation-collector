BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/LogFilter.ps1')
    . (Join-Path $ProjectRoot 'lib/Report.ps1')
}

Describe 'New-LogAnalysis' {
    BeforeAll {
        $fx = Join-Path $PSScriptRoot 'fixtures'
        $script:cliOutput = (Get-Content (Join-Path $fx 'show_clock_sample.txt') -Raw) + "`n" + (Get-Content (Join-Path $fx 'show_logging_sample.txt') -Raw)
    }

    It 'keeps only entries inside a 3 day window, using the switch clock as reference' {
        $a = New-LogAnalysis -Output $script:cliOutput -Days 3 -FallbackDate ([datetime]::new(2030, 1, 1))
        $a.Reference | Should -Be ([datetime]::new(2026, 11, 3, 14, 25, 30))
        $a.ReferenceSource | Should -Be 'switch clock'
        $a.InWindowCount | Should -Be 4
        $a.EntriesText | Should -Match 'LINEPROTO-5-UPDOWN'
        $a.EntriesText | Should -Match 'SYS-5-CONFIG_I'
        $a.EntriesText | Should -Not -Match 'PM-4-ERR_DISABLE'
    }

    It 'widens the window to 30 days' {
        (New-LogAnalysis -Output $script:cliOutput -Days 30 -FallbackDate (Get-Date)).InWindowCount | Should -Be 6
    }

    It 'returns every entry when days is 0' {
        $a = New-LogAnalysis -Output $script:cliOutput -Days 0 -FallbackDate (Get-Date)
        $a.InWindowCount | Should -Be $a.TotalEntries
        $a.TotalEntries | Should -Be 8
    }

    It 'states when the buffer does not reach back far enough' {
        $a = New-LogAnalysis -Output $script:cliOutput -Days 90 -FallbackDate (Get-Date)
        $a.Summary | Should -Match 'NOT COVERED'
        $a.CoverageShort | Should -Match 'NOT covered'
    }

    It 'states when the buffer covers the requested period' {
        $a = New-LogAnalysis -Output $script:cliOutput -Days 30 -FallbackDate (Get-Date)
        $a.Summary | Should -Match 'covered'
        $a.Summary | Should -Not -Match 'NOT COVERED'
    }

    It 'summarizes severities and top mnemonics' {
        $a = New-LogAnalysis -Output $script:cliOutput -Days 0 -FallbackDate (Get-Date)
        $a.Summary | Should -Match '%LINK-3-UPDOWN x3'
        $a.Summary | Should -Match 'Severity'
    }

    It 'falls back to the PC clock and says so when show clock is missing' {
        $noClock = (Get-Content (Join-Path $PSScriptRoot 'fixtures\show_logging_sample.txt') -Raw)
        $a = New-LogAnalysis -Output $noClock -Days 3 -FallbackDate ([datetime]::new(2026, 11, 3, 15, 0, 0))
        $a.ReferenceSource | Should -Be 'PC clock'
        $a.Summary | Should -Match 'PC clock'
    }

    It 'reports clearly when there are no syslog entries' {
        $a = New-LogAnalysis -Output "% Invalid input detected at '^' marker." -Days 3 -FallbackDate (Get-Date)
        $a.TotalEntries | Should -Be 0
        $a.Summary | Should -Match 'No syslog entries'
    }
}

Describe 'New-SwitchBlock note' {
    It 'prints the note near the top of the block' {
        $p = @{
            Name = 'SW'; Ip = '192.0.2.1'; Started = [datetime]::new(2026,11,3,10,0,0); Finished = [datetime]::new(2026,11,3,10,1,0)
            StdOut = 'RAWDATA'; StdErr = ''; ExitCode = 0; TimedOut = $false
            Note = 'host key auto-accepted on first use'
        }
        $b = New-SwitchBlock $p
        $b | Should -Match 'NOTE : host key auto-accepted on first use'
        $b.IndexOf('NOTE :') | Should -BeLessThan $b.IndexOf('RAWDATA')
    }
}

Describe 'New-SwitchBlock log section' {
    It 'prints the log summary and filtered entries before the raw output' {
        $p = @{
            Name = 'SW'; Ip = '192.0.2.1'; Started = [datetime]::new(2026,11,3,10,0,0); Finished = [datetime]::new(2026,11,3,10,1,0)
            StdOut = 'RAWDATA'; StdErr = ''; ExitCode = 0; TimedOut = $false
            LogSummary = 'SUMMARY-TEXT'; LogEntriesText = 'ENTRY-LINE'; LogDays = 3
        }
        $b = New-SwitchBlock $p
        $b.IndexOf('SUMMARY-TEXT') | Should -BeLessThan $b.IndexOf('RAWDATA')
        $b | Should -Match 'LOG ENTRIES - LAST 3 DAYS'
        $b.IndexOf('ENTRY-LINE') | Should -BeLessThan $b.IndexOf('RAWDATA')
    }
}

Describe 'Resolve-ReportDirectory' {
    It 'resolves "." to the script folder, not the current directory' {
        Resolve-ReportDirectory '.' 'C:\Tools\Collector' | Should -Be 'C:\Tools\Collector'
    }

    It 'resolves a relative folder under the script folder' {
        Resolve-ReportDirectory 'reports' 'C:\Tools\Collector' | Should -Be 'C:\Tools\Collector\reports'
    }

    It 'keeps an absolute folder unchanged' {
        Resolve-ReportDirectory 'D:\Evidence\Site-A' 'C:\Tools\Collector' | Should -Be 'D:\Evidence\Site-A'
    }

    It 'falls back to the script folder when blank' {
        Resolve-ReportDirectory '  ' 'C:\Tools\Collector' | Should -Be 'C:\Tools\Collector'
    }
}

Describe 'New-ReportHeader' {
    It 'produces a string with metadata fields' {
        $header = New-ReportHeader @{
            StartTime    = [datetime]::new(2026, 11, 3, 10, 0, 0)
            Username     = 'admin'
            PresetName   = 'Quick triage (3 days)'
            SwitchCount  = 4
            PlinkPath    = 'C:\plink.exe'
            SupportsPwFile = $true
            CommandCount = 62
            MaxParallel  = 4
        }
        $header | Should -Match 'CISCO C9200 OT NETWORK INVESTIGATION'
        $header | Should -Match 'admin'
        $header | Should -Match 'Quick triage'
    }
}

Describe 'New-SwitchBlock' {
    It 'produces a block with switch header, output, and result' {
        $block = New-SwitchBlock @{
            Name      = 'OT-SW-01'
            Ip        = '10.20.30.11'
            HostKey   = 'SHA256:abc'
            KeySource = 'PuTTY cache'
            StdOut    = 'Some CLI output here'
            StdErr    = ''
            ExitCode  = 0
            TimedOut  = $false
            Started   = [datetime]::new(2026, 11, 3, 10, 22, 0)
            Finished  = [datetime]::new(2026, 11, 3, 10, 23, 0)
            LogSummary = 'Buffer: 41 entries in 3d window, covers 6d'
        }
        $block | Should -Match 'OT-SW-01'
        $block | Should -Match '10.20.30.11'
        $block | Should -Match 'SHA256:abc'
        $block | Should -Match 'RAW CLI OUTPUT'
        $block | Should -Match 'COLLECTION RESULT'
    }

    It 'includes PLINK STDERR section when stderr is present' {
        $block = New-SwitchBlock @{
            Name      = 'SW-02'
            Ip        = '10.0.0.2'
            HostKey   = ''
            KeySource = ''
            StdOut    = 'output'
            StdErr    = 'some warning'
            ExitCode  = 0
            TimedOut  = $false
            Started   = [datetime]::Now
            Finished  = [datetime]::Now
            LogSummary = ''
        }
        $block | Should -Match 'PLINK STDERR'
        $block | Should -Match 'some warning'
    }
}

Describe 'New-CollectionSummary' {
    It 'produces summary table' {
        $switches = @(
            @{ Name='SW-01'; Ip='10.0.0.1'; Status='Done'; Duration='58s'; KB=812; LogCoverage='41/3d'; Notes='' }
            @{ Name='SW-02'; Ip='10.0.0.2'; Status='TimedOut'; Duration='175s'; KB=420; LogCoverage=''; Notes='partial output saved' }
        )
        $summary = New-CollectionSummary $switches ([datetime]::Now) ([datetime]::Now.AddMinutes(5))
        $summary | Should -Match 'COLLECTION SUMMARY'
        $summary | Should -Match 'SW-01'
        $summary | Should -Match 'SW-02'
        $summary | Should -Match 'TimedOut'
    }
}
