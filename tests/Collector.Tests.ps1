BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/HostKeys.ps1')
    . (Join-Path $ProjectRoot 'lib/Plink.ps1')
    . (Join-Path $ProjectRoot 'lib/Collector.ps1')
}

Describe 'Build-PlinkArguments' {
    It 'builds standard arguments with -pwfile' {
        $args = Build-PlinkArguments -Ip '10.0.0.1' -Port 22 -Username 'admin' `
            -Password 'secret' -SupportsPwFile $true -PasswordFilePath 'C:\tmp\pw.txt' `
            -HostKeyFingerprint 'SHA256:abc' -CommandFilePath 'C:\tmp\cmd.txt'
        $args | Should -Contain '-ssh'
        $args | Should -Contain '-batch'
        $args | Should -Contain '-pwfile'
        $args | Should -Contain 'C:\tmp\pw.txt'
        $args | Should -Contain '-hostkey'
        $args | Should -Contain 'SHA256:abc'
        $args | Should -Contain '10.0.0.1'
        $args | Should -Not -Contain '-pw'
    }

    It 'falls back to -pw when SupportsPwFile is false' {
        $args = Build-PlinkArguments -Ip '10.0.0.1' -Port 22 -Username 'admin' `
            -Password 'secret' -SupportsPwFile $false -PasswordFilePath '' `
            -HostKeyFingerprint '' -CommandFilePath 'C:\tmp\cmd.txt'
        $args | Should -Contain '-pw'
        $args | Should -Contain 'secret'
        $args | Should -Not -Contain '-pwfile'
    }

    It 'omits -hostkey when fingerprint is empty' {
        $args = Build-PlinkArguments -Ip '10.0.0.1' -Port 22 -Username 'admin' `
            -Password 'secret' -SupportsPwFile $false -PasswordFilePath '' `
            -HostKeyFingerprint '' -CommandFilePath 'C:\tmp\cmd.txt'
        $args | Should -Not -Contain '-hostkey'
    }
}

Describe 'Quote-PlinkArgument' {
    It 'quotes a simple string' {
        Quote-PlinkArgument 'hello' | Should -Be '"hello"'
    }
    It 'escapes embedded quotes' {
        Quote-PlinkArgument 'say "hi"' | Should -Be '"say \"hi\""'
    }
    It 'handles null' {
        Quote-PlinkArgument $null | Should -Be '""'
    }
}

