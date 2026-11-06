BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
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
