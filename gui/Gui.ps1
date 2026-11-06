Set-StrictMode -Version 2.0

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Show-CollectorGui {
    param(
        [string]$ScriptRoot,
        [hashtable]$Settings
    )

    $xamlPath = Join-Path $ScriptRoot 'gui\MainWindow.xaml'
    $xamlContent = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($xamlContent))
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $ctrl = @{}
    $controlNames = @(
        'rbModeSaved','rbModeScanStart','rbModeScanPick','rbModeDirect',
        'pnlSaved','pnlScan','pnlDirect','txtDirectIps','btnCollectNow','lblTargetHint',
        'cmbPreset','btnSavePreset','btnSavePresetAs','btnDeletePreset','lblPresetModified',
        'dgSwitches','btnAddSwitch','btnRemoveSwitch','txtScanRange','btnScan','pbScan','dgScanResults',
        'chkIdentity','chkHealth','chkInterfaces','chkLayer2','chkLayer3','chkSecurity',
        'chkConfigExtracts','chkLogs','chkDetailed','chkSanitizedConfig',
        'chkLogBuffer','chkLogReboot','cmbLogDays','txtCustomDays',
        'rbVlanAll','rbVlanOnly','txtVlans','txtMacs',
        'txtUsername','txtPassword','txtPlinkPath','btnBrowsePlink','lblPwFileStatus',
        'txtMaxParallel','txtTimeout','txtConnectTimeout','cmbHostKeyPolicy','txtReportDir','btnBrowseReport',
        'btnStart','btnCancel','btnOpenReport','btnOpenFolder','lblRunStatus','pbRun',
        'dgRunProgress','txtEventLog','tabMain'
    )
    foreach ($name in $controlNames) {
        $ctrl[$name] = $window.FindName($name)
    }

    $state = @{
        Settings       = $Settings
        ScriptRoot     = $ScriptRoot
        Modified       = $false
        ScanState      = $null
        CollectionRun  = $null
        Running        = $false
        ReportPath     = $null
        AutoStartAfterScan = $false
        LastTimerError = ''
        RunStart       = [datetime]::Now
        RunInfo        = @{}
        SwitchesData   = New-Object Collections.ObjectModel.ObservableCollection[PSObject]
        ScanData       = New-Object Collections.ObjectModel.ObservableCollection[PSObject]
        ProgressData   = New-Object Collections.ObjectModel.ObservableCollection[PSObject]
        KnownHostsStore = $null
    }

    $knownHostsPath = Join-Path $ScriptRoot 'known_hosts.json'
    $state.KnownHostsStore = Import-KnownHostsStore $knownHostsPath

    $ctrl['dgSwitches'].ItemsSource = $state.SwitchesData
    $ctrl['dgScanResults'].ItemsSource = $state.ScanData
    $ctrl['dgRunProgress'].ItemsSource = $state.ProgressData

    # --- Populate presets ---
    $presets = $Settings['presets']
    if ($presets) {
        foreach ($p in $presets) {
            $ctrl['cmbPreset'].Items.Add($p['name']) | Out-Null
        }
    }
    $lastUsed = $Settings['lastUsed']
    if ($lastUsed) {
        $idx = $ctrl['cmbPreset'].Items.IndexOf($lastUsed)
        if ($idx -ge 0) { $ctrl['cmbPreset'].SelectedIndex = $idx }
    }

    # --- Load settings into controls ---
    function Load-SettingsToControls {
        $conn = $Settings['connection']
        if ($conn) {
            $ctrl['txtUsername'].Text = [string]$conn['username']
            if ($conn['plinkPath']) { $ctrl['txtPlinkPath'].Text = [string]$conn['plinkPath'] }
            $ctrl['txtMaxParallel'].Text = [string]$conn['maxParallel']
            $ctrl['txtTimeout'].Text = [string]$conn['perSwitchTimeoutSeconds']
            $ctrl['txtConnectTimeout'].Text = [string]$conn['connectTimeoutSeconds']
            $hkp = [string]$conn['hostKeyPolicy']
            for ($i = 0; $i -lt $ctrl['cmbHostKeyPolicy'].Items.Count; $i++) {
                if ($ctrl['cmbHostKeyPolicy'].Items[$i].Content -eq $hkp) {
                    $ctrl['cmbHostKeyPolicy'].SelectedIndex = $i
                    break
                }
            }
        }
        $report = $Settings['report']
        if ($report -and $report['directory']) {
            $ctrl['txtReportDir'].Text = [string]$report['directory']
        }

        $targets = $Settings['targets']
        if ($targets -and $targets['switches']) {
            $state.SwitchesData.Clear()
            foreach ($sw in $targets['switches']) {
                $obj = New-Object PSObject -Property @{
                    Name    = [string]$sw['name']
                    Ip      = [string]$sw['ip']
                    Enabled = [bool]$sw['enabled']
                }
                $state.SwitchesData.Add($obj)
            }
        }
        if ($targets -and $targets['scanRanges']) {
            $ctrl['txtScanRange'].Text = ($targets['scanRanges'] -join ', ')
        }
    }

    function Apply-PresetToControls {
        param([hashtable]$Preset)
        $cats = $Preset['categories']
        if (-not $cats) { $cats = @() }
        $ctrl['chkIdentity'].IsChecked = ($cats -contains 'Identity')
        $ctrl['chkHealth'].IsChecked = ($cats -contains 'Health')
        $ctrl['chkInterfaces'].IsChecked = ($cats -contains 'Interfaces')
        $ctrl['chkLayer2'].IsChecked = ($cats -contains 'Layer2')
        $ctrl['chkLayer3'].IsChecked = ($cats -contains 'Layer3')
        $ctrl['chkSecurity'].IsChecked = ($cats -contains 'Security')
        $ctrl['chkConfigExtracts'].IsChecked = ($cats -contains 'ConfigExtracts')
        $ctrl['chkLogs'].IsChecked = ($cats -contains 'Logs')
        $ctrl['chkDetailed'].IsChecked = ($cats -contains 'Detailed')
        $ctrl['chkSanitizedConfig'].IsChecked = ($cats -contains 'SanitizedRunningConfig')

        $logs = $Preset['logs']
        if ($logs) {
            $sources = $logs['sources']
            if (-not $sources) { $sources = @() }
            $ctrl['chkLogBuffer'].IsChecked = ($sources -contains 'Buffer')
            $ctrl['chkLogReboot'].IsChecked = ($sources -contains 'RebootHistory')
            $days = $logs['days']
            $found = $false
            for ($i = 0; $i -lt $ctrl['cmbLogDays'].Items.Count; $i++) {
                if ([string]$ctrl['cmbLogDays'].Items[$i].Tag -eq [string]$days) {
                    $ctrl['cmbLogDays'].SelectedIndex = $i
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                for ($i = 0; $i -lt $ctrl['cmbLogDays'].Items.Count; $i++) {
                    if ([string]$ctrl['cmbLogDays'].Items[$i].Tag -eq '-1') {
                        $ctrl['cmbLogDays'].SelectedIndex = $i
                        break
                    }
                }
                $ctrl['txtCustomDays'].Text = [string]$days
                $ctrl['txtCustomDays'].Visibility = 'Visible'
            }
        }

        $vlans = $Preset['vlans']
        if ($vlans) {
            if ($vlans['mode'] -eq 'Only') {
                $ctrl['rbVlanOnly'].IsChecked = $true
                $ctrl['txtVlans'].IsEnabled = $true
            } else {
                $ctrl['rbVlanAll'].IsChecked = $true
                $ctrl['txtVlans'].IsEnabled = $false
            }
            if ($vlans['list']) {
                $ctrl['txtVlans'].Text = ($vlans['list'] -join ', ')
            }
        }

        $macs = $Preset['macs']
        if ($macs) {
            $ctrl['txtMacs'].Text = ($macs -join ', ')
        } else {
            $ctrl['txtMacs'].Text = ''
        }
    }

    Load-SettingsToControls

    if ($ctrl['cmbPreset'].SelectedIndex -ge 0 -and $presets) {
        $selected = $ctrl['cmbPreset'].SelectedItem
        foreach ($p in $presets) {
            if ($p['name'] -eq $selected) {
                Apply-PresetToControls $p
                break
            }
        }
    }

    # --- Event log helper ---
    function Write-EventLog {
        param([string]$Message)
        $ts = (Get-Date).ToString('HH:mm:ss')
        $ctrl['txtEventLog'].AppendText("$ts  $Message`r`n")
        $ctrl['txtEventLog'].ScrollToEnd()
    }

    # --- Preset selection ---
    $ctrl['cmbPreset'].Add_SelectionChanged({
        $selected = $ctrl['cmbPreset'].SelectedItem
        if ($null -eq $selected) { return }
        foreach ($p in $Settings['presets']) {
            if ($p['name'] -eq $selected) {
                Apply-PresetToControls $p
                $ctrl['lblPresetModified'].Visibility = 'Collapsed'
                $state.Modified = $false
                break
            }
        }
    })

    # --- VLAN radio buttons ---
    $ctrl['rbVlanOnly'].Add_Checked({ $ctrl['txtVlans'].IsEnabled = $true })
    $ctrl['rbVlanAll'].Add_Checked({ $ctrl['txtVlans'].IsEnabled = $false })

    # --- Custom days visibility ---
    $ctrl['cmbLogDays'].Add_SelectionChanged({
        $sel = $ctrl['cmbLogDays'].SelectedItem
        if ($null -ne $sel -and [string]$sel.Tag -eq '-1') {
            $ctrl['txtCustomDays'].Visibility = 'Visible'
        } else {
            $ctrl['txtCustomDays'].Visibility = 'Collapsed'
        }
    })

    # --- Add/Remove switches ---
    $ctrl['btnAddSwitch'].Add_Click({
        $obj = New-Object PSObject -Property @{
            Name    = 'New-Switch'
            Ip      = '10.0.0.1'
            Enabled = $true
        }
        $state.SwitchesData.Add($obj)
    })
    $ctrl['btnRemoveSwitch'].Add_Click({
        $sel = $ctrl['dgSwitches'].SelectedItem
        if ($null -ne $sel) { $state.SwitchesData.Remove($sel) | Out-Null }
    })

    # --- Browse buttons ---
    $ctrl['btnBrowsePlink'].Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'plink.exe|plink.exe|All Files|*.*'
        $dlg.Title = 'Select plink.exe'
        if ($dlg.ShowDialog($window)) {
            $ctrl['txtPlinkPath'].Text = $dlg.FileName
        }
    })
    $ctrl['btnBrowseReport'].Add_Click({
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select report directory'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $ctrl['txtReportDir'].Text = $dlg.SelectedPath
            }
        } catch {
            Write-EventLog "Could not open folder dialog: $($_.Exception.Message)"
        }
    })

    # --- Open folder ---
    $ctrl['btnOpenFolder'].Add_Click({
        $dir = Resolve-ReportDirectory $ctrl['txtReportDir'].Text $ScriptRoot
        if (Test-Path -LiteralPath $dir) {
            Start-Process explorer.exe -ArgumentList $dir
        }
    })

    # --- Target mode ---
    function Get-TargetMode {
        if ($ctrl['rbModeScanStart'].IsChecked) { return 'ScanStart' }
        if ($ctrl['rbModeDirect'].IsChecked) { return 'Direct' }
        if ($ctrl['rbModeSaved'].IsChecked) { return 'Saved' }
        return 'ScanPick'
    }

    function Update-ModeUi {
        $mode = Get-TargetMode
        $ctrl['pnlSaved'].Visibility = if ($mode -eq 'Saved') { 'Visible' } else { 'Collapsed' }
        $ctrl['pnlDirect'].Visibility = if ($mode -eq 'Direct') { 'Visible' } else { 'Collapsed' }
        $ctrl['pnlScan'].Visibility = if ($mode -in @('ScanPick', 'ScanStart')) { 'Visible' } else { 'Collapsed' }
        $ctrl['btnScan'].Visibility = if ($mode -eq 'ScanPick') { 'Visible' } else { 'Collapsed' }
        $ctrl['lblTargetHint'].Content = switch ($mode) {
            'ScanPick'  { 'Scan, tick the switches to collect, then click Collect now.' }
            'ScanStart' { 'Collect now scans the range and then collects from every Cisco switch found.' }
            'Direct'    { 'Collect now connects straight to the IP address(es) above.' }
            'Saved'     { 'Collect now uses the enabled switches in the saved list.' }
        }
    }

    function Test-RunPrerequisites {
        $errors = @()
        if (-not $ctrl['txtUsername'].Text.Trim()) { $errors += 'Username is required (Connection tab)' }
        if ($ctrl['txtPassword'].SecurePassword.Length -eq 0) { $errors += 'Password is required (Connection tab)' }
        if (-not (Resolve-PlinkPath -ConfigPath $ctrl['txtPlinkPath'].Text -ScriptRoot $ScriptRoot)) {
            $errors += 'plink.exe not found (Connection tab)'
        }
        return , $errors
    }

    # --- Scan ---
    function Start-ScanFromUi {
        param([bool]$AutoStart)
        if ($null -ne $state.ScanState -and -not $state.ScanState['Done']) {
            [Windows.MessageBox]::Show('A scan is already running.', 'Scan', 'OK', 'Information')
            return
        }
        $range = $ctrl['txtScanRange'].Text.Trim()
        if (-not $range) {
            [Windows.MessageBox]::Show('Enter a scan range (e.g. 10.0.0.0/24)', 'Scan', 'OK', 'Warning')
            return
        }
        $maxScan = 1024
        if ($Settings['targets'] -and $Settings['targets']['maxScanHosts']) { $maxScan = [int]$Settings['targets']['maxScanHosts'] }
        try {
            $hosts = Expand-IPv4Cidr $range -MaxHosts $maxScan
        } catch {
            [Windows.MessageBox]::Show("Invalid range: $($_.Exception.Message)", 'Scan', 'OK', 'Error')
            return
        }
        if ($AutoStart) {
            $problems = Test-RunPrerequisites
            if ($problems.Count -gt 0) {
                [Windows.MessageBox]::Show(($problems -join "`n"), 'Before scanning', 'OK', 'Warning')
                return
            }
        }
        $state.ScanData.Clear()
        $state.AutoStartAfterScan = $AutoStart
        $ctrl['dgScanResults'].Visibility = 'Visible'
        $ctrl['pbScan'].Visibility = 'Visible'
        $ctrl['pbScan'].Maximum = $hosts.Count
        $ctrl['pbScan'].Value = 0
        $ctrl['btnScan'].IsEnabled = $false
        $ctrl['btnCollectNow'].IsEnabled = $false
        Write-EventLog ("Scan started: {0} hosts in {1}" -f $hosts.Count, $range)

        $sshPort = 22
        $conn = $Settings['connection']
        if ($conn -and $conn['sshPort']) { $sshPort = [int]$conn['sshPort'] }
        $state.ScanState = Start-NetworkScan -Hosts $hosts -Port $sshPort
    }

    $ctrl['btnScan'].Add_Click({ Start-ScanFromUi -AutoStart $false })

    $ctrl['rbModeScanPick'].Add_Checked({ Update-ModeUi })
    $ctrl['rbModeScanStart'].Add_Checked({ Update-ModeUi })
    $ctrl['rbModeDirect'].Add_Checked({ Update-ModeUi })
    $ctrl['rbModeSaved'].Add_Checked({ Update-ModeUi })
    if ($state.SwitchesData.Count -gt 0) { $ctrl['rbModeSaved'].IsChecked = $true }
    Update-ModeUi

    # --- Collect selected categories ---
    function Get-SelectedCategories {
        $cats = @()
        if ($ctrl['chkIdentity'].IsChecked) { $cats += 'Identity' }
        if ($ctrl['chkHealth'].IsChecked) { $cats += 'Health' }
        if ($ctrl['chkInterfaces'].IsChecked) { $cats += 'Interfaces' }
        if ($ctrl['chkLayer2'].IsChecked) { $cats += 'Layer2' }
        if ($ctrl['chkLayer3'].IsChecked) { $cats += 'Layer3' }
        if ($ctrl['chkSecurity'].IsChecked) { $cats += 'Security' }
        if ($ctrl['chkConfigExtracts'].IsChecked) { $cats += 'ConfigExtracts' }
        if ($ctrl['chkLogs'].IsChecked) { $cats += 'Logs' }
        if ($ctrl['chkDetailed'].IsChecked) { $cats += 'Detailed' }
        if ($ctrl['chkSanitizedConfig'].IsChecked) { $cats += 'SanitizedRunningConfig' }
        return , $cats
    }

    function Get-SelectedLogDays {
        $sel = $ctrl['cmbLogDays'].SelectedItem
        if ($null -eq $sel) { return 30 }
        $tag = [string]$sel.Tag
        if ($tag -eq '-1') {
            $n = 0
            if ([int]::TryParse($ctrl['txtCustomDays'].Text, [ref]$n) -and $n -ge 0) { return $n }
            return 30
        }
        return [int]$tag
    }

    # --- Start collection ---
    function Start-Collection {
        param([array]$Targets)
        if ($state.Running) { return }

        $enabledSwitches = @($Targets)
        $errors = @()
        if ($enabledSwitches.Count -eq 0) { $errors += 'No switches selected' }
        $errors += Test-RunPrerequisites
        if ($errors.Count -gt 0) {
            [Windows.MessageBox]::Show(($errors -join "`n"), 'Validation', 'OK', 'Warning')
            return
        }
        $plinkPath = Resolve-PlinkPath -ConfigPath $ctrl['txtPlinkPath'].Text -ScriptRoot $ScriptRoot

        $cats = Get-SelectedCategories
        $logSources = @()
        if ($ctrl['chkLogBuffer'].IsChecked) { $logSources += 'Buffer' }
        if ($ctrl['chkLogReboot'].IsChecked) { $logSources += 'RebootHistory' }

        $vlanMode = 'All'
        [int[]]$vlanList = @()
        if ($ctrl['rbVlanOnly'].IsChecked) {
            $vlanMode = 'Only'
            try {
                [int[]]$vlanList = @(Parse-VlanList $ctrl['txtVlans'].Text)
            } catch {
                [Windows.MessageBox]::Show($_.Exception.Message, 'VLANs', 'OK', 'Warning')
                return
            }
            if ($vlanList.Count -eq 0) {
                [Windows.MessageBox]::Show('Enter at least one VLAN, or select "All".', 'VLANs', 'OK', 'Warning')
                return
            }
        }
        $macList = @()
        $macText = $ctrl['txtMacs'].Text.Trim()
        if ($macText) { $macList = @(($macText -split '[,;\s]+') | Where-Object { $_ -ne '' }) }
        try {
            foreach ($m in $macList) { ConvertTo-CiscoMac $m | Out-Null }
        } catch {
            [Windows.MessageBox]::Show($_.Exception.Message, 'MAC addresses', 'OK', 'Warning')
            return
        }

        $cmds = Build-CommandList -Categories $cats -Vlans $vlanList `
            -VlanMode $vlanMode -Macs $macList -LogSources $logSources

        $supportsPwFile = Test-PlinkPwFileSupport $plinkPath
        if ($supportsPwFile) {
            $ctrl['lblPwFileStatus'].Content = 'Supported (using -pwfile)'
        } else {
            $ctrl['lblPwFileStatus'].Content = 'Not supported (using -pw)'
        }

        # Resolve host keys
        $pinnedKeys = @{}
        $hostKeys = $Settings['hostKeys']
        if ($hostKeys) { $pinnedKeys = $hostKeys }
        $hostKeyResolutions = @{}
        foreach ($sw in $enabledSwitches) {
            $res = Resolve-HostKey -Ip $sw['Ip'] -PinnedKeys $pinnedKeys -KnownHostsStore $state.KnownHostsStore
            if ($res) { $hostKeyResolutions[$sw['Ip']] = $res }
        }

        $maxPar = 4
        try { $maxPar = [int]$ctrl['txtMaxParallel'].Text } catch {}
        if ($maxPar -lt 1) { $maxPar = 1 }
        if ($maxPar -gt 10) { $maxPar = 10 }

        $timeout = 175
        try { $timeout = [int]$ctrl['txtTimeout'].Text } catch {}

        $hostKeyPolicy = 'AutoAccept'
        if ($null -ne $ctrl['cmbHostKeyPolicy'].SelectedItem) { $hostKeyPolicy = [string]$ctrl['cmbHostKeyPolicy'].SelectedItem.Content }

        $state.CollectionRun = New-CollectionRun -Targets $enabledSwitches -Commands $cmds `
            -PlinkPath $plinkPath -Username $ctrl['txtUsername'].Text `
            -SecurePassword $ctrl['txtPassword'].SecurePassword `
            -SupportsPwFile $supportsPwFile -MaxParallel $maxPar `
            -PerSwitchTimeoutSeconds $timeout -HostKeyResolutions $hostKeyResolutions `
            -HostKeyPolicy $hostKeyPolicy -KnownHostsStore $state.KnownHostsStore

        $state.RunStart = [datetime]::Now
        $state.RunInfo = @{
            Username       = $ctrl['txtUsername'].Text
            PlinkPath      = $plinkPath
            SupportsPwFile = $supportsPwFile
            CommandCount   = $cmds.Count
            MaxParallel    = $maxPar
            LogDays        = (Get-SelectedLogDays)
            WantLogs       = (($cats -contains 'Logs') -and ($logSources -contains 'Buffer'))
        }
        $state.Running = $true
        $state.ProgressData.Clear()
        foreach ($sw in $state.CollectionRun.SwitchStates) {
            $obj = New-Object PSObject -Property @{
                Name   = $sw['Name']
                Ip     = $sw['Ip']
                Status = $sw['Status']
                Step   = ''
                Time   = ''
                KB     = ''
                Logs   = ''
            }
            $state.ProgressData.Add($obj)
        }

        $ctrl['btnStart'].IsEnabled = $false
        $ctrl['btnCollectNow'].IsEnabled = $false
        $ctrl['btnCancel'].IsEnabled = $true
        $ctrl['lblRunStatus'].Content = 'Collecting...'
        $ctrl['pbRun'].Maximum = $enabledSwitches.Count
        $ctrl['pbRun'].Value = 0
        $ctrl['tabMain'].SelectedIndex = 3

        Write-EventLog ("Collection started: {0} switches, {1} commands, max parallel {2}" -f `
            $enabledSwitches.Count, $cmds.Count, $maxPar)
    }

    function Invoke-CollectNow {
        if ($state.Running) {
            [Windows.MessageBox]::Show('A collection is already running.', 'Collect', 'OK', 'Information')
            return
        }
        $mode = Get-TargetMode
        $targets = @()
        switch ($mode) {
            'ScanStart' {
                Start-ScanFromUi -AutoStart $true
                return
            }
            'Direct' {
                try { $targets = @(Parse-DirectIpList $ctrl['txtDirectIps'].Text) }
                catch {
                    [Windows.MessageBox]::Show($_.Exception.Message, 'Switch IP address', 'OK', 'Warning')
                    return
                }
                if ($targets.Count -eq 0) {
                    [Windows.MessageBox]::Show('Type at least one switch IP address.', 'Switch IP address', 'OK', 'Warning')
                    return
                }
            }
            'ScanPick' {
                if ($null -ne $state.ScanState -and -not $state.ScanState['Done']) {
                    [Windows.MessageBox]::Show('Wait for the scan to finish.', 'Collect', 'OK', 'Information')
                    return
                }
                if ($state.ScanData.Count -eq 0) {
                    [Windows.MessageBox]::Show('Run a scan first, then tick the switches to collect.', 'Collect', 'OK', 'Information')
                    return
                }
                foreach ($row in $state.ScanData) {
                    if ($row.Use) { $targets += @{ Name = [string]$row.Ip; Ip = [string]$row.Ip } }
                }
            }
            'Saved' {
                foreach ($sw in $state.SwitchesData) {
                    if ($sw.Enabled) { $targets += @{ Name = [string]$sw.Name; Ip = [string]$sw.Ip } }
                }
            }
        }
        Start-Collection -Targets $targets
    }

    $ctrl['btnStart'].Add_Click({
        try { Invoke-CollectNow }
        catch { [Windows.MessageBox]::Show($_.Exception.Message, 'Collect', 'OK', 'Error') }
    })
    $ctrl['btnCollectNow'].Add_Click({
        try { Invoke-CollectNow }
        catch { [Windows.MessageBox]::Show($_.Exception.Message, 'Collect', 'OK', 'Error') }
    })

    # --- Cancel ---
    $ctrl['btnCancel'].Add_Click({
        if ($null -ne $state.ScanState -and -not $state.ScanState['Done']) {
            Stop-NetworkScan $state.ScanState
            $state.AutoStartAfterScan = $false
            $ctrl['btnScan'].IsEnabled = $true
            $ctrl['btnCollectNow'].IsEnabled = $true
            Write-EventLog 'Scan cancelled by user'
        }
        if ($state.Running -and $state.CollectionRun) {
            Stop-CollectionRun $state.CollectionRun
            $state.Running = $false
            $ctrl['btnStart'].IsEnabled = $true; $ctrl['btnCollectNow'].IsEnabled = $true
            $ctrl['btnCancel'].IsEnabled = $false
            $ctrl['lblRunStatus'].Content = 'Cancelled'
            Write-EventLog 'Collection cancelled by user'
        }
    })

    # --- Open report ---
    $ctrl['btnOpenReport'].Add_Click({
        if ($state.ReportPath -and (Test-Path -LiteralPath $state.ReportPath)) {
            Start-Process notepad.exe -ArgumentList $state.ReportPath
        }
    })

    # --- Timer tick (250ms) ---
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        try {
            # Scan tick
            if ($null -ne $state.ScanState -and -not $state.ScanState['Done']) {
                Step-NetworkScan $state.ScanState
                $completed = @($state.ScanState['Probes'] | Where-Object { $_['Completed'] }).Count
                $ctrl['pbScan'].Value = $completed

                if ($state.ScanState['Done']) {
                    $ctrl['btnScan'].IsEnabled = $true
                    $ctrl['btnCollectNow'].IsEnabled = $true
                    $state.ScanData.Clear()
                    $ciscoCount = 0
                    $sshCount = 0
                    foreach ($r in $state.ScanState['Results']) {
                        if (-not $r['PingReply'] -and -not $r['TcpOpen']) { continue }
                        $pingStr = if ($r['PingReply']) { 'Yes' } else { 'No' }
                        $tcpStr = if ($r['TcpOpen']) { 'Open' } else { 'Closed' }
                        $bannerStr = if ($r['Banner']) { $r['Banner'] } else { '' }
                        $ciscoStr = if ($r['IsCisco']) { 'Yes'; $ciscoCount++ } else { 'No' }
                        if ($r['TcpOpen']) { $sshCount++ }
                        $obj = New-Object PSObject -Property @{
                            Ip     = $r['Ip']
                            Ping   = $pingStr
                            Tcp    = $tcpStr
                            Banner = $bannerStr
                            Cisco  = $ciscoStr
                            Use    = [bool]$r['IsCisco']
                        }
                        $state.ScanData.Add($obj)
                    }
                    Write-EventLog ("Scan finished: {0} probed, {1} SSH open, {2} Cisco" -f `
                        $state.ScanState['Results'].Count, $sshCount, $ciscoCount)

                    if ($state.AutoStartAfterScan) {
                        $state.AutoStartAfterScan = $false
                        $found = @(Get-CiscoScanTargets $state.ScanState['Results'])
                        if ($found.Count -eq 0) {
                            Write-EventLog 'No Cisco SSH switches found; nothing to collect.'
                            [Windows.MessageBox]::Show('The scan found no Cisco SSH switches in that range.', 'Scan', 'OK', 'Information')
                        } else {
                            Start-Collection -Targets $found
                        }
                    }
                }
            }

            # Collection tick
            if ($state.Running -and $null -ne $state.CollectionRun) {
                Step-CollectionRun $state.CollectionRun
                $doneCount = 0
                for ($i = 0; $i -lt $state.CollectionRun.SwitchStates.Count; $i++) {
                    $sw = $state.CollectionRun.SwitchStates[$i]
                    if ($i -lt $state.ProgressData.Count) {
                        $pd = $state.ProgressData[$i]
                        $pd.Status = $sw['Status']
                        if ($sw['Started']) {
                            $elapsed = ([datetime]::Now - $sw['Started']).TotalSeconds
                            $pd.Time = "{0:N0}s" -f $elapsed
                        }
                        $kb = [math]::Round($sw['BytesRead'] / 1024, 1)
                        $pd.KB = if ($kb -gt 0) { "{0:N1}" -f $kb } else { '' }
                    }
                    if ($sw['Status'] -notin @('Queued','Collecting')) { $doneCount++ }
                }
                $ctrl['pbRun'].Value = $doneCount
                $running = @($state.CollectionRun.SwitchStates | Where-Object { $_['Status'] -eq 'Collecting' }).Count
                $queued = @($state.CollectionRun.SwitchStates | Where-Object { $_['Status'] -eq 'Queued' }).Count
                $ctrl['lblRunStatus'].Content = "Collecting: $running running, $queued queued, $doneCount done"

                $ctrl['dgRunProgress'].Items.Refresh()

                if ($state.CollectionRun.Done) {
                    $state.Running = $false
                    $ctrl['btnStart'].IsEnabled = $true; $ctrl['btnCollectNow'].IsEnabled = $true
                    $ctrl['btnCancel'].IsEnabled = $false

                    # Build report
                    try {
                        $reportDir = Resolve-ReportDirectory $ctrl['txtReportDir'].Text $ScriptRoot
                        [IO.Directory]::CreateDirectory($reportDir) | Out-Null
                        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
                        $reportName = "Cisco_C9200_OT_Investigation_$stamp.txt"
                        $reportPath = Join-Path $reportDir $reportName
                        $state.ReportPath = $reportPath

                        $logDays = [int]$state.RunInfo['LogDays']

                        $presetName = ''
                        if ($ctrl['cmbPreset'].SelectedItem) { $presetName = [string]$ctrl['cmbPreset'].SelectedItem }

                        $runEnd = [datetime]::Now
                        $header = New-ReportHeader -Params @{
                            StartTime      = $state.RunStart
                            Username       = $state.RunInfo['Username']
                            PresetName     = $presetName
                            SwitchCount    = $state.CollectionRun.SwitchStates.Count
                            PlinkPath      = $state.RunInfo['PlinkPath']
                            SupportsPwFile = $state.RunInfo['SupportsPwFile']
                            CommandCount   = $state.RunInfo['CommandCount']
                            MaxParallel    = $state.RunInfo['MaxParallel']
                        }

                        $blocks = @()
                        $summaryRows = @()
                        foreach ($sw in $state.CollectionRun.SwitchStates) {
                            $started = if ($sw['Started']) { $sw['Started'] } else { $state.RunStart }
                            $finished = if ($sw['Finished']) { $sw['Finished'] } else { $runEnd }
                            $analysis = $null
                            if ($state.RunInfo['WantLogs'] -and $sw['Status'] -in @('Done', 'TimedOut') -and $sw['StdOut']) {
                                $analysis = New-LogAnalysis -Output ([string]$sw['StdOut']) -Days $logDays -FallbackDate $started
                            }
                            $notes = @()
                            if ($sw['Note']) { $notes += [string]$sw['Note'] }
                            if ($sw['TimedOut']) { $notes += 'timed out' }
                            $blocks += New-SwitchBlock -Params @{
                                Name           = $sw['Name']
                                Ip             = $sw['Ip']
                                Started        = $started
                                Finished       = $finished
                                HostKey        = $sw['HostKey']
                                KeySource      = $sw['KeySource']
                                Note           = ($notes -join '; ')
                                LogSummary     = if ($analysis) { $analysis.Summary } else { '' }
                                LogEntriesText = if ($analysis) { $analysis.EntriesText } else { '' }
                                LogDays        = $logDays
                                StdOut         = [string]$sw['StdOut']
                                StdErr         = [string]$sw['StdErr']
                                ExitCode       = $sw['ExitCode']
                                TimedOut       = $sw['TimedOut']
                            }
                            $summaryRows += @{
                                Name        = $sw['Name']
                                Ip          = $sw['Ip']
                                Status      = $sw['Status']
                                Duration    = ('{0:N0}s' -f ($finished - $started).TotalSeconds)
                                KB          = ('{0:N1}' -f ($sw['BytesRead'] / 1024))
                                LogCoverage = if ($analysis) { $analysis.CoverageShort } else { '' }
                                Notes       = ($notes -join '; ')
                            }
                        }

                        $summary = New-CollectionSummary -SwitchResults $summaryRows `
                            -RunStart $state.RunStart -RunEnd $runEnd

                        $utf8NoBom = New-Object Text.UTF8Encoding($false)
                        $nl = [Environment]::NewLine
                        $content = $header + $nl + ($blocks -join $nl) + $nl + $summary + $nl
                        [IO.File]::WriteAllText($reportPath, $content, $utf8NoBom)

                        $ctrl['btnOpenReport'].IsEnabled = $true
                        $ctrl['lblRunStatus'].Content = 'Done'
                        Write-EventLog "Report saved: $reportName"

                        Save-KnownHostsStore -Store $state.KnownHostsStore -Path $knownHostsPath
                    }
                    catch {
                        $ctrl['lblRunStatus'].Content = 'Done (report error)'
                        Write-EventLog "Report error: $($_.Exception.Message)"
                    }

                    # Clean temp
                    if ($state.CollectionRun.TempRoot -and (Test-Path -LiteralPath $state.CollectionRun.TempRoot)) {
                        Remove-Item -LiteralPath $state.CollectionRun.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    $state.CollectionRun.PlainPassword = $null
                }
            }
        }
        catch {
            $msg = $_.Exception.Message
            if ($state.LastTimerError -ne $msg) {
                $state.LastTimerError = $msg
                try { Write-EventLog "Timer error: $msg" } catch {}
            }
        }
    })
    $timer.Start()

    # --- Window closing ---
    $window.Add_Closing({
        param($sender, $e)
        if ($state.Running -and $null -ne $state.CollectionRun) {
            $result = [Windows.MessageBox]::Show(
                'Collection is running. Cancel and close?',
                'Confirm', 'YesNo', 'Question')
            if ($result -eq 'No') {
                $e.Cancel = $true
                return
            }
            Stop-CollectionRun $state.CollectionRun
        }
        $timer.Stop()
    })

    $window.ShowDialog() | Out-Null
}
