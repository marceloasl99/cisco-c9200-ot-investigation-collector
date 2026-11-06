BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/Network.ps1')
}

Describe 'Expand-IPv4Cidr' {
    It 'expands /24 to 254 hosts' {
        $hosts = Expand-IPv4Cidr '192.0.2.0/24'
        $hosts.Count | Should -Be 254
        $hosts[0] | Should -Be '192.0.2.1'
        $hosts[-1] | Should -Be '192.0.2.254'
    }

    It 'expands /30 to 2 hosts' {
        $hosts = Expand-IPv4Cidr '10.0.0.0/30'
        $hosts.Count | Should -Be 2
        $hosts | Should -Contain '10.0.0.1'
        $hosts | Should -Contain '10.0.0.2'
    }

    It 'expands /32 to 1 host (the address itself)' {
        $hosts = Expand-IPv4Cidr '10.0.0.5/32'
        $hosts.Count | Should -Be 1
        $hosts[0] | Should -Be '10.0.0.5'
    }

    It 'handles bare IP as /32' {
        $hosts = Expand-IPv4Cidr '10.0.0.5'
        $hosts.Count | Should -Be 1
        $hosts[0] | Should -Be '10.0.0.5'
    }

    It 'rejects prefix shorter than /16' {
        { Expand-IPv4Cidr '10.0.0.0/15' } | Should -Throw '*16*'
    }

    It 'rejects invalid IP' {
        { Expand-IPv4Cidr '999.0.0.0/24' } | Should -Throw
    }

    It 'expands comma-separated ranges' {
        $hosts = Expand-IPv4Cidr '10.0.0.1/32,10.0.0.2/32'
        $hosts.Count | Should -Be 2
    }
}

Describe 'Expand-IPv4Cidr maxHosts limit' {
    It 'enforces maxHosts limit' {
        { Expand-IPv4Cidr '10.0.0.0/16' -MaxHosts 1024 } | Should -Throw '*1024*'
    }

    It 'allows within limit' {
        $hosts = Expand-IPv4Cidr '10.0.0.0/24' -MaxHosts 1024
        $hosts.Count | Should -Be 254
    }
}

Describe 'New-ScanResult' {
    It 'creates a scan result object with expected properties' {
        $result = New-ScanResult '10.0.0.1'
        $result.Ip | Should -Be '10.0.0.1'
        $result.PingReply | Should -Be $false
        $result.TcpOpen | Should -Be $false
        $result.Banner | Should -BeNullOrEmpty
        $result.IsCisco | Should -Be $false
        $result.Selected | Should -Be $false
    }
}

Describe 'Test-CiscoBanner' {
    It 'identifies Cisco SSH banner' {
        Test-CiscoBanner 'SSH-2.0-Cisco-1.25' | Should -BeTrue
    }

    It 'identifies Cisco IOS-XE banner' {
        Test-CiscoBanner 'SSH-1.99-Cisco-1.25' | Should -BeTrue
    }

    It 'rejects OpenSSH banner' {
        Test-CiscoBanner 'SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.1' | Should -BeFalse
    }

    It 'rejects empty string' {
        Test-CiscoBanner '' | Should -BeFalse
    }

    It 'rejects null' {
        Test-CiscoBanner $null | Should -BeFalse
    }
}

Describe 'Start-NetworkScan / Step-NetworkScan integration' {
    BeforeAll {
        $script:listener = $null
        $script:listenerPort = 0
        try {
            $script:listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
            $script:listener.Start()
            $script:listenerPort = ([Net.IPEndPoint]$script:listener.LocalEndpoint).Port

            $script:acceptTask = $script:listener.AcceptTcpClientAsync()
        }
        catch {
            $script:listener = $null
        }
    }
    AfterAll {
        if ($script:listener) {
            $script:listener.Stop()
        }
    }

    It 'detects open TCP port on localhost' -Skip:(-not $script:listener) {
        $scanState = Start-NetworkScan @('127.0.0.1') $script:listenerPort 1500 1500
        $timeout = [datetime]::Now.AddSeconds(5)
        while (-not $scanState.Done -and [datetime]::Now -lt $timeout) {
            Step-NetworkScan $scanState
            Start-Sleep -Milliseconds 100
        }
        $scanState.Done | Should -BeTrue
        $scanState.Results.Count | Should -Be 1
        $scanState.Results[0].TcpOpen | Should -BeTrue
    }

    It 'detects closed TCP port' {
        $unusedPort = 19876
        $scanState = Start-NetworkScan @('127.0.0.1') $unusedPort 500 500
        $timeout = [datetime]::Now.AddSeconds(5)
        while (-not $scanState.Done -and [datetime]::Now -lt $timeout) {
            Step-NetworkScan $scanState
            Start-Sleep -Milliseconds 100
        }
        $scanState.Done | Should -BeTrue
        $scanState.Results[0].TcpOpen | Should -BeFalse
    }
}
