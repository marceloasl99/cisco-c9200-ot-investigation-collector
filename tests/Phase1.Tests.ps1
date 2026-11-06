BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    $ScriptPath  = Join-Path $ProjectRoot 'CiscoC9200-OT-Investigation.ps1'
    $FixtureDir  = Join-Path $PSScriptRoot 'fixtures'

    # Parse the script AST and extract functions without running main
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    $funcDefs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)

    # Set module-level variables the functions depend on
    $script:FocusVlans = @()
    $script:LostMacs   = @()
    $script:IncludeSanitizedRunningConfig = $false
    $script:IncludeShowTechSupport        = $false

    foreach ($f in $funcDefs) {
        if ($f.Name -in 'Convert-ToCiscoMac', 'New-CiscoCommandList', 'Quote-ProcessArgument', 'Test-TcpPort') {
            . ([scriptblock]::Create($f.Extent.Text))
        }
    }

    function Load-GoldenFixture {
        param([string]$Name)
        $path = Join-Path $FixtureDir "golden_commands_${Name}.json"
        $raw  = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        return @(($raw | ConvertFrom-Json))
    }
}

Describe 'Golden command lists — existing behavior' {
    Context 'Fast mode (no VLANs, no MACs)' {
        BeforeAll {
            $script:FocusVlans = @()
            $script:LostMacs   = @()
            $script:IncludeSanitizedRunningConfig = $false
            $script:IncludeShowTechSupport = $false
            $actual  = New-CiscoCommandList -CollectionMode 'Fast'
            $golden  = Load-GoldenFixture 'Fast'
        }
        It 'produces the same number of commands' {
            $actual.Count | Should -Be $golden.Count
        }
        It 'matches every command in order' {
            for ($i = 0; $i -lt $golden.Count; $i++) {
                $actual[$i] | Should -Be $golden[$i] -Because "command at index $i"
            }
        }
        It 'starts with terminal length 0' {
            $actual[0] | Should -Be 'terminal length 0'
        }
        It 'ends with exit' {
            $actual[-1] | Should -Be 'exit'
        }
    }

    Context 'Standard mode (no VLANs, no MACs)' {
        BeforeAll {
            $script:FocusVlans = @()
            $script:LostMacs   = @()
            $script:IncludeSanitizedRunningConfig = $false
            $script:IncludeShowTechSupport = $false
            $actual  = New-CiscoCommandList -CollectionMode 'Standard'
            $golden  = Load-GoldenFixture 'Standard'
        }
        It 'produces the same number of commands' {
            $actual.Count | Should -Be $golden.Count
        }
        It 'matches every command in order' {
            for ($i = 0; $i -lt $golden.Count; $i++) {
                $actual[$i] | Should -Be $golden[$i] -Because "command at index $i"
            }
        }
        It 'includes detailed commands not in Fast' {
            $actual | Should -Contain 'show spanning-tree detail'
            $actual | Should -Contain 'show interfaces'
        }
    }

    Context 'Deep mode (no VLANs, no MACs)' {
        BeforeAll {
            $script:FocusVlans = @()
            $script:LostMacs   = @()
            $script:IncludeSanitizedRunningConfig = $true
            $script:IncludeShowTechSupport = $false
            $actual  = New-CiscoCommandList -CollectionMode 'Deep'
            $golden  = Load-GoldenFixture 'Deep'
        }
        It 'produces the same number of commands' {
            $actual.Count | Should -Be $golden.Count
        }
        It 'matches every command in order' {
            for ($i = 0; $i -lt $golden.Count; $i++) {
                $actual[$i] | Should -Be $golden[$i] -Because "command at index $i"
            }
        }
        It 'includes sanitized running config' {
            $actual | Should -Contain 'show running-config | exclude password|secret|community|key-string|authentication-key|privacy-key'
        }
    }

    Context 'Standard with VLANs and MACs' {
        BeforeAll {
            $script:FocusVlans = @(31, 32, 33)
            $script:LostMacs   = @('28:63:36:61:66:87')
            $script:IncludeSanitizedRunningConfig = $false
            $script:IncludeShowTechSupport = $false
            $actual  = New-CiscoCommandList -CollectionMode 'Standard'
            $golden  = Load-GoldenFixture 'Standard_WithVlanMac'
        }
        It 'produces the same number of commands' {
            $actual.Count | Should -Be $golden.Count
        }
        It 'includes per-VLAN STP commands' {
            $actual | Should -Contain 'show spanning-tree vlan 31 detail'
            $actual | Should -Contain 'show spanning-tree vlan 32 detail'
            $actual | Should -Contain 'show spanning-tree vlan 33 detail'
        }
        It 'includes per-VLAN MAC table' {
            $actual | Should -Contain 'show mac address-table vlan 31'
        }
        It 'includes MAC address lookup' {
            $actual | Should -Contain 'show mac address-table address 2863.3661.6687'
        }
    }
}

Describe 'Convert-ToCiscoMac' {
    It 'converts colon-separated MAC' {
        Convert-ToCiscoMac '28:63:36:61:66:87' | Should -Be '2863.3661.6687'
    }
    It 'converts dash-separated MAC' {
        Convert-ToCiscoMac '28-63-36-61-66-87' | Should -Be '2863.3661.6687'
    }
    It 'passes through Cisco format' {
        Convert-ToCiscoMac '2863.3661.6687' | Should -Be '2863.3661.6687'
    }
    It 'converts uppercase' {
        Convert-ToCiscoMac 'AA:BB:CC:DD:EE:FF' | Should -Be 'aabb.ccdd.eeff'
    }
    It 'throws on invalid MAC' {
        { Convert-ToCiscoMac '12:34' } | Should -Throw '*Invalid MAC*'
    }
}

Describe 'Quote-ProcessArgument' {
    It 'quotes a simple string' {
        Quote-ProcessArgument 'hello' | Should -Be '"hello"'
    }
    It 'escapes embedded quotes' {
        Quote-ProcessArgument 'say "hi"' | Should -Be '"say \"hi\""'
    }
    It 'handles null' {
        Quote-ProcessArgument $null | Should -Be '""'
    }
}

Describe 'Bug: $args shadowing in Invoke-SwitchCollection' {
    It 'Invoke-SwitchCollection must not use $args as a variable name' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        $funcDefs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
        $invokeFn = $funcDefs | Where-Object { $_.Name -eq 'Invoke-SwitchCollection' }
        $invokeFn | Should -Not -BeNullOrEmpty

        $varExprs = $invokeFn.FindAll({ param($n)
            $n -is [Management.Automation.Language.VariableExpressionAst] -and
            $n.VariablePath.UserPath -eq 'args'
        }, $true)

        $varExprs.Count | Should -Be 0 -Because '$args is a PS automatic variable and must not be shadowed'
    }
}

Describe 'Bug: plink detection must use --help not -h' {
    It 'script must not contain "plink -h" or "plink.exe -h" for help detection' {
        $content = Get-Content -LiteralPath $ScriptPath -Raw
        $content | Should -Not -Match 'plink[^-]*-h\b(?!ost)' -Because 'plink 0.84 treats -h as unknown option'
    }
}

Describe 'Bug: show logging | last 300 not confirmed on C9200' {
    It 'script must not contain "show logging | last"' {
        $content = Get-Content -LiteralPath $ScriptPath -Raw
        $content | Should -Not -Match 'show logging \| last' -Because '| last modifier is not confirmed on C9200 IOS-XE'
    }
}
