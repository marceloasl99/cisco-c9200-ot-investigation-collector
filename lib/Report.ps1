Set-StrictMode -Version 2.0

function Resolve-ReportDirectory {
    param(
        [string]$Directory,
        [string]$ScriptRoot
    )
    if ([string]::IsNullOrWhiteSpace($Directory)) { return $ScriptRoot }
    if ([IO.Path]::IsPathRooted($Directory)) { return $Directory }
    return [IO.Path]::GetFullPath((Join-Path $ScriptRoot $Directory))
}

function New-LogAnalysis {
    param(
        [string]$Output,
        [int]$Days,
        [datetime]$FallbackDate
    )
    $nl = [Environment]::NewLine
    $clockPattern = '(?m)^[*.]?\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\s+\w+\s+\w+\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{4}\s*$'
    $reference = $FallbackDate
    $source = 'PC clock'
    $notes = @()
    $clockMatch = [regex]::Match($Output, $clockPattern)
    if ($clockMatch.Success) {
        $clock = Parse-ShowClock $clockMatch.Value.Trim()
        if ($clock) {
            $reference = $clock.DateTime
            $source = 'switch clock'
            if ($clockMatch.Value.TrimStart().StartsWith('*')) {
                $notes += 'The switch clock is not synchronised (no time source), so event times may be off.'
            }
        }
    }
    if ($source -eq 'PC clock') {
        $notes += 'show clock was not readable; the PC clock was used as the reference for the period.'
    }

    $all = @(Get-LogEntries -LogText $Output -ReferenceYear $reference)
    $window = @(Filter-LogByDays -Entries $all -Days $Days -ReferenceDate $reference)
    $periodText = if ($Days -gt 0) { "last $Days days" } else { 'all entries' }
    $result = @{
        Reference       = $reference
        ReferenceSource = $source
        TotalEntries    = $all.Count
        InWindowCount   = $window.Count
        EntriesText     = ''
        CoverageShort   = ''
        Summary         = ''
    }

    $head = "Period: $periodText (reference: $source $($reference.ToString('yyyy-MM-dd HH:mm:ss')))"
    if ($all.Count -eq 0) {
        $result.CoverageShort = 'no entries'
        $result.Summary = $head + $nl + 'No syslog entries found in the output (logging disabled, empty buffer, or the command failed).'
        return $result
    }

    $cov = Get-LogCoverage -Entries $all -ReferenceDate $reference -RequestedDays $Days
    $buf = Parse-LogBufferHeader $Output
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($head)
    if ($buf.MessagesLogged -gt 0) {
        $lines.Add("Log buffer       : $($buf.BufferSize) bytes, $($buf.MessagesLogged) messages logged")
    }
    $lines.Add("Entries parsed   : $($all.Count) in output, $($window.Count) inside the period")
    if ($cov.OldestEntry) {
        $lines.Add("Oldest / newest  : $($cov.OldestEntry.ToString('yyyy-MM-dd HH:mm:ss')) / $($cov.NewestEntry.ToString('yyyy-MM-dd HH:mm:ss'))")
        $reach = [math]::Floor(($reference - $cov.OldestEntry).TotalDays)
        if ($Days -le 0) {
            $lines.Add("Coverage         : buffer reaches back $reach days (all entries requested)")
            $result.CoverageShort = "reaches $reach d"
        }
        elseif ($cov.Covered) {
            $lines.Add("Coverage         : buffer reaches back $reach days, requested $Days days: covered")
            $result.CoverageShort = "$Days d covered"
        }
        else {
            $lines.Add("Coverage         : buffer reaches back only $reach days, requested $Days days: NOT COVERED (older events may have been overwritten)")
            $result.CoverageShort = "$Days d NOT covered ($reach d)"
        }
    }
    else {
        $lines.Add('Coverage         : entries have no readable timestamps, so the period could not be applied.')
        $result.CoverageShort = 'no timestamps'
    }
    $sev = Get-SeveritySummary $window
    $sevText = ($sev.Keys | Sort-Object { [int]$_ } | ForEach-Object { "$_=$($sev[$_])" }) -join ', '
    if ($sevText) { $lines.Add("Severity (period): $sevText") }
    $top = @(Get-TopMnemonics -Entries $window -TopN 10)
    if ($top.Count -gt 0) {
        $lines.Add('Top mnemonics    : ' + (($top | ForEach-Object { "$($_.Mnemonic) x$($_.Count)" }) -join ', '))
    }
    foreach ($n in $notes) { $lines.Add("Note             : $n") }

    $result.Summary = ($lines -join $nl)
    $result.EntriesText = (($window | ForEach-Object { $_.RawLine }) -join $nl)
    return $result
}

