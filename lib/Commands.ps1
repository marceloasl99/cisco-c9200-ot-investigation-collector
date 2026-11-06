Set-StrictMode -Version 2.0

function ConvertTo-CiscoMac {
    param([string]$Mac)
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
    if ($hex.Length -ne 12) {
        throw "Invalid MAC address: $Mac"
    }
    return '{0}.{1}.{2}' -f $hex.Substring(0,4), $hex.Substring(4,4), $hex.Substring(8,4)
}

function Parse-VlanList {
    param([string]$VlanString)
    $vlans = New-Object Collections.Generic.HashSet[int]
    $parts = $VlanString -split ','
    foreach ($part in $parts) {
        $part = $part.Trim()
        if ($part -eq '') { continue }
        if ($part -match '^(\d+)-(\d+)$') {
            $start = [int]$Matches[1]
            $end   = [int]$Matches[2]
            if ($start -lt 1 -or $end -gt 4094 -or $start -gt $end) {
                throw "Invalid VLAN range: $part (valid: 1-4094)"
            }
            for ($v = $start; $v -le $end; $v++) {
                $vlans.Add($v) | Out-Null
            }
        }
        elseif ($part -match '^\d+$') {
            $v = [int]$part
            if ($v -lt 1 -or $v -gt 4094) {
                throw "Invalid VLAN: $v (valid: 1-4094)"
            }
            $vlans.Add($v) | Out-Null
        }
        else {
            throw "Invalid VLAN entry: $part"
        }
    }
    if ($vlans.Count -gt 64) {
        throw "Too many VLANs: $($vlans.Count) (max 64)"
    }
    return @($vlans | Sort-Object)
}

function Test-CommandAllowlist {
    param([string]$Command)
    if ($Command -match '\|\s*(redirect|tee|append)\b') {
        return $false
    }
    if ($Command -match '^(terminal (length|width) \d+|show .+|exit)$') {
        return $true
    }
    return $false
}

function New-CommandCatalog {
    $catalog = @{}

    $catalog['Identity'] = @(
        'show clock detail'
        'show version'
        'show inventory'
        'show switch detail'
        'show boot'
        'show redundancy'
    )

    $catalog['Health'] = @(
        'show platform'
        'show platform resources'
        'show platform software status control-processor brief'
        'show processes cpu sorted 5sec'
        'show processes memory platform sorted'
        'show environment all'
        'show power inline'
        'show license summary'
    )

    $catalog['Interfaces'] = @(
        'show interfaces status'
        'show interfaces description'
        'show ip interface brief'
        'show interfaces counters'
        'show interfaces counters errors'
        'show interfaces transceiver detail'
        'show interfaces switchport'
        'show interfaces status err-disabled'
        'show errdisable detect'
        'show errdisable recovery'
    )

    $catalog['Layer2'] = @(
        'show vlan brief'
        'show interfaces trunk'
        'show etherchannel summary'
        'show etherchannel port-channel'
        'show spanning-tree summary'
        'show spanning-tree root'
        'show spanning-tree blockedports'
        'show spanning-tree inconsistentports'
        'show mac address-table count'
        'show mac address-table dynamic'
        'show cdp neighbors detail'
        'show lldp neighbors detail'
        'show vtp status'
    )

    $catalog['Layer3'] = @(
        'show ip arp'
        'show ip route'
        'show ip default-gateway'
        'show ip protocols'
        'show ntp associations'
        'show ntp status'
    )

    $catalog['Security'] = @(
        'show port-security'
        'show port-security address'
        'show authentication sessions'
        'show access-lists'
        'show ip access-lists'
        'show ip dhcp snooping'
        'show ip arp inspection'
        'show ip verify source'
        'show storm-control'
        'show monitor session all'
    )

    $catalog['ConfigExtracts'] = @(
        'show running-config | section ^interface'
        'show running-config | section ^vlan'
        'show running-config | section ^spanning-tree'
        'show running-config | section ^monitor session'
        'show running-config | include ^hostname|^ip default-gateway|^ip route|^ntp|^clock timezone|^logging host|^snmp-server location'
    )

    $catalog['Logs'] = @(
        'show logging'
        'show logging onboard switch active uptime detail'
    )

    $catalog['Detailed'] = @(
        'show spanning-tree detail'
        'show interfaces'
        'show platform software fed switch active punt rates interfaces'
        'show platform software fed switch active punt cpuq rates'
        'show diagnostic result switch all detail'
    )

    $catalog['SanitizedRunningConfig'] = @(
        'show running-config | exclude password|secret|community|key-string|authentication-key|privacy-key'
    )

    return $catalog
}

function Get-LegacyModeCategories {
    param([string]$Mode)
    $base = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs')
    switch ($Mode) {
        'Fast'     { return $base }
        'Standard' { return $base + @('Detailed') }
        'Deep'     { return $base + @('Detailed','SanitizedRunningConfig') }
        default    { return $base }
    }
}

function Build-CommandList {
    param(
        [string[]]$Categories,
        [int[]]$Vlans = @(),
        [string]$VlanMode = 'All',
        [string[]]$Macs = @(),
        [string[]]$LogSources = @('Buffer')
    )

    $catalog = New-CommandCatalog
    $commands = New-Object Collections.Generic.List[string]

    $commands.Add('terminal length 0')
    $commands.Add('terminal width 511')
    $commands.Add('show clock detail')

    foreach ($cat in $Categories) {
        if (-not $catalog.ContainsKey($cat)) { continue }
        $catCmds = $catalog[$cat]

        if ($cat -eq 'Logs') {
            if ($LogSources -contains 'Buffer') {
                $commands.Add('show logging')
            }
            if ($LogSources -contains 'RebootHistory') {
                $commands.Add('show logging onboard switch active uptime detail')
            }
            continue
        }

        foreach ($cmd in $catCmds) {
            if ($cmd -eq 'show clock detail') { continue }
            if (-not (Test-CommandAllowlist $cmd)) { continue }
            $commands.Add($cmd)
        }
    }

    if ($Categories -contains 'Layer2') {
        if ($VlanMode -eq 'Only') {
            foreach ($v in $Vlans) {
                $commands.Add("show vlan id $v")
                $commands.Add("show spanning-tree vlan $v detail")
                $commands.Add("show mac address-table vlan $v")
            }
        }
        else {
            foreach ($v in $Vlans) {
                $commands.Add("show vlan id $v")
                $commands.Add("show spanning-tree vlan $v detail")
                $commands.Add("show mac address-table vlan $v")
            }
        }
    }

    foreach ($mac in $Macs) {
        $ciscoMac = ConvertTo-CiscoMac $mac
        $commands.Add("show mac address-table address $ciscoMac")
        if ($Categories -contains 'Layer3') {
            $commands.Add("show ip arp | include $ciscoMac")
        }
    }

    $commands.Add('exit')
    return , $commands.ToArray()
}
