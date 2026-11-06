Set-StrictMode -Version 2.0

function New-CollectionRun {
    param(
        [array]$Targets,
        [string[]]$Commands,
        [string]$PlinkPath,
        [string]$Username,
        [Security.SecureString]$SecurePassword,
        [bool]$SupportsPwFile,
        [int]$MaxParallel = 4,
        [int]$PerSwitchTimeoutSeconds = 175,
        [int]$SshPort = 22,
        [hashtable]$HostKeyResolutions = @{}
    )

    $seen = @{}
    $deduped = @()
    foreach ($t in $Targets) {
        $ip = $t['Ip']
        if (-not $seen.ContainsKey($ip)) {
            $seen[$ip] = $true
            $deduped += $t
        }
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("CiscoC9200_{0}_{1}" -f $PID, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $commandFile = Join-Path $tempRoot 'commands.txt'
    [IO.File]::WriteAllLines($commandFile, $Commands, $utf8NoBom)

    $passwordFile = $null
    $plainPassword = $null
    if ($null -ne $SecurePassword) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        try {
            $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }

    if ($SupportsPwFile -and $plainPassword) {
        $passwordFile = Join-Path $tempRoot 'password.txt'
        [IO.File]::WriteAllText($passwordFile, $plainPassword + [Environment]::NewLine, $utf8NoBom)
        try {
            $acl = Get-Acl $passwordFile
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl', 'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $passwordFile -AclObject $acl
        } catch {}
    }

    $switchStates = @()
    foreach ($t in $deduped) {
        $switchStates += @{
            Name      = $t['Name']
            Ip        = $t['Ip']
            Status    = 'Queued'
            Step      = ''
            Process   = $null
            Started   = $null
            Finished  = $null
            StdOut    = ''
            StdErr    = ''
            ExitCode  = -1
            TimedOut  = $false
            BytesRead = 0
            HostKey   = ''
            KeySource = ''
        }
    }

    return @{
        Targets      = $deduped
        SwitchStates = $switchStates
        Commands     = $Commands
        PlinkPath    = $PlinkPath
        Username     = $Username
        PlainPassword = $plainPassword
        SupportsPwFile = $SupportsPwFile
        PasswordFile = $passwordFile
        CommandFile  = $commandFile
        TempRoot     = $tempRoot
        MaxParallel  = $MaxParallel
        Timeout      = $PerSwitchTimeoutSeconds
        SshPort      = $SshPort
        HostKeyResolutions = $HostKeyResolutions
        Done         = $false
        Cancelled    = $false
        RunningIPs   = @{}
        ActiveCount  = 0
    }
}

function Step-CollectionRun {
    param([hashtable]$Run)

    if ($Run.Done -or $Run.Cancelled) { return }

    foreach ($sw in $Run.SwitchStates) {
        if ($sw['Status'] -ne 'Collecting') { continue }
        $proc = $sw['Process']
        if ($null -eq $proc) { continue }

        $process = $proc['Process']
        $elapsed = ([datetime]::Now - $sw['Started']).TotalSeconds

        if ($process.HasExited) {
            $sw['StdOut'] = $proc['StdoutTask'].Result
            $sw['StdErr'] = $proc['StderrTask'].Result
            $sw['ExitCode'] = $process.ExitCode
            $sw['Finished'] = Get-Date
            $sw['Status'] = 'Done'
            $sw['BytesRead'] = $sw['StdOut'].Length
            $process.Dispose()
            $Run.RunningIPs.Remove($sw['Ip'])
            $Run.ActiveCount--
        }
        elseif ($elapsed -ge $Run.Timeout) {
            $sw['TimedOut'] = $true
            try { $process.Kill() } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
            try {
                $sw['StdOut'] = $proc['StdoutTask'].Result
                $sw['StdErr'] = $proc['StderrTask'].Result
            } catch {}
            $sw['ExitCode'] = -1
            $sw['Finished'] = Get-Date
            $sw['Status'] = 'TimedOut'
            $sw['BytesRead'] = $sw['StdOut'].Length
            $process.Dispose()
            $Run.RunningIPs.Remove($sw['Ip'])
            $Run.ActiveCount--
        }
    }

    foreach ($sw in $Run.SwitchStates) {
        if ($sw['Status'] -ne 'Queued') { continue }
        if ($Run.ActiveCount -ge $Run.MaxParallel) { break }
        if ($Run.RunningIPs.ContainsKey($sw['Ip'])) { continue }

        $hostKey = ''
        $keySource = ''
        $resolution = $null
        if ($Run.HostKeyResolutions.ContainsKey($sw['Ip'])) {
            $resolution = $Run.HostKeyResolutions[$sw['Ip']]
            $hostKey = $resolution['Fingerprint']
            $keySource = $resolution['Source']
        }
        $sw['HostKey'] = $hostKey
        $sw['KeySource'] = $keySource

        $args = Build-PlinkArguments -Ip $sw['Ip'] -Port $Run.SshPort `
            -Username $Run.Username -Password $Run.PlainPassword `
            -SupportsPwFile $Run.SupportsPwFile `
            -PasswordFilePath $Run.PasswordFile `
            -HostKeyFingerprint $hostKey `
            -CommandFilePath $Run.CommandFile

        try {
            $proc = Start-PlinkProcess -PlinkPath $Run.PlinkPath -Arguments $args
            $sw['Process'] = $proc
            $sw['Started'] = Get-Date
            $sw['Status'] = 'Collecting'
            $Run.RunningIPs[$sw['Ip']] = $true
            $Run.ActiveCount++
        }
        catch {
            $sw['Status'] = 'Failed'
            $sw['StdErr'] = $_.Exception.Message
            $sw['Finished'] = Get-Date
        }
    }

    $allDone = $true
    foreach ($sw in $Run.SwitchStates) {
        if ($sw['Status'] -in @('Queued','Collecting')) {
            $allDone = $false
            break
        }
    }
    $Run.Done = $allDone
}

function Stop-CollectionRun {
    param([hashtable]$Run)

    $Run.Cancelled = $true
    foreach ($sw in $Run.SwitchStates) {
        if ($sw['Status'] -eq 'Collecting' -and $null -ne $sw['Process']) {
            $process = $sw['Process']['Process']
            try {
                if (-not $process.HasExited) { $process.Kill() }
                $process.WaitForExit(5000) | Out-Null
            } catch {}
            $process.Dispose()
            $sw['Status'] = 'Cancelled'
            $sw['Finished'] = Get-Date
        }
        elseif ($sw['Status'] -eq 'Queued') {
            $sw['Status'] = 'Cancelled'
        }
    }
    $Run.RunningIPs = @{}
    $Run.ActiveCount = 0
    $Run.Done = $true

    if ($Run.TempRoot -and (Test-Path -LiteralPath $Run.TempRoot)) {
        Remove-Item -LiteralPath $Run.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Run.PlainPassword = $null
}
