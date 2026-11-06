BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/Commands.ps1')
    . (Join-Path $ProjectRoot 'lib/Settings.ps1')
    . (Join-Path $ProjectRoot 'lib/LogFilter.ps1')
    . (Join-Path $ProjectRoot 'lib/Report.ps1')
    . (Join-Path $ProjectRoot 'lib/Network.ps1')
    . (Join-Path $ProjectRoot 'lib/HostKeys.ps1')
    . (Join-Path $ProjectRoot 'lib/Plink.ps1')
    . (Join-Path $ProjectRoot 'lib/Collector.ps1')

    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
}

Describe 'MainWindow.xaml' {
    BeforeAll {
        $xamlPath = Join-Path $ProjectRoot 'gui\MainWindow.xaml'
        $xamlContent = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
        $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($xamlContent))
        $script:window = [Windows.Markup.XamlReader]::Load($reader)
    }
    AfterAll {
        if ($script:window) { $script:window.Close() }
    }

    It 'loads without error' {
        $script:window | Should -Not -BeNullOrEmpty
    }

    It 'has expected title' {
        $script:window.Title | Should -Be 'Cisco C9200 OT Investigation Collector'
    }

    It 'has all named controls in Targets tab' {
        $names = @('dgSwitches','btnAddSwitch','btnRemoveSwitch','txtScanRange','btnScan','pbScan','dgScanResults')
        foreach ($n in $names) {
            $script:window.FindName($n) | Should -Not -BeNullOrEmpty -Because "control $n should exist"
        }
    }

    It 'has all named controls in Collection tab' {
        $names = @(
            'chkIdentity','chkHealth','chkInterfaces','chkLayer2','chkLayer3','chkSecurity',
            'chkConfigExtracts','chkLogs','chkDetailed','chkSanitizedConfig',
            'chkLogBuffer','chkLogReboot','cmbLogDays','txtCustomDays',
            'rbVlanAll','rbVlanOnly','txtVlans','txtMacs'
        )
        foreach ($n in $names) {
            $script:window.FindName($n) | Should -Not -BeNullOrEmpty -Because "control $n should exist"
        }
    }

    It 'has all named controls in Connection tab' {
        $names = @(
            'txtUsername','txtPassword','txtPlinkPath','btnBrowsePlink','lblPwFileStatus',
            'txtMaxParallel','txtTimeout','txtConnectTimeout','cmbHostKeyPolicy',
            'txtReportDir','btnBrowseReport'
        )
        foreach ($n in $names) {
            $script:window.FindName($n) | Should -Not -BeNullOrEmpty -Because "control $n should exist"
        }
    }

    It 'has all named controls in Run & Monitor tab' {
        $names = @(
            'btnStart','btnCancel','btnOpenReport','btnOpenFolder',
            'lblRunStatus','pbRun','dgRunProgress','txtEventLog'
        )
        foreach ($n in $names) {
            $script:window.FindName($n) | Should -Not -BeNullOrEmpty -Because "control $n should exist"
        }
    }

    It 'has preset controls' {
        $names = @('cmbPreset','btnSavePreset','btnSavePresetAs','btnDeletePreset','lblPresetModified')
        foreach ($n in $names) {
            $script:window.FindName($n) | Should -Not -BeNullOrEmpty -Because "control $n should exist"
        }
    }

    It 'has 4 tabs' {
        $tabControl = $script:window.FindName('tabMain')
        $tabControl.Items.Count | Should -Be 4
    }
}
