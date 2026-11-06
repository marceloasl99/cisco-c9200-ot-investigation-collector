Set-StrictMode -Version 2.0

function Resolve-PlinkPath {
    param(
        [string]$ConfigPath,
        [string]$ScriptRoot
    )
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        return (Resolve-Path -LiteralPath $ConfigPath).Path
    }
    $beside = Join-Path $ScriptRoot 'plink.exe'
    if (Test-Path -LiteralPath $beside) {
        return (Resolve-Path -LiteralPath $beside).Path
    }
    try {
        return (Get-Command plink.exe -ErrorAction Stop).Source
    }
    catch {}
    $putty = 'C:\Program Files\PuTTY\plink.exe'
    if (Test-Path -LiteralPath $putty) {
        return $putty
    }
    return $null
}

function Test-PlinkPwFileSupport {
    param([string]$PlinkPath)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $PlinkPath
    $psi.Arguments = '--help'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(5000) | Out-Null
        $helpText = $stdout + $stderr
        return $helpText -match '(?m)^\s*-pwfile\s'
    }
    catch {
        return $false
    }
}

function Build-PlinkArguments {
    param(
        [string]$Ip,
        [int]$Port,
        [string]$Username,
        [string]$Password,
        [bool]$SupportsPwFile,
        [string]$PasswordFilePath,
        [string]$HostKeyFingerprint,
        [string]$CommandFilePath
    )

    $plinkArgs = New-Object Collections.Generic.List[string]
    $plinkArgs.Add('-ssh')
    $plinkArgs.Add('-t')
    $plinkArgs.Add('-batch')
    $plinkArgs.Add('-noagent')
    $plinkArgs.Add('-P')
    $plinkArgs.Add([string]$Port)
    $plinkArgs.Add('-l')
    $plinkArgs.Add($Username)

    if ($HostKeyFingerprint) {
        $plinkArgs.Add('-hostkey')
        $plinkArgs.Add($HostKeyFingerprint)
    }

    if ($SupportsPwFile -and $PasswordFilePath) {
        $plinkArgs.Add('-pwfile')
        $plinkArgs.Add($PasswordFilePath)
    }
    else {
        $plinkArgs.Add('-pw')
        $plinkArgs.Add($Password)
    }

    $plinkArgs.Add($Ip)
    $plinkArgs.Add('-m')
    $plinkArgs.Add($CommandFilePath)

    return , $plinkArgs.ToArray()
}

function Quote-PlinkArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-PlinkProcess {
    param(
        [string]$PlinkPath,
        [string[]]$Arguments
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $PlinkPath
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-PlinkArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        throw "Failed to start plink process"
    }

    return @{
        Process    = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        Started    = Get-Date
    }
}
