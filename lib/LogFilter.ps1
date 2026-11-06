Set-StrictMode -Version 2.0

$script:MonthMap = @{
    'Jan'=1;'Feb'=2;'Mar'=3;'Apr'=4;'May'=5;'Jun'=6
    'Jul'=7;'Aug'=8;'Sep'=9;'Oct'=10;'Nov'=11;'Dec'=12
}

function Parse-CiscoTimestamp {
    param(
        [string]$Line,
        [object]$ReferenceYear
    )

    $pattern = '(?:^\d+:\s*)?[*.]?([A-Z][a-z]{2})\s+(\d{1,2})\s+(?:(\d{4})\s+)?(\d{1,2}):(\d{2}):(\d{2})(?:\.\d+)?'
    if ($Line -notmatch $pattern) {
        return $null
    }

    $month = $script:MonthMap[$Matches[1]]
    if (-not $month) { return $null }
    $day   = [int]$Matches[2]
    $year  = if ($Matches[3]) { [int]$Matches[3] } else { $null }
    $hour  = [int]$Matches[4]
    $min   = [int]$Matches[5]
    $sec   = [int]$Matches[6]

    if ($null -eq $year -and $null -ne $ReferenceYear) {
        if ($ReferenceYear -is [datetime]) {
            $refDate = $ReferenceYear
            $year = $refDate.Year
        }
        else {
            $year = [int]$ReferenceYear
            $refDate = [datetime]::new($year, 11, 5, 0, 0, 0)
        }
        try {
            $candidate = [datetime]::new($year, $month, $day, $hour, $min, $sec)
            if ($candidate -gt $refDate.AddDays(2)) { $year-- }
        }
        catch { }
    }
    elseif ($null -eq $year) {
        $year = [datetime]::Now.Year
    }

    try {
        return [datetime]::new($year, $month, $day, $hour, $min, $sec)
    }
    catch {
        return $null
    }
}

function Parse-ShowClock {
    param([string]$ClockText)
    $authoritative = $ClockText -match '^\*'
    $pattern = '(\d{1,2}):(\d{2}):(\d{2})(?:\.\d+)?\s+(\w+)\s+\w+\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{4})'
    if ($ClockText -notmatch $pattern) { return $null }

    $hour  = [int]$Matches[1]
    $min   = [int]$Matches[2]
    $sec   = [int]$Matches[3]
    $tz    = $Matches[4]
    $month = $script:MonthMap[$Matches[5]]
    $day   = [int]$Matches[6]
    $year  = [int]$Matches[7]

    try {
        $dt = [datetime]::new($year, $month, $day, $hour, $min, $sec)
    }
    catch { return $null }

    return @{
        DateTime      = $dt
        Timezone      = $tz
        Authoritative = $authoritative
    }
}

function Get-LogEntries {
    param(
        [string]$LogText,
        [object]$ReferenceYear
    )
    $entries = @()
    $syslogPattern = '%([A-Z_]+)-(\d)-([A-Z_]+):\s*(.*)'
    $lines = $LogText -split "`n"

    foreach ($line in $lines) {
        if ($line -match $syslogPattern) {
            $facility = $Matches[1]
            $severity = [int]$Matches[2]
            $mnemonic = $Matches[3]
            $message  = $Matches[4].TrimEnd()

            $ts = Parse-CiscoTimestamp $line $ReferenceYear

            $entries += @{
                Timestamp = $ts
                Facility  = $facility
                Severity  = $severity
                Mnemonic  = $mnemonic
                Message   = $message
                RawLine   = $line.TrimEnd()
            }
        }
    }
    return $entries
}

function Filter-LogByDays {
    param(
        [array]$Entries,
        [int]$Days,
        [datetime]$ReferenceDate
    )
    if ($Days -le 0) {
        return $Entries
    }
    $cutoff = $ReferenceDate.AddDays(-$Days)
    return @($Entries | Where-Object {
        $null -eq $_.Timestamp -or $_.Timestamp -ge $cutoff
    })
}

function Get-LogCoverage {
    param(
        [array]$Entries,
        [datetime]$ReferenceDate,
        [int]$RequestedDays
    )
    $withTs = @($Entries | Where-Object { $null -ne $_.Timestamp } | Sort-Object { $_.Timestamp })
    $oldest = if ($withTs.Count -gt 0) { $withTs[0].Timestamp } else { $null }
    $newest = if ($withTs.Count -gt 0) { $withTs[-1].Timestamp } else { $null }
    $spanDays = if ($oldest -and $newest) { [math]::Ceiling(($newest - $oldest).TotalDays) } else { 0 }
    $covered = if ($RequestedDays -le 0) { $true }
               elseif ($null -eq $oldest) { $false }
               else { ($ReferenceDate - $oldest).TotalDays -ge $RequestedDays }

    return @{
        OldestEntry   = $oldest
        NewestEntry   = $newest
        SpanDays      = $spanDays
        TotalEntries  = $Entries.Count
        RequestedDays = $RequestedDays
        Covered       = $covered
    }
}

function Get-SeveritySummary {
    param([array]$Entries)
    $summary = @{}
    foreach ($entry in $Entries) {
        $sev = [string]$entry.Severity
        if ($summary.ContainsKey($sev)) {
            $summary[$sev]++
        }
        else {
            $summary[$sev] = 1
        }
    }
    return $summary
}

function Get-TopMnemonics {
    param(
        [array]$Entries,
        [int]$TopN = 10
    )
    $counts = @{}
    foreach ($entry in $Entries) {
        $key = "%{0}-{1}-{2}" -f $entry.Facility, $entry.Severity, $entry.Mnemonic
        if ($counts.ContainsKey($key)) { $counts[$key]++ }
        else { $counts[$key] = 1 }
    }
    $sorted = $counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopN
    return @($sorted | ForEach-Object { @{ Mnemonic = $_.Key; Count = $_.Value } })
}

function Parse-LogBufferHeader {
    param([string]$LogText)
    $result = @{
        BufferSize     = 0
        MessagesLogged = 0
        PersistentLogging = $false
        FileLogging    = $false
    }
    if ($LogText -match 'Log Buffer \((\d+) bytes\)') {
        $result.BufferSize = [int]$Matches[1]
    }
    if ($LogText -match 'Buffer logging:.*?(\d+) messages logged') {
        $result.MessagesLogged = [int]$Matches[1]
    }
    if ($LogText -match 'Persistent logging:\s*enabled') {
        $result.PersistentLogging = $true
    }
    if ($LogText -match 'File logging:\s*enabled') {
        $result.FileLogging = $true
    }
    return $result
}
