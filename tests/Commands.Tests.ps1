BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/Commands.ps1')
}

Describe 'New-CommandCatalog' {
    It 'returns a hashtable with category keys' {
        $catalog = New-CommandCatalog
        $catalog | Should -BeOfType [hashtable]
        $catalog.Keys | Should -Contain 'Identity'
        $catalog.Keys | Should -Contain 'Health'
        $catalog.Keys | Should -Contain 'Interfaces'
        $catalog.Keys | Should -Contain 'Layer2'
        $catalog.Keys | Should -Contain 'Layer3'
        $catalog.Keys | Should -Contain 'Security'
        $catalog.Keys | Should -Contain 'ConfigExtracts'
        $catalog.Keys | Should -Contain 'Logs'
        $catalog.Keys | Should -Contain 'Detailed'
        $catalog.Keys | Should -Contain 'SanitizedRunningConfig'
    }

    It 'every category value is a string array' {
        $catalog = New-CommandCatalog
        foreach ($key in $catalog.Keys) {
            $catalog[$key] | Should -BeOfType [string] -Because "category $key"
        }
    }

    It 'Identity includes show clock detail and show version' {
        $catalog = New-CommandCatalog
        $catalog['Identity'] | Should -Contain 'show clock detail'
        $catalog['Identity'] | Should -Contain 'show version'
    }

    It 'Logs includes show logging (not show logging | last 300)' {
        $catalog = New-CommandCatalog
        $catalog['Logs'] | Should -Contain 'show logging'
        $catalog['Logs'] | Should -Not -Contain 'show logging | last 300'
    }

    It 'Logs includes show logging onboard switch active uptime detail' {
        $catalog = New-CommandCatalog
        $catalog['Logs'] | Should -Contain 'show logging onboard switch active uptime detail'
    }
}

Describe 'Build-CommandList' {
    Context 'basic invocation with all categories' {
        BeforeAll {
            $params = @{
                Categories = @('Identity','Health','Interfaces','Layer2','Layer3','Security','ConfigExtracts','Logs')
                Vlans      = @()
                VlanMode   = 'All'
                Macs       = @()
                LogSources = @('Buffer')
            }
            $result = Build-CommandList @params
        }

        It 'starts with terminal length 0 and terminal width 511' {
            $result[0] | Should -Be 'terminal length 0'
            $result[1] | Should -Be 'terminal width 511'
        }

        It 'includes show clock detail early (always present)' {
            $result | Should -Contain 'show clock detail'
        }

        It 'ends with exit' {
            $result[-1] | Should -Be 'exit'
        }

        It 'includes show logging (Buffer source)' {
            $result | Should -Contain 'show logging'
        }

        It 'does not include RebootHistory when not selected' {
            $result | Should -Not -Contain 'show logging onboard switch active uptime detail'
        }
    }

    Context 'with RebootHistory log source' {
        It 'includes OBFL command' {
            $result = Build-CommandList -Categories @('Identity','Logs') -Vlans @() -VlanMode 'All' -Macs @() -LogSources @('Buffer','RebootHistory')
            $result | Should -Contain 'show logging onboard switch active uptime detail'
        }
    }

    Context 'VLAN mode Only with specific VLANs' {
        BeforeAll {
            $result = Build-CommandList -Categories @('Identity','Layer2') -Vlans @(10,20,30) -VlanMode 'Only' -Macs @() -LogSources @('Buffer')
        }

        It 'includes per-VLAN show vlan id commands' {
            $result | Should -Contain 'show vlan id 10'
            $result | Should -Contain 'show vlan id 20'
            $result | Should -Contain 'show vlan id 30'
        }

        It 'includes per-VLAN STP detail' {
            $result | Should -Contain 'show spanning-tree vlan 10 detail'
        }

        It 'includes per-VLAN MAC table' {
            $result | Should -Contain 'show mac address-table vlan 10'
        }
    }

    Context 'VLAN mode All with focus VLANs' {
        It 'includes global commands plus per-VLAN commands' {
            $result = Build-CommandList -Categories @('Identity','Layer2') -Vlans @(31,32) -VlanMode 'All' -Macs @() -LogSources @('Buffer')
            $result | Should -Contain 'show mac address-table dynamic'
            $result | Should -Contain 'show vlan id 31'
            $result | Should -Contain 'show spanning-tree vlan 31 detail'
        }
    }

    Context 'MAC address lookup' {
        It 'generates MAC lookup commands' {
            $result = Build-CommandList -Categories @('Identity','Layer2','Layer3') -Vlans @() -VlanMode 'All' -Macs @('28:63:36:61:66:87') -LogSources @('Buffer')
            $result | Should -Contain 'show mac address-table address 2863.3661.6687'
            $result | Should -Contain 'show ip arp | include 2863.3661.6687'
        }
    }

    Context 'Detailed and SanitizedRunningConfig categories' {
        It 'includes detailed commands when Detailed is selected' {
            $result = Build-CommandList -Categories @('Identity','Detailed') -Vlans @() -VlanMode 'All' -Macs @() -LogSources @('Buffer')
            $result | Should -Contain 'show spanning-tree detail'
            $result | Should -Contain 'show interfaces'
        }

        It 'includes sanitized running config when selected' {
            $result = Build-CommandList -Categories @('Identity','SanitizedRunningConfig') -Vlans @() -VlanMode 'All' -Macs @() -LogSources @('Buffer')
            $result | Should -Contain 'show running-config | exclude password|secret|community|key-string|authentication-key|privacy-key'
        }
    }
}

