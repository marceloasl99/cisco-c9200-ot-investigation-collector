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
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
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
        $dir = $ctrl['txtReportDir'].Text
        if (-not $dir) { $dir = $ScriptRoot }
        if (Test-Path -LiteralPath $dir) {
            Start-Process explorer.exe -ArgumentList $dir
        }
    })

    # --- Scan ---
    $ctrl['btnScan'].Add_Click({
        $range = $ctrl['txtScanRange'].Text.Trim()
        if (-not $range) {
            [Windows.MessageBox]::Show('Enter a scan range (e.g. 10.0.0.0/24)', 'Scan', 'OK', 'Warning')
            return
        }
        try {
            $hosts = Expand-IPv4Cidr $range
        } catch {
            [Windows.MessageBox]::Show("Invalid range: $($_.Exception.Message)", 'Scan', 'OK', 'Error')
            return
        }
        $state.ScanData.Clear()
        $ctrl['dgScanResults'].Visibility = 'Visible'
        $ctrl['pbScan'].Visibility = 'Visible'
        $ctrl['pbScan'].Maximum = $hosts.Count
        $ctrl['pbScan'].Value = 0
        $ctrl['btnScan'].IsEnabled = $false
        Write-EventLog ("Scan started: {0} hosts in {1}" -f $hosts.Count, $range)

        $sshPort = 22
        $conn = $Settings['connection']
        if ($conn -and $conn['sshPort']) { $sshPort = [int]$conn['sshPort'] }
        $state.ScanState = Start-NetworkScan -Hosts $hosts -Port $sshPort
    })

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

    # --- Start collection ---
    $ctrl['btnStart'].Add_Click({
        # Validation
        $errors = @()
        $enabledSwitches = @()
        foreach ($sw in $state.SwitchesData) {
            if ($sw.Enabled) {
                $enabledSwitches += @{ Name = $sw.Name; Ip = $sw.Ip }
            }
        }
        if ($enabledSwitches.Count -eq 0) { $errors += 'No switches enabled' }
        if (-not $ctrl['txtUsername'].Text.Trim()) { $errors += 'Username is required' }
        if ($ctrl['txtPassword'].SecurePassword.Length -eq 0) { $errors += 'Password is required' }

        $plinkPath = Resolve-PlinkPath -ConfigPath $ctrl['txtPlinkPath'].Text -ScriptRoot $ScriptRoot
        if (-not $plinkPath) { $errors += 'plink.exe not found' }

        if ($errors.Count -gt 0) {
            [Windows.MessageBox]::Show(($errors -join "`n"), 'Validation', 'OK', 'Warning')
            return
        }

        $cats = Get-SelectedCategories
        $logSources = @()
        if ($ctrl['chkLogBuffer'].IsChecked) { $logSources += 'Buffer' }
        if ($ctrl['chkLogReboot'].IsChecked) { $logSources += 'RebootHistory' }

        $vlanMode = 'All'
        $vlanList = @()
        if ($ctrl['rbVlanOnly'].IsChecked) {
            $vlanMode = 'Only'
            $vlanList = $ctrl['txtVlans'].Text.Trim()
        }
        $macList = @()
        $macText = $ctrl['txtMacs'].Text.Trim()
        if ($macText) { $macList = ($macText -split '[,;\s]+') | Where-Object { $_ -ne '' } }

        $catalog = New-CommandCatalog
        $cmds = Build-CommandList -Catalog $catalog -Categories $cats `
            -VlanMode $vlanMode -VlanList $vlanList -Macs $macList -LogSources $logSources

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

        $state.CollectionRun = New-CollectionRun -Targets $enabledSwitches -Commands $cmds `
            -PlinkPath $plinkPath -Username $ctrl['txtUsername'].Text `
            -SecurePassword $ctrl['txtPassword'].SecurePassword `
            -SupportsPwFile $supportsPwFile -MaxParallel $maxPar `
            -PerSwitchTimeoutSeconds $timeout -HostKeyResolutions $hostKeyResolutions

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
        $ctrl['btnCancel'].IsEnabled = $true
        $ctrl['lblRunStatus'].Content = 'Collecting...'
        $ctrl['pbRun'].Maximum = $enabledSwitches.Count
        $ctrl['pbRun'].Value = 0
        $ctrl['tabMain'].SelectedIndex = 3

        Write-EventLog ("Collection started: {0} switches, {1} commands, max parallel {2}" -f `
            $enabledSwitches.Count, $cmds.Count, $maxPar)
    })

    # --- Cancel ---
    $ctrl['btnCancel'].Add_Click({
        if ($state.CollectionRun) {
            Stop-CollectionRun $state.CollectionRun
            $state.Running = $false
            $ctrl['btnStart'].IsEnabled = $true
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
                $completed = 0
                foreach ($r in $state.ScanState['Results']) {
                    if ($r['PingReply'] -ne $null -or $r['TcpOpen'] -ne $null) { $completed++ }
                }
                $ctrl['pbScan'].Value = $completed

                if ($state.ScanState['Done']) {
                    $ctrl['btnScan'].IsEnabled = $true
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
                $running = ($state.CollectionRun.SwitchStates | Where-Object { $_['Status'] -eq 'Collecting' }).Count
                $queued = ($state.CollectionRun.SwitchStates | Where-Object { $_['Status'] -eq 'Queued' }).Count
                $ctrl['lblRunStatus'].Content = "Collecting: $running running, $queued queued, $doneCount done"

                $ctrl['dgRunProgress'].Items.Refresh()

                if ($state.CollectionRun.Done) {
                    $state.Running = $false
                    $ctrl['btnStart'].IsEnabled = $true
                    $ctrl['btnCancel'].IsEnabled = $false

                    # Build report
                    try {
                        $reportDir = $ctrl['txtReportDir'].Text
                        if (-not $reportDir) { $reportDir = $ScriptRoot }
                        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
                        $reportName = "Cisco_C9200_OT_Investigation_$stamp.txt"
                        $reportPath = Join-Path $reportDir $reportName
                        $state.ReportPath = $reportPath

                        $logDays = 30
                        $sel = $ctrl['cmbLogDays'].SelectedItem
                        if ($null -ne $sel) {
                            $tag = [string]$sel.Tag
                            if ($tag -eq '-1') {
                                try { $logDays = [int]$ctrl['txtCustomDays'].Text } catch {}
                            } else {
                                $logDays = [int]$tag
                            }
                        }

                        $presetName = ''
                        if ($ctrl['cmbPreset'].SelectedItem) { $presetName = [string]$ctrl['cmbPreset'].SelectedItem }

                        $header = New-ReportHeader -PresetName $presetName `
                            -Categories (Get-SelectedCategories) `
                            -LogDays $logDays -SwitchCount $state.CollectionRun.SwitchStates.Count

                        $blocks = @()
                        foreach ($sw in $state.CollectionRun.SwitchStates) {
                            $blocks += New-SwitchBlock -Name $sw['Name'] -Ip $sw['Ip'] `
                                -Status $sw['Status'] -StdOut $sw['StdOut'] -StdErr $sw['StdErr'] `
                                -HostKey $sw['HostKey'] -KeySource $sw['KeySource'] `
                                -ExitCode $sw['ExitCode'] -TimedOut $sw['TimedOut'] `
                                -LogDays $logDays
                        }

                        $summary = New-CollectionSummary $state.CollectionRun.SwitchStates

                        $utf8NoBom = New-Object Text.UTF8Encoding($false)
                        $content = $header + ($blocks -join "`r`n") + "`r`n" + $summary
                        [IO.File]::WriteAllText($reportPath, $content, $utf8NoBom)

                        $ctrl['btnOpenReport'].IsEnabled = $true
                        $ctrl['lblRunStatus'].Content = 'Done'
                        Write-EventLog "Report saved: $reportName"

                        # Save host keys from TOFU
                        foreach ($sw in $state.CollectionRun.SwitchStates) {
                            if ($sw['Status'] -eq 'Done' -and $sw['HostKey']) {
                                Set-KnownHostKey -Store $state.KnownHostsStore `
                                    -Ip $sw['Ip'] -Fingerprint $sw['HostKey'] -Algorithm ''
                            }
                        }
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
            try { Write-EventLog "Timer error: $($_.Exception.Message)" } catch {}
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
