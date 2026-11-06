BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/Settings.ps1')
    $FixtureDir = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Get-DefaultSettings' {
    BeforeAll {
        $defaults = Get-DefaultSettings
    }

    It 'returns a hashtable' {
        $defaults | Should -BeOfType [hashtable]
    }

    It 'has connection section with expected keys' {
        $defaults.connection | Should -Not -BeNullOrEmpty
        $defaults.connection.username | Should -Be 'network-admin'
        $defaults.connection.sshPort | Should -Be 22
        $defaults.connection.maxParallel | Should -Be 4
        $defaults.connection.perSwitchTimeoutSeconds | Should -Be 175
        $defaults.connection.connectTimeoutSeconds | Should -Be 5
        $defaults.connection.hostKeyPolicy | Should -Be 'AutoAccept'
        $defaults.connection.onHostKeyChange | Should -Be 'Block'
    }

    It 'has targets section' {
        $defaults.targets | Should -Not -BeNullOrEmpty
        , $defaults.targets.switches | Should -BeOfType [array]
        $defaults.targets.scanRanges | Should -Not -BeNullOrEmpty
        $defaults.targets.maxScanHosts | Should -Be 1024
    }

    It 'has presets array' {
        $defaults.presets | Should -Not -BeNullOrEmpty
        $defaults.presets.Count | Should -BeGreaterOrEqual 6
    }

    It 'has report section' {
        $defaults.report | Should -Not -BeNullOrEmpty
        $defaults.report.directory | Should -Be '.'
    }
}

Describe 'Merge-Settings' {
    It 'returns defaults when user settings are empty' {
        $defaults = Get-DefaultSettings
        $merged = Merge-Settings $defaults @{}
        $merged.connection.maxParallel | Should -Be 4
    }

    It 'overrides scalar values from user' {
        $defaults = Get-DefaultSettings
        $user = @{ connection = @{ maxParallel = 8 } }
        $merged = Merge-Settings $defaults $user
        $merged.connection.maxParallel | Should -Be 8
    }

    It 'preserves default keys not in user settings' {
        $defaults = Get-DefaultSettings
        $user = @{ connection = @{ maxParallel = 8 } }
        $merged = Merge-Settings $defaults $user
        $merged.connection.username | Should -Be 'network-admin'
        $merged.connection.sshPort | Should -Be 22
    }

    It 'replaces arrays entirely (not merging)' {
        $defaults = Get-DefaultSettings
        $user = @{ targets = @{ scanRanges = @('10.0.0.0/24') } }
        $merged = Merge-Settings $defaults $user
        $merged.targets.scanRanges | Should -Be @('10.0.0.0/24')
    }
}

Describe 'Test-Settings' {
    It 'passes with valid defaults' {
        $defaults = Get-DefaultSettings
        $errors = Test-Settings $defaults
        $errors | Should -BeNullOrEmpty
    }

    It 'reports error for maxParallel out of range' {
        $s = Get-DefaultSettings
        $s.connection.maxParallel = 0
        $errors = Test-Settings $s
        $errors | Should -Not -BeNullOrEmpty
        $errors | Should -Match 'maxParallel'
    }

    It 'reports error for invalid hostKeyPolicy' {
        $s = Get-DefaultSettings
        $s.connection.hostKeyPolicy = 'Whatever'
        $errors = Test-Settings $s
        $errors | Should -Not -BeNullOrEmpty
        $errors | Should -Match 'hostKeyPolicy'
    }

    It 'reports error for perSwitchTimeoutSeconds out of range' {
        $s = Get-DefaultSettings
        $s.connection.perSwitchTimeoutSeconds = 10
        $errors = Test-Settings $s
        $errors | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertTo-SettingsJson / ConvertFrom-SettingsJson roundtrip' {
    It 'roundtrips without data loss' {
        $original = Get-DefaultSettings
        $json = ConvertTo-SettingsJson $original
        $restored = ConvertFrom-SettingsJson $json
        $restored.connection.maxParallel | Should -Be 4
        $restored.connection.hostKeyPolicy | Should -Be 'AutoAccept'
        $restored.presets.Count | Should -Be $original.presets.Count
    }
}

Describe 'Save-Settings and Import-Settings roundtrip' {
    BeforeAll {
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) "test_settings_$(Get-Random).json"
    }
    AfterAll {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    It 'saves and loads settings identically' {
        $original = Get-DefaultSettings
        $original.connection.maxParallel = 6
        Save-Settings $original $tempFile
        $loaded = Import-Settings $tempFile
        $loaded.connection.maxParallel | Should -Be 6
        $loaded.connection.username | Should -Be 'network-admin'
    }

    It 'overwrites an existing settings file' {
        $s = Get-DefaultSettings
        $s.connection.maxParallel = 3
        Save-Settings $s $tempFile
        $s.connection.maxParallel = 7
        Save-Settings $s $tempFile
        (Import-Settings $tempFile).connection.maxParallel | Should -Be 7
        Test-Path -LiteralPath ($tempFile + '.tmp') | Should -BeFalse
    }
}

Describe 'Get-PresetByName' {
    It 'finds Quick triage preset' {
        $settings = Get-DefaultSettings
        $preset = Get-PresetByName $settings 'Quick triage (3 days)'
        $preset | Should -Not -BeNullOrEmpty
        $preset.name | Should -Be 'Quick triage (3 days)'
    }

    It 'returns null for unknown preset' {
        $settings = Get-DefaultSettings
        $preset = Get-PresetByName $settings 'Nonexistent'
        $preset | Should -BeNullOrEmpty
    }
}

Describe 'Get-LegacyModePreset' {
    It 'Fast maps to Quick triage categories' {
        $preset = Get-LegacyModePreset 'Fast'
        $preset.categories | Should -Not -BeNullOrEmpty
        $preset.categories | Should -Not -Contain 'Detailed'
    }

    It 'Deep maps to categories including SanitizedRunningConfig' {
        $preset = Get-LegacyModePreset 'Deep'
        $preset.categories | Should -Contain 'SanitizedRunningConfig'
    }
}

Describe 'Preset structure' {
    It 'every built-in preset has required fields' {
        $settings = Get-DefaultSettings
        foreach ($preset in $settings.presets) {
            $preset.name | Should -Not -BeNullOrEmpty -Because "preset at index $($settings.presets.IndexOf($preset))"
            $preset.categories | Should -Not -BeNullOrEmpty -Because "preset $($preset.name)"
        }
    }

    It 'VLAN focus preset has VlanMode=Only' {
        $settings = Get-DefaultSettings
        $vf = $settings.presets | Where-Object { $_.name -eq 'VLAN focus' }
        $vf | Should -Not -BeNullOrEmpty
        $vf.vlans.mode | Should -Be 'Only'
    }
}