function New-ReportHeader {
    param([hashtable]$Params)
    $lines = @(
        '=========================================================================='
        'CISCO C9200 OT NETWORK INVESTIGATION'
        '=========================================================================='
        "Started             : $($Params.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        "Operator account    : $($Params.Username)"
        "Preset              : $($Params.PresetName)"
        "Switch count        : $($Params.SwitchCount)"
        "Plink               : $($Params.PlinkPath)"
        "Plink -pwfile       : $($Params.SupportsPwFile)"
        "Commands per switch : $($Params.CommandCount)"
        "Max parallel        : $($Params.MaxParallel)"
        ''
        'NOTE: This report may contain sensitive network details. Protect it.'
        'Some commands vary by IOS-XE release; CLI errors are retained as evidence.'
        ''
    )
    return $lines -join [Environment]::NewLine
}

function New-SwitchBlock {
    param([hashtable]$Params)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('##############################################################################')
    $lines.Add("SWITCH: $($Params.Name) ($($Params.Ip))")
    $lines.Add("START : $($Params.Started.ToString('yyyy-MM-dd HH:mm:ss'))")
    if ($Params['HostKey']) {
        $lines.Add("HOST KEY: $($Params['HostKey']) (source: $($Params['KeySource']))")
    }
    if ($Params['Note']) {
        $lines.Add("NOTE : $($Params['Note'])")
    }
    $lines.Add('##############################################################################')
    $lines.Add('')

    if ($Params['LogSummary']) {
        $lines.Add('LOG SUMMARY:')
        $lines.Add("  $($Params['LogSummary'])".Replace([Environment]::NewLine, [Environment]::NewLine + '  '))
        $lines.Add('')
    }

    if ($Params['LogEntriesText']) {
        $lines.Add("LOG ENTRIES - LAST $($Params['LogDays']) DAYS:")
        $lines.Add('------------------------------------------------------------------------------')
        $lines.Add($Params['LogEntriesText'].TrimEnd())
        $lines.Add('')
    }

    $lines.Add('RAW CLI OUTPUT:')
    $lines.Add('------------------------------------------------------------------------------')
    $lines.Add($Params.StdOut.TrimEnd())

    if (-not [string]::IsNullOrWhiteSpace($Params.StdErr)) {
        $lines.Add('')
        $lines.Add('PLINK STDERR:')
        $lines.Add($Params.StdErr.TrimEnd())
    }

    $lines.Add('')
    $lines.Add('COLLECTION RESULT:')
    $lines.Add("  Exit code : $($Params.ExitCode)")
    $lines.Add("  Timed out : $($Params.TimedOut)")
    $lines.Add("  Finished  : $($Params.Finished.ToString('yyyy-MM-dd HH:mm:ss'))")
    $duration = ($Params.Finished - $Params.Started).TotalSeconds
    $lines.Add("  Duration  : $([math]::Round($duration, 1)) seconds")
    $lines.Add('')
    $lines.Add("END SWITCH: $($Params.Name) ($($Params.Ip))")
    $lines.Add('')

    return $lines -join [Environment]::NewLine
}

function New-CollectionSummary {
    param(
        [array]$SwitchResults,
        [datetime]$RunStart,
        [datetime]$RunEnd
    )
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('==========================================================================')
    $lines.Add('COLLECTION SUMMARY')
    $lines.Add('==========================================================================')
    $lines.Add('')
    $fmt = '{0,-20} {1,-16} {2,-12} {3,-10} {4,-8} {5,-15} {6}'
    $lines.Add(($fmt -f 'Switch','IP','Status','Duration','KB','Log coverage','Notes'))
    $lines.Add(($fmt -f '------','--','------','--------','--','-----------','-----'))

    foreach ($sw in $SwitchResults) {
        $n = [string]$sw['Name']
        $ip = [string]$sw['Ip']
        $st = [string]$sw['Status']
        $dur = [string]$sw['Duration']
        $kb = [string]$sw['KB']
        $lc = [string]$sw['LogCoverage']
        $nt = [string]$sw['Notes']
        $lines.Add(('{0,-20} {1,-16} {2,-12} {3,-10} {4,-8} {5,-15} {6}' -f $n, $ip, $st, $dur, $kb, $lc, $nt))
    }

    $lines.Add('')
    $lines.Add("Started  : $($RunStart.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("Finished : $($RunEnd.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("Duration : $(($RunEnd - $RunStart).ToString())")
    $lines.Add('==========================================================================')

    return $lines -join [Environment]::NewLine
}
