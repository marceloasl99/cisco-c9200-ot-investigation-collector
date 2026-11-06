Set-StrictMode -Version 2.0

function Get-DefaultSettings {
    $settings = @{
        connection = @{
            username                = 'network-admin'
            plinkPath               = ''
            sshPort                 = 22
            maxParallel             = 4
            perSwitchTimeoutSeconds = 175
            connectTimeoutSeconds   = 5
            hostKeyPolicy           = 'AutoAccept'
            onHostKeyChange         = 'Block'
        }
        targets = @{
            switches          = @()
            scanRanges        = @('192.0.2.0/24')
            includeNonCiscoSsh = $false
            maxScanHosts      = 1024
        }
        hostKeys = @{}
        report = @{
            directory = '.'
        }
        presets = @(
            @{
                name        = 'Quick triage (3 days)'
                description = 'Fast overview with 3-day log window'
                categories  = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs')
                logs        = @{ sources = @('Buffer'); days = 3 }
                vlans       = @{ mode = 'All'; list = @() }
                macs        = @()
            }
            @{
                name        = 'Standard investigation (30 days)'
                description = 'Full investigation with 30-day log window'
                categories  = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs','Detailed')
                logs        = @{ sources = @('Buffer','RebootHistory'); days = 30 }
                vlans       = @{ mode = 'All'; list = @() }
                macs        = @()
            }
            @{
                name        = 'Deep investigation (90 days)'
                description = 'Deep investigation with 90-day log window and running config'
                categories  = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs','Detailed','SanitizedRunningConfig')
                logs        = @{ sources = @('Buffer','RebootHistory'); days = 90 }
                vlans       = @{ mode = 'All'; list = @() }
                macs        = @()
            }
            @{
                name        = 'Logs only'
                description = 'Collect identity and logs only'
                categories  = @('Identity','Logs')
                logs        = @{ sources = @('Buffer','RebootHistory'); days = 30 }
                vlans       = @{ mode = 'All'; list = @() }
                macs        = @()
            }
            @{
                name        = 'VLAN focus'
                description = 'Layer 2 investigation for specific VLANs'
                categories  = @('Identity','Layer2','Logs')
                logs        = @{ sources = @('Buffer'); days = 3 }
                vlans       = @{ mode = 'Only'; list = @() }
                macs        = @()
            }
            @{
                name        = 'MAC trace'
                description = 'Trace specific MAC addresses across switches'
                categories  = @('Identity','Layer2','Layer3')
                logs        = @{ sources = @(); days = 0 }
                vlans       = @{ mode = 'All'; list = @() }
                macs        = @()
            }
        )
        lastUsed = @{}
    }
    return $settings
}

function Merge-Settings {
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )
    $result = @{}
    foreach ($key in $Base.Keys) {
        if ($Override.ContainsKey($key)) {
            $bVal = $Base[$key]
            $oVal = $Override[$key]
            if ($bVal -is [hashtable] -and $oVal -is [hashtable]) {
                $result[$key] = Merge-Settings $bVal $oVal
            }
            else {
                $result[$key] = $oVal
            }
        }
        else {
            $result[$key] = $Base[$key]
        }
    }
    foreach ($key in $Override.Keys) {
        if (-not $Base.ContainsKey($key)) {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Test-Settings {
    param([hashtable]$Settings)
    $errors = @()
    $c = $Settings.connection
    if ($c.maxParallel -lt 1 -or $c.maxParallel -gt 10) {
        $errors += "connection.maxParallel must be 1-10 (got $($c.maxParallel))"
    }
    if ($c.perSwitchTimeoutSeconds -lt 60 -or $c.perSwitchTimeoutSeconds -gt 900) {
        $errors += "connection.perSwitchTimeoutSeconds must be 60-900 (got $($c.perSwitchTimeoutSeconds))"
    }
    if ($c.connectTimeoutSeconds -lt 1 -or $c.connectTimeoutSeconds -gt 30) {
        $errors += "connection.connectTimeoutSeconds must be 1-30 (got $($c.connectTimeoutSeconds))"
    }
    if ($c.hostKeyPolicy -notin @('AutoAccept','Strict')) {
        $errors += "connection.hostKeyPolicy must be AutoAccept or Strict (got $($c.hostKeyPolicy))"
    }
    if ($c.onHostKeyChange -notin @('Block','Accept')) {
        $errors += "connection.onHostKeyChange must be Block or Accept (got $($c.onHostKeyChange))"
    }
    if ($Settings.targets.maxScanHosts -lt 1 -or $Settings.targets.maxScanHosts -gt 65534) {
        $errors += "targets.maxScanHosts must be 1-65534"
    }
    return $errors
}

function ConvertTo-SettingsJson {
    param([hashtable]$Settings)
    return $Settings | ConvertTo-Json -Depth 10
}

function ConvertFrom-SettingsJson {
    param([string]$Json)
    $obj = $Json | ConvertFrom-Json
    return ConvertTo-Hashtable $obj
}

function ConvertTo-Hashtable {
    param($InputObject)
    if ($InputObject -is [hashtable]) {
        return $InputObject
    }
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $ht
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $InputObject
}

function Save-Settings {
    param(
        [hashtable]$Settings,
        [string]$Path
    )
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $json = ConvertTo-SettingsJson $Settings
    $tempPath = $Path + '.tmp'
    [IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
    [IO.File]::Move($tempPath, $Path, $true)
}

function Import-Settings {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return Get-DefaultSettings
    }
    $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $user = ConvertFrom-SettingsJson $json
    $defaults = Get-DefaultSettings
    return Merge-Settings $defaults $user
}

function Get-PresetByName {
    param(
        [hashtable]$Settings,
        [string]$Name
    )
    foreach ($preset in $Settings.presets) {
        if ($preset.name -eq $Name) {
            return $preset
        }
    }
    return $null
}

function Get-LegacyModePreset {
    param([string]$Mode)
    switch ($Mode) {
        'Fast' {
            return @{
                name       = 'Legacy Fast'
                categories = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs')
                logs       = @{ sources = @('Buffer'); days = 0 }
                vlans      = @{ mode = 'All'; list = @() }
                macs       = @()
            }
        }
        'Standard' {
            return @{
                name       = 'Legacy Standard'
                categories = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs','Detailed')
                logs       = @{ sources = @('Buffer'); days = 0 }
                vlans      = @{ mode = 'All'; list = @() }
                macs       = @()
            }
        }
        'Deep' {
            return @{
                name       = 'Legacy Deep'
                categories = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs','Detailed','SanitizedRunningConfig')
                logs       = @{ sources = @('Buffer','RebootHistory'); days = 0 }
                vlans      = @{ mode = 'All'; list = @() }
                macs       = @()
            }
        }
    }
}
