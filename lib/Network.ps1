Set-StrictMode -Version 2.0

function Expand-IPv4Cidr {
    param(
        [string]$CidrList,
        [int]$MaxHosts = 65534
    )

    $allHosts = New-Object Collections.Generic.List[string]
    $ranges = $CidrList -split ','

    foreach ($range in $ranges) {
        $range = $range.Trim()
        if ($range -eq '') { continue }

        if ($range -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
            $ipStr  = $Matches[1]
            $prefix = [int]$Matches[2]
        }
        elseif ($range -match '^\d+\.\d+\.\d+\.\d+$') {
            $ipStr  = $range
            $prefix = 32
        }
        else {
            throw "Invalid CIDR notation: $range"
        }

        if ($prefix -lt 16) {
            throw "Prefix /$prefix is too broad (minimum /16)"
        }

        $ipParts = $ipStr -split '\.'
        if ($ipParts.Count -ne 4) { throw "Invalid IP: $ipStr" }
        foreach ($part in $ipParts) {
            $v = [int]$part
            if ($v -lt 0 -or $v -gt 255) { throw "Invalid IP octet: $part in $ipStr" }
        }

        $ipBytes = [byte[]]@(
            [int]$ipParts[0], [int]$ipParts[1],
            [int]$ipParts[2], [int]$ipParts[3]
        )
        $ipUint = ([uint32]$ipBytes[0] -shl 24) -bor ([uint32]$ipBytes[1] -shl 16) -bor ([uint32]$ipBytes[2] -shl 8) -bor [uint32]$ipBytes[3]

        if ($prefix -eq 32) {
            $allHosts.Add($ipStr)
            continue
        }

        $hostBits = 32 - $prefix
        $netMask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, $hostBits))
        $network  = $ipUint -band $netMask
        $broadcast = $network -bor ([uint32]([math]::Pow(2, $hostBits) - 1))

        for ($addr = $network + 1; $addr -lt $broadcast; $addr++) {
            $o1 = [int](($addr -shr 24) -band 0xFF)
            $o2 = [int](($addr -shr 16) -band 0xFF)
            $o3 = [int](($addr -shr 8) -band 0xFF)
            $o4 = [int]($addr -band 0xFF)
            $allHosts.Add("$o1.$o2.$o3.$o4")
        }
    }

    if ($allHosts.Count -gt $MaxHosts) {
        throw "Expanded host count ($($allHosts.Count)) exceeds limit ($MaxHosts)"
    }

    return , $allHosts.ToArray()
}

function New-ScanResult {
    param([string]$Ip)
    return @{
        Ip        = $Ip
        PingReply = $false
        TcpOpen   = $false
        Banner    = ''
        IsCisco   = $false
        Selected  = $false
    }
}

function Test-CiscoBanner {
    param([string]$Banner)
    if ([string]::IsNullOrEmpty($Banner)) { return $false }
    return $Banner -match '^SSH-[\d.]+-Cisco'
}

function Start-NetworkScan {
    param(
        [string[]]$Hosts,
        [int]$Port = 22,
        [int]$PingTimeoutMs = 1000,
        [int]$TcpTimeoutMs = 1500
    )

    $state = @{
        Hosts         = $Hosts
        Port          = $Port
        PingTimeoutMs = $PingTimeoutMs
        TcpTimeoutMs  = $TcpTimeoutMs
        Results       = @()
        Probes        = @()
        Index         = 0
        MaxConcurrent = 64
        Done          = $false
    }

    foreach ($ip in $Hosts) {
        $state.Results += New-ScanResult $ip
    }

    return $state
}