Describe 'ConvertTo-CiscoMac' {
    It 'converts colon format' {
        ConvertTo-CiscoMac '28:63:36:61:66:87' | Should -Be '2863.3661.6687'
    }
    It 'converts dash format' {
        ConvertTo-CiscoMac 'AA-BB-CC-DD-EE-FF' | Should -Be 'aabb.ccdd.eeff'
    }
    It 'passes Cisco format' {
        ConvertTo-CiscoMac 'aabb.ccdd.eeff' | Should -Be 'aabb.ccdd.eeff'
    }
    It 'rejects short MAC' {
        { ConvertTo-CiscoMac '12:34' } | Should -Throw '*Invalid MAC*'
    }
}

Describe 'Parse-VlanList' {
    It 'parses comma-separated VLANs' {
        $result = Parse-VlanList '10,20,30'
        $result | Should -Be @(10, 20, 30)
    }
    It 'parses ranges' {
        $result = Parse-VlanList '10-13'
        $result | Should -Be @(10, 11, 12, 13)
    }
    It 'parses mixed comma and ranges' {
        $result = Parse-VlanList '10,20-22,30'
        $result | Should -Be @(10, 20, 21, 22, 30)
    }
    It 'rejects VLAN 0' {
        { Parse-VlanList '0' } | Should -Throw
    }
    It 'rejects VLAN above 4094' {
        { Parse-VlanList '4095' } | Should -Throw
    }
    It 'enforces max 64 VLANs' {
        { Parse-VlanList ((1..65) -join ',') } | Should -Throw '*64*'
    }
    It 'removes duplicates and sorts' {
        $result = Parse-VlanList '30,10,20,10'
        $result | Should -Be @(10, 20, 30)
    }
}

Describe 'Test-CommandAllowlist' {
    It 'allows terminal length' {
        Test-CommandAllowlist 'terminal length 0' | Should -BeTrue
    }
    It 'allows terminal width' {
        Test-CommandAllowlist 'terminal width 511' | Should -BeTrue
    }
    It 'allows show commands' {
        Test-CommandAllowlist 'show version' | Should -BeTrue
        Test-CommandAllowlist 'show running-config | section ^interface' | Should -BeTrue
    }
    It 'allows exit' {
        Test-CommandAllowlist 'exit' | Should -BeTrue
    }
    It 'rejects configure terminal' {
        Test-CommandAllowlist 'configure terminal' | Should -BeFalse
    }
    It 'rejects show with redirect to flash' {
        Test-CommandAllowlist 'show version | redirect flash:test.txt' | Should -BeFalse
    }
    It 'rejects show with tee' {
        Test-CommandAllowlist 'show version | tee flash:test.txt' | Should -BeFalse
    }
    It 'rejects show with append' {
        Test-CommandAllowlist 'show version | append flash:test.txt' | Should -BeFalse
    }
    It 'rejects arbitrary commands' {
        Test-CommandAllowlist 'delete flash:startup-config' | Should -BeFalse
    }
}

Describe 'Get-LegacyModeCategories' {
    It 'Fast mode returns base categories' {
        $cats = Get-LegacyModeCategories 'Fast'
        $cats | Should -Contain 'Identity'
        $cats | Should -Contain 'Health'
        $cats | Should -Not -Contain 'Detailed'
        $cats | Should -Not -Contain 'SanitizedRunningConfig'
    }
    It 'Standard mode includes Detailed' {
        $cats = Get-LegacyModeCategories 'Standard'
        $cats | Should -Contain 'Detailed'
        $cats | Should -Not -Contain 'SanitizedRunningConfig'
    }
    It 'Deep mode includes SanitizedRunningConfig' {
        $cats = Get-LegacyModeCategories 'Deep'
        $cats | Should -Contain 'Detailed'
        $cats | Should -Contain 'SanitizedRunningConfig'
    }
}
