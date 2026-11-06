param(
    [ValidateSet('Fast','Standard','Deep')]
    [string]$Mode = 'Standard',

    [ValidateRange(60,900)]
    [int]$PerSwitchTimeoutSeconds = 175,

    [ValidateRange(1,30)]
    [int]$SshConnectTimeoutSeconds = 5,

    [switch]$NoGui,

    [string]$SettingsPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- Load library modules ---
. (Join-Path $PSScriptRoot 'lib/Commands.ps1')
. (Join-Path $PSScriptRoot 'lib/Settings.ps1')
. (Join-Path $PSScriptRoot 'lib/LogFilter.ps1')
. (Join-Path $PSScriptRoot 'lib/Report.ps1')
. (Join-Path $PSScriptRoot 'lib/Network.ps1')
. (Join-Path $PSScriptRoot 'lib/HostKeys.ps1')
. (Join-Path $PSScriptRoot 'lib/Plink.ps1')
. (Join-Path $PSScriptRoot 'lib/Collector.ps1')

# --- GUI or legacy CLI dispatch ---
$isLegacyMode = $PSBoundParameters.ContainsKey('Mode')
$isHeadless = $NoGui.IsPresent -or $isLegacyMode

if (-not $isHeadless) {
    try {
        . (Join-Path $PSScriptRoot 'gui/Gui.ps1')
        $settingsFile = if ($SettingsPath) { $SettingsPath } else { Join-Path $PSScriptRoot 'settings.json' }
        $guiSettings = Import-Settings -Path $settingsFile
        Show-CollectorGui -ScriptRoot $PSScriptRoot -Settings $guiSettings
        return
    }
    catch {
        Write-Host "GUI could not load: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Falling back to CLI. Use -NoGui to run headless directly." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ============================================================================
# USER CONFIGURATION
# ============================================================================

$User = 'network-admin'
$PlinkPath = Join-Path $PSScriptRoot 'plink.exe'

# Name = IP address. Add or remove switches here.
# The addresses below use RFC 5737 documentation space and must be replaced.
$Switches = [ordered]@{
    'OT-SWITCH-01' = '192.0.2.10'
    'OT-SWITCH-02' = '192.0.2.11'
    'OT-SWITCH-03' = '192.0.2.12'
    'OT-SWITCH-04' = '192.0.2.13'
}

# Optional: investigate specific MAC addresses. Accepted formats include
# 2863.3661.6687, 28:63:36:61:66:87, and 28-63-36-61-66-87.
$LostMacs = @(
    # '28:63:36:61:66:87'
)

# Optional: add focused STP output for important OT VLANs.
$FocusVlans = @(
    # 31, 32, 33
)

# Recommended: pin each SSH host key. If empty, the key must already be trusted
# in PuTTY for the Windows user running this script. Example value:
# 'ssh-ed25519 255 SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$HostKeys = [ordered]@{
    # '192.0.2.10' = 'ssh-ed25519 255 SHA256:...'
}

# Deep mode can exceed three minutes on busy switches. These options are kept
# off by default even in Standard mode.
$IncludeSanitizedRunningConfig = ($Mode -eq 'Deep')
$IncludeShowTechSupport = $false

# ============================================================================
# OUTPUT INITIALIZATION
# ============================================================================

$RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$ReportPath = Join-Path $PSScriptRoot ("Cisco_C9200_OT_Investigation_{0}.txt" -f $RunStamp)
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("CiscoC9200_{0}_{1}" -f $PID, $RunStamp)
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.Directory]::CreateDirectory($TempRoot) | Out-Null
$RunStart = Get-Date

function Write-Report {
    param([string]$Text = '')
    [IO.File]::AppendAllText($ReportPath, $Text + [Environment]::NewLine, $Utf8NoBom)
}

function Write-ConsoleStatus {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Message -ForegroundColor $Color
}

function Convert-ToPlainText {
    param([Security.SecureString]$SecureValue)
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Convert-ToCiscoMac {
    param([string]$Mac)
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
    if ($hex.Length -ne 12) {
        throw "Invalid MAC address: $Mac"
    }
    return '{0}.{1}.{2}' -f $hex.Substring(0,4), $hex.Substring(4,4), $hex.Substring(8,4)
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Test-TcpPort {
    param([string]$Ip, [int]$Port = 22, [int]$TimeoutSeconds = 5)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Ip, $Port)
        if (-not $task.Wait($TimeoutSeconds * 1000)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Resolve-Plink {
    if (Test-Path -LiteralPath $PlinkPath) {
        return (Resolve-Path -LiteralPath $PlinkPath).Path
    }
    try {
        return (Get-Command plink.exe -ErrorAction Stop).Source
    }
    catch {
        throw "plink.exe was not found. Place plink.exe beside the script or add it to PATH."
    }
}

function New-CiscoCommandList {
    param([string]$CollectionMode)

    $commands = New-Object Collections.Generic.List[string]
    $commands.Add('terminal length 0')
    $commands.Add('terminal width 511')

    # Identity, uptime, stack, software, boot, hardware, and health.
    foreach ($cmd in @(
        'show clock detail',
        'show version',
        'show inventory',
        'show switch detail',
        'show boot',
        'show redundancy',
        'show platform',
        'show platform resources',
        'show platform software status control-processor brief',
        'show processes cpu sorted 5sec',
        'show processes memory platform sorted',
        'show environment all',
        'show power inline',
        'show license summary'
    )) { $commands.Add($cmd) }

    # Layer 1, interface state, traffic, errors, optics, and PoE.
    foreach ($cmd in @(
        'show interfaces status',
        'show interfaces description',
        'show ip interface brief',
        'show interfaces counters',
        'show interfaces counters errors',
        'show interfaces transceiver detail',
        'show interfaces switchport',
        'show interfaces status err-disabled',
        'show errdisable detect',
        'show errdisable recovery'
    )) { $commands.Add($cmd) }

    # Layer 2 topology, VLANs, trunks, EtherChannel, STP, MAC, and neighbors.
    foreach ($cmd in @(
        'show vlan brief',
        'show interfaces trunk',
        'show etherchannel summary',
        'show etherchannel port-channel',
        'show spanning-tree summary',
        'show spanning-tree root',
        'show spanning-tree blockedports',
        'show spanning-tree inconsistentports',
        'show mac address-table count',
        'show mac address-table dynamic',
        'show cdp neighbors detail',
        'show lldp neighbors detail',
        'show vtp status'
    )) { $commands.Add($cmd) }

    foreach ($vlan in $FocusVlans) {
        if ($vlan -ge 1 -and $vlan -le 4094) {
            $commands.Add("show spanning-tree vlan $vlan detail")
            $commands.Add("show mac address-table vlan $vlan")
        }
    }

    foreach ($mac in $LostMacs) {
        $ciscoMac = Convert-ToCiscoMac $mac
        $commands.Add("show mac address-table address $ciscoMac")
    }

    # Layer 3, management reachability, and forwarding information.
    foreach ($cmd in @(
        'show ip arp',
        'show ip route',
        'show ip default-gateway',
        'show ip protocols',
        'show ntp associations',
        'show ntp status'
    )) { $commands.Add($cmd) }

    # Common causes of blocked or restricted OT connectivity.
    foreach ($cmd in @(
        'show port-security',
        'show port-security address',
        'show authentication sessions',
        'show access-lists',
        'show ip access-lists',
        'show ip dhcp snooping',
        'show ip arp inspection',
        'show ip verify source',
        'show storm-control',
        'show monitor session all'
    )) { $commands.Add($cmd) }

    # Configuration extracts: broad enough for investigation but avoid printing
    # password, secret, SNMP community, and key material in Standard/Fast mode.
    foreach ($cmd in @(
        'show running-config | section ^interface',
        'show running-config | section ^vlan',
        'show running-config | section ^spanning-tree',
        'show running-config | section ^monitor session',
        'show running-config | include ^hostname|^ip default-gateway|^ip route|^ntp|^clock timezone|^logging host|^snmp-server location'
    )) { $commands.Add($cmd) }

    $commands.Add('show logging')

    if ($CollectionMode -ne 'Fast') {
        foreach ($cmd in @(
            'show spanning-tree detail',
            'show interfaces',
            'show platform software fed switch active punt rates interfaces',
            'show platform software fed switch active punt cpuq rates',
            'show diagnostic result switch all detail'
        )) { $commands.Add($cmd) }
    }

    if ($IncludeSanitizedRunningConfig) {
        $commands.Add('show running-config | exclude password|secret|community|key-string|authentication-key|privacy-key')
    }
    if ($IncludeShowTechSupport) {
        $commands.Add('show tech-support')
    }

    $commands.Add('exit')
    return $commands.ToArray()
}

function Invoke-SwitchCollection {
    param(
        [string]$Name,
        [string]$Ip,
        [string]$Plink,
        [string]$Password,
        [bool]$SupportsPwFile,
        [string[]]$Commands
    )

    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $commandFile = Join-Path $TempRoot ("commands_{0}.txt" -f $safeName)
    $passwordFile = Join-Path $TempRoot ("password_{0}.txt" -f $safeName)
    [IO.File]::WriteAllLines($commandFile, $Commands, $Utf8NoBom)

    $plinkArgs = New-Object Collections.Generic.List[string]
    $plinkArgs.Add('-ssh')
    $plinkArgs.Add('-t')
    $plinkArgs.Add('-batch')
    $plinkArgs.Add('-noagent')
    $plinkArgs.Add('-P')
    $plinkArgs.Add('22')
    $plinkArgs.Add('-l')
    $plinkArgs.Add($User)

    if ($HostKeys.Contains($Ip)) {
        $plinkArgs.Add('-hostkey')
        $plinkArgs.Add([string]$HostKeys[$Ip])
    }

    if ($SupportsPwFile) {
        [IO.File]::WriteAllText($passwordFile, $Password + [Environment]::NewLine, $Utf8NoBom)
        try {
            $acl = Get-Acl $passwordFile
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $passwordFile -AclObject $acl
        } catch {}
        $plinkArgs.Add('-pwfile')
        $plinkArgs.Add($passwordFile)
    }
    else {
        $plinkArgs.Add('-pw')
        $plinkArgs.Add($Password)
    }

    $plinkArgs.Add($Ip)
    $plinkArgs.Add('-m')
    $plinkArgs.Add($commandFile)

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Plink
    $psi.Arguments = (($plinkArgs | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $started = Get-Date
    $timedOut = $false

    try {
        if (-not $process.Start()) { throw 'Plink process could not be started.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($PerSwitchTimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill() } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    }
    finally {
        $process.Dispose()
        Remove-Item -LiteralPath $commandFile, $passwordFile -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Name = $Name
        Ip = $Ip
        Started = $started
        Finished = Get-Date
        TimedOut = $timedOut
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

$PlainPassword = $null
try {
    $PlinkResolved = Resolve-Plink
    $plinkHelpPsi = New-Object Diagnostics.ProcessStartInfo
    $plinkHelpPsi.FileName = $PlinkResolved
    $plinkHelpPsi.Arguments = '--help'
    $plinkHelpPsi.UseShellExecute = $false
    $plinkHelpPsi.CreateNoWindow = $true
    $plinkHelpPsi.RedirectStandardOutput = $true
    $plinkHelpPsi.RedirectStandardError = $true
    $plinkHelpProc = [Diagnostics.Process]::Start($plinkHelpPsi)
    $plinkHelpOut = $plinkHelpProc.StandardOutput.ReadToEnd()
    $plinkHelpErr = $plinkHelpProc.StandardError.ReadToEnd()
    $plinkHelpProc.WaitForExit(5000) | Out-Null
    $plinkHelp = $plinkHelpOut + $plinkHelpErr
    $SupportsPwFile = $plinkHelp -match '(?m)^\s*-pwfile\s'
    $Commands = New-CiscoCommandList -CollectionMode $Mode

    $SecurePassword = Read-Host "SSH password for $User" -AsSecureString
    $PlainPassword = Convert-ToPlainText $SecurePassword

    @(
        '==========================================================================',
        'CISCO C9200 OT NETWORK INVESTIGATION',
        '==========================================================================',
        "Started             : $($RunStart.ToString('yyyy-MM-dd HH:mm:ss'))",
        "Operator account    : $User",
        "Collection mode     : $Mode",
        "Per-switch timeout  : $PerSwitchTimeoutSeconds seconds",
        "Switch count        : $($Switches.Count)",
        "Plink               : $PlinkResolved",
        "Plink -pwfile       : $SupportsPwFile",
        "Commands per switch : $($Commands.Count)",
        "Report              : $ReportPath",
        '',
        'NOTE: This report may contain sensitive network details. Protect it.',
        'Some commands vary by IOS-XE release; CLI errors are retained as evidence.',
        ''
    ) | ForEach-Object { Write-Report $_ }

    $index = 0
    foreach ($entry in $Switches.GetEnumerator()) {
        $index++
        $name = [string]$entry.Key
        $ip = [string]$entry.Value
        $switchStart = Get-Date

        Write-ConsoleStatus ("[{0}/{1}] {2} ({3}) - pre-check" -f $index,$Switches.Count,$name,$ip) Cyan
        Write-Report '##############################################################################'
        Write-Report ("SWITCH: {0} ({1})" -f $name,$ip)
        Write-Report ("START : {0}" -f $switchStart.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Report ("MODE  : {0}" -f $Mode)
        Write-Report '##############################################################################'
        Write-Report ''
        Write-Report 'COMMAND PLAN:'
        foreach ($command in $Commands) { Write-Report ("  {0}" -f $command) }
        Write-Report ''
        Write-Report 'RAW CLI OUTPUT:'
        Write-Report '------------------------------------------------------------------------------'

        if (-not (Test-TcpPort -Ip $ip -Port 22 -TimeoutSeconds $SshConnectTimeoutSeconds)) {
            $message = "SKIPPED: TCP/22 was not reachable within $SshConnectTimeoutSeconds seconds."
            Write-ConsoleStatus ("  $message") Yellow
            Write-Report $message
            Write-Report ''
            continue
        }

        try {
            Write-ConsoleStatus ("  Collecting, hard timeout {0}s..." -f $PerSwitchTimeoutSeconds) DarkCyan
            $result = Invoke-SwitchCollection -Name $name -Ip $ip -Plink $PlinkResolved -Password $PlainPassword -SupportsPwFile $SupportsPwFile -Commands $Commands
            Write-Report $result.StdOut.TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
                Write-Report ''
                Write-Report 'PLINK STDERR:'
                Write-Report $result.StdErr.TrimEnd()
            }
            Write-Report ''
            Write-Report 'COLLECTION RESULT:'
            Write-Report ("  Exit code : {0}" -f $result.ExitCode)
            Write-Report ("  Timed out: {0}" -f $result.TimedOut)
            Write-Report ("  Finished : {0}" -f $result.Finished.ToString('yyyy-MM-dd HH:mm:ss'))
            Write-Report ("  Duration : {0:n1} seconds" -f ($result.Finished-$result.Started).TotalSeconds)

            if ($result.TimedOut) {
                Write-ConsoleStatus '  TIMEOUT - partial output was saved.' Yellow
            }
            elseif ($result.ExitCode -eq 0) {
                Write-ConsoleStatus ("  Completed in {0:n1}s" -f ($result.Finished-$result.Started).TotalSeconds) Green
            }
            else {
                Write-ConsoleStatus ("  Plink exit code {0}; inspect STDERR in report." -f $result.ExitCode) Yellow
            }
        }
        catch {
            Write-Report ("FATAL COLLECTION ERROR: {0}" -f $_.Exception.Message)
            Write-ConsoleStatus ("  ERROR: {0}" -f $_.Exception.Message) Red
        }
        finally {
            Write-Report ''
            Write-Report ("END SWITCH: {0} ({1})" -f $name,$ip)
            Write-Report ''
        }
    }
}
catch {
    Write-ConsoleStatus ("FATAL: {0}" -f $_.Exception.Message) Red
    try { Write-Report ("FATAL SCRIPT ERROR: {0}" -f $_.Exception.ToString()) } catch {}
    exit 1
}
finally {
    $PlainPassword = $null
    $SecurePassword = $null
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$RunEnd = Get-Date
Write-Report '========================================================================== '
Write-Report 'COLLECTION FINISHED'
Write-Report ("Finished       : {0}" -f $RunEnd.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Report ("Total duration : {0}" -f ($RunEnd-$RunStart).ToString())
Write-Report ("Report         : {0}" -f $ReportPath)
Write-Report '========================================================================== '

Write-Host ''
Write-ConsoleStatus ("REPORT GENERATED: {0}" -f $ReportPath) Yellow
Write-ConsoleStatus ("TOTAL DURATION : {0}" -f ($RunEnd-$RunStart).ToString()) Green
