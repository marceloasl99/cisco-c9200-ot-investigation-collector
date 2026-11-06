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
    if ($Params.HostKey) {
        $lines.Add("HOST KEY: $($Params.HostKey) (source: $($Params.KeySource))")
    }
    $lines.Add('##############################################################################')
    $lines.Add('')

    if ($Params.LogSummary) {
        $lines.Add('LOG SUMMARY:')
        $lines.Add("  $($Params.LogSummary)")
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