function Step-NetworkScan {
    param([hashtable]$State)

    if ($State.Done) { return }

    $activeCount = @($State.Probes | Where-Object { -not $_['Completed'] }).Count

    while ($State.Index -lt $State.Hosts.Count -and $activeCount -lt $State.MaxConcurrent) {
        $idx = $State.Index
        $ip  = $State.Hosts[$idx]
        $probe = @{
            Index     = $idx
            Ip        = $ip
            Completed = $false
            PingDone  = $false
            TcpDone   = $false
            BannerDone = $false
            PingTask  = $null
            TcpClient = $null
            TcpTask   = $null
            TcpStream = $null
            ReadTask  = $null
            ReadBuf   = $null
            StartTime = [datetime]::Now
        }

        try {
            $pinger = New-Object Net.NetworkInformation.Ping
            $probe.PingTask = $pinger.SendPingAsync($ip, $State.PingTimeoutMs)
            $probe['Pinger'] = $pinger
        }
        catch {
            $probe.PingDone = $true
        }

        try {
            $client = New-Object Net.Sockets.TcpClient
            $probe.TcpClient = $client
            $probe.TcpTask = $client.ConnectAsync($ip, $State.Port)
        }
        catch {
            $probe.TcpDone = $true
        }

        $State.Probes += $probe
        $State.Index++
        $activeCount++
    }

    foreach ($probe in $State.Probes) {
        if ($probe.Completed) { continue }
        $idx = $probe.Index
        $now = [datetime]::Now

        if (-not $probe.PingDone -and $null -ne $probe.PingTask) {
            if ($probe.PingTask.IsCompleted) {
                $probe.PingDone = $true
                try {
                    $reply = $probe.PingTask.Result
                    if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                        $State.Results[$idx]['PingReply'] = $true
                    }
                }
                catch {}
                try { $probe['Pinger'].Dispose() } catch {}
            }
            elseif (($now - $probe.StartTime).TotalMilliseconds -gt ($State.PingTimeoutMs + 500)) {
                $probe.PingDone = $true
                try { $probe['Pinger'].Dispose() } catch {}
            }
        }

        if (-not $probe.TcpDone -and $null -ne $probe.TcpTask) {
            if ($probe.TcpTask.IsCompleted) {
                if ($probe.TcpTask.IsFaulted -or $probe.TcpTask.IsCanceled) {
                    $probe.TcpDone = $true
                    $probe.BannerDone = $true
                    try { $probe.TcpClient.Dispose() } catch {}
                }
                else {
                    $State.Results[$idx]['TcpOpen'] = $true
                    try {
                        $stream = $probe.TcpClient.GetStream()
                        $stream.ReadTimeout = 2000
                        $buf = New-Object byte[] 256
                        $probe.TcpStream = $stream
                        $probe.ReadBuf = $buf
                        $probe.ReadTask = $stream.ReadAsync($buf, 0, 256)
                    }
                    catch {
                        $probe.BannerDone = $true
                    }
                    $probe.TcpDone = $true
                }
            }
            elseif (($now - $probe.StartTime).TotalMilliseconds -gt ($State.TcpTimeoutMs + 500)) {
                $probe.TcpDone = $true
                $probe.BannerDone = $true
                try { $probe.TcpClient.Dispose() } catch {}
            }
        }

        if (-not $probe.BannerDone -and $probe.TcpDone -and $null -ne $probe.ReadTask) {
            if ($probe.ReadTask.IsCompleted) {
                $probe.BannerDone = $true
                try {
                    $bytesRead = $probe.ReadTask.Result
                    if ($bytesRead -gt 0) {
                        $banner = [Text.Encoding]::ASCII.GetString($probe.ReadBuf, 0, $bytesRead).Trim()
                        $State.Results[$idx]['Banner'] = $banner
                        $State.Results[$idx]['IsCisco'] = Test-CiscoBanner $banner
                        if ($State.Results[$idx]['IsCisco']) {
                            $State.Results[$idx]['Selected'] = $true
                        }
                    }
                }
                catch {}
                try { $probe.TcpClient.Dispose() } catch {}
            }
            elseif (($now - $probe.StartTime).TotalMilliseconds -gt ($State.TcpTimeoutMs + 3000)) {
                $probe.BannerDone = $true
                try { $probe.TcpClient.Dispose() } catch {}
            }
        }

        if ($probe.PingDone -and $probe.TcpDone -and $probe.BannerDone) {
            $probe.Completed = $true
        }
    }

    $remaining = @($State.Probes | Where-Object { -not $_['Completed'] }).Count
    if ($State.Index -ge $State.Hosts.Count -and $remaining -eq 0) {
        $State.Done = $true
    }
}
