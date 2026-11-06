BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/LogFilter.ps1')
    . (Join-Path $ProjectRoot 'lib/Report.ps1')
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
