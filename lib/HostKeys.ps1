Set-StrictMode -Version 2.0

function Parse-PlinkHostKeyMessage {
    param([string]$Message)
    $pattern = '(ssh-ed25519|ssh-ed448|ssh-rsa|ssh-dss|ecdsa-sha2-nistp\d+)\s+\d+\s+(SHA256:[A-Za-z0-9+/=]{27,64})'
    if ($Message -match $pattern) {
        return @{
            Algorithm   = $Matches[1]
            Fingerprint = $Matches[2]
        }
    }
    return $null
}

function Parse-PlinkHostKeyChanged {
    param([string]$Message)
    if ($Message -notmatch 'POTENTIAL SECURITY BREACH|host key does not match') {
        return $null
    }
    $parsed = Parse-PlinkHostKeyMessage $Message
    if ($parsed) {
        return @{
            Changed        = $true
            NewFingerprint = $parsed.Fingerprint
            NewAlgorithm   = $parsed.Algorithm
        }
    }
    return @{ Changed = $true; NewFingerprint = ''; NewAlgorithm = '' }
}

function New-KnownHostsStore {
    return @{ hosts = @{} }
}

function Get-KnownHostKey {
    param(
        [hashtable]$Store,
        [string]$Ip
    )
    if ($Store.hosts.ContainsKey($Ip)) {
        return $Store.hosts[$Ip]
    }
    return $null
}

function Set-KnownHostKey {
    param(
        [hashtable]$Store,
        [string]$Ip,
        [string]$Fingerprint,
        [string]$Algorithm
    )
    $now = (Get-Date).ToString('o')
    if ($Store.hosts.ContainsKey($Ip)) {
        $Store.hosts[$Ip].fingerprint = $Fingerprint
        $Store.hosts[$Ip].algorithm   = $Algorithm
        $Store.hosts[$Ip].lastSeen    = $now
    }
    else {
        $Store.hosts[$Ip] = @{
            fingerprint = $Fingerprint
            algorithm   = $Algorithm
            firstSeen   = $now
            lastSeen    = $now
        }
    }
}

function Save-KnownHostsStore {
    param(
        [hashtable]$Store,
        [string]$Path
    )
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $json = $Store | ConvertTo-Json -Depth 10
    $tempPath = $Path + '.tmp'
    [IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tempPath, $Path, [NullString]::Value) }
    else { [IO.File]::Move($tempPath, $Path) }
}

function Import-KnownHostsStore {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return New-KnownHostsStore
    }
    $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $obj = $json | ConvertFrom-Json
    $store = @{ hosts = @{} }
    if ($null -ne $obj.hosts) {
        foreach ($prop in $obj.hosts.PSObject.Properties) {
            $entry = $prop.Value
            $store.hosts[$prop.Name] = @{
                fingerprint = [string]$entry.fingerprint
                algorithm   = [string]$entry.algorithm
                firstSeen   = [string]$entry.firstSeen
                lastSeen    = [string]$entry.lastSeen
            }
        }
    }
    return $store
}

function Resolve-HostKey {
    param(
        [string]$Ip,
        [hashtable]$PinnedKeys,
        [hashtable]$KnownHostsStore
    )

    if ($PinnedKeys.ContainsKey($Ip)) {
        $pinnedValue = [string]$PinnedKeys[$Ip]
        if ($pinnedValue -match '(SHA256:[A-Za-z0-9+/=]{27,64})') {
            return @{
                Source      = 'pinned'
                Fingerprint = $Matches[1]
                FullKey     = $pinnedValue
            }
        }
    }

    $known = Get-KnownHostKey $KnownHostsStore $Ip
    if ($known) {
        return @{
            Source      = 'known_hosts'
            Fingerprint = $known.fingerprint
            FullKey     = $known.fingerprint
        }
    }

    return $null
}