Describe 'New-CollectionRun' {
    BeforeAll {
        $targets = @(
            @{ Name = 'SW-01'; Ip = '10.0.0.1' }
            @{ Name = 'SW-02'; Ip = '10.0.0.2' }
            @{ Name = 'SW-DUP'; Ip = '10.0.0.1' }
        )
        $secPw = ConvertTo-SecureString 'test' -AsPlainText -Force
        $run = New-CollectionRun -Targets $targets -Commands @('terminal length 0','exit') `
            -PlinkPath 'plink.exe' -Username 'admin' -SecurePassword $secPw `
            -SupportsPwFile $false -MaxParallel 2
    }
    AfterAll {
        if ($run -and $run.TempRoot -and (Test-Path -LiteralPath $run.TempRoot)) {
            Remove-Item -LiteralPath $run.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'deduplicates targets by IP' {
        $run.SwitchStates.Count | Should -Be 2
    }

    It 'creates temp directory' {
        Test-Path -LiteralPath $run.TempRoot | Should -BeTrue
    }

    It 'writes command file' {
        Test-Path -LiteralPath $run.CommandFile | Should -BeTrue
    }

    It 'all switches start as Queued' {
        foreach ($sw in $run.SwitchStates) {
            $sw['Status'] | Should -Be 'Queued'
        }
    }

    It 'respects MaxParallel setting' {
        $run.MaxParallel | Should -Be 2
    }
}

Describe 'Stop-CollectionRun' {
    It 'marks queued switches as Cancelled and cleans up temp' {
        $targets = @(
            @{ Name = 'SW-01'; Ip = '10.0.0.1' }
            @{ Name = 'SW-02'; Ip = '10.0.0.2' }
        )
        $secPw = ConvertTo-SecureString 'test' -AsPlainText -Force
        $run = New-CollectionRun -Targets $targets -Commands @('exit') `
            -PlinkPath 'plink.exe' -Username 'admin' -SecurePassword $secPw `
            -SupportsPwFile $false -MaxParallel 2
        $tempRoot = $run.TempRoot

        Stop-CollectionRun $run

        $run.Cancelled | Should -BeTrue
        $run.Done | Should -BeTrue
        foreach ($sw in $run.SwitchStates) {
            $sw['Status'] | Should -Be 'Cancelled'
        }
        Test-Path -LiteralPath $tempRoot | Should -BeFalse
        $run.PlainPassword | Should -BeNullOrEmpty
    }
}

Describe 'Step-CollectionRun host key handling' {
    BeforeAll {
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ("hk_{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null

        function New-FakePlink([string]$Name, [string]$Mode) {
            $log = Join-Path $script:dir "$Name.log"
            $lines = @('@echo off', "echo called %* >> `"$log`"")
            if ($Mode -eq 'unknown') {
                $lines += 'echo %* | findstr /C:"-hostkey" >nul', 'if %errorlevel%==0 goto ok',
                    '>&2 echo The host key is not cached for this server:',
                    '>&2 echo The server''s ssh-ed25519 key fingerprint is:',
                    '>&2 echo   ssh-ed25519 255 SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234',
                    '>&2 echo Connection abandoned.', 'exit /b 1', ':ok', 'echo SWITCH OUTPUT', 'exit /b 0'
            }
            elseif ($Mode -eq 'changed') {
                $lines += '>&2 echo WARNING - POTENTIAL SECURITY BREACH!',
                    '>&2 echo The server''s host key does not match the one PuTTY has',
                    '>&2 echo   ssh-ed25519 255 SHA256:NewKeyFingerprint1234567890abcdefghijklm',
                    '>&2 echo Connection abandoned.', 'exit /b 1'
            }
            $path = Join-Path $script:dir "$Name.cmd"
            [IO.File]::WriteAllLines($path, $lines)
            return @{ Path = $path; Log = $log }
        }

        function Invoke-Run($fake, [string]$Policy, [hashtable]$Resolutions = @{}, $Store = $null) {
            $pw = ConvertTo-SecureString 'x' -AsPlainText -Force
            $run = New-CollectionRun -Targets @(@{ Name = 'SW'; Ip = '10.0.0.1' }) -Commands @('exit') `
                -PlinkPath $fake.Path -Username 'u' -SecurePassword $pw -SupportsPwFile $false `
                -MaxParallel 1 -PerSwitchTimeoutSeconds 30 -HostKeyPolicy $Policy `
                -HostKeyResolutions $Resolutions -KnownHostsStore $Store
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $run.Done -and (Get-Date) -lt $deadline) { Step-CollectionRun $run; Start-Sleep -Milliseconds 100 }
            Stop-CollectionRun $run
            return $run
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'learns an unknown key, retries once with -hostkey and finishes (AutoAccept)' {
        $fake = New-FakePlink 'auto' 'unknown'
        $store = New-KnownHostsStore
        $run = Invoke-Run $fake 'AutoAccept' @{} $store
        $sw = $run.SwitchStates[0]
        $sw['Status'] | Should -Be 'Done'
        $sw['StdOut'] | Should -Match 'SWITCH OUTPUT'
        $sw['HostKey'] | Should -Be 'SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234'
        $sw['KeySource'] | Should -Match 'auto-accepted'
        @(Get-Content $fake.Log).Count | Should -Be 2
        (Get-KnownHostKey $store '10.0.0.1').fingerprint | Should -Be 'SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234'
    }

    It 'connects once when the key is already known' {
        $fake = New-FakePlink 'known' 'unknown'
        $res = @{ '10.0.0.1' = @{ Source = 'known_hosts'; Fingerprint = 'SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234' } }
        $run = Invoke-Run $fake 'AutoAccept' $res
        $run.SwitchStates[0]['Status'] | Should -Be 'Done'
        @(Get-Content $fake.Log).Count | Should -Be 1
    }

    It 'skips the switch under the Strict policy without retrying' {
        $fake = New-FakePlink 'strict' 'unknown'
        $run = Invoke-Run $fake 'Strict'
        $run.SwitchStates[0]['Status'] | Should -Be 'Skipped'
        $run.SwitchStates[0]['Note'] | Should -Match 'not trusted'
        @(Get-Content $fake.Log).Count | Should -Be 1
    }

    It 'skips a changed host key and never retries' {
        $fake = New-FakePlink 'changed' 'changed'
        $run = Invoke-Run $fake 'AutoAccept'
        $run.SwitchStates[0]['Status'] | Should -Be 'Skipped'
        $run.SwitchStates[0]['Note'] | Should -Match 'CHANGED'
        @(Get-Content $fake.Log).Count | Should -Be 1
    }
}
