BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $ProjectRoot 'lib/HostKeys.ps1')
}

Describe 'Parse-PlinkHostKeyMessage' {
    It 'parses fingerprint from plink "Connection abandoned" message' {
        $msg = @"
The host key is not cached for this server:
  10.20.30.11 (port 22)
You have no guarantee that the server is the computer
you think it is.
The server's ssh-ed25519 key fingerprint is:
  ssh-ed25519 255 SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234
If you trust this host, enter "y" to add the key to
PuTTY's cache and carry on connecting.
If you want to carry on connecting just once, without
adding the key to the cache, enter "n".
If you do not trust this host, press Return to abandon the
connection.
Connection abandoned.
"@
        $result = Parse-PlinkHostKeyMessage $msg
        $result | Should -Not -BeNullOrEmpty
        $result.Algorithm | Should -Be 'ssh-ed25519'
        $result.Fingerprint | Should -Be 'SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234'
    }

    It 'parses ecdsa fingerprint' {
        $msg = "The server's ecdsa-sha2-nistp256 key fingerprint is:`n  ecdsa-sha2-nistp256 256 SHA256:XyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLm12`nConnection abandoned."
        $result = Parse-PlinkHostKeyMessage $msg
        $result.Algorithm | Should -Be 'ecdsa-sha2-nistp256'
        $result.Fingerprint | Should -Match '^SHA256:'
    }

    It 'returns null for unrelated plink output' {
        $result = Parse-PlinkHostKeyMessage 'FATAL ERROR: connection refused'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Parse-PlinkHostKeyChanged' {
    It 'detects host key mismatch message' {
        $msg = @"
WARNING - POTENTIAL SECURITY BREACH!
The server's host key does not match the one PuTTY has
cached for this server. This means that either the
server administrator has changed the host key, or you
have actually connected to another computer pretending
to be the server.
The new ssh-ed25519 key fingerprint is:
  ssh-ed25519 255 SHA256:NewKeyFingerprint1234567890abcdefghijklm
If you were expecting this change and trust the new key,
enter "y" to update PuTTY's cache and continue connecting.
Connection abandoned.
"@
        $result = Parse-PlinkHostKeyChanged $msg
        $result | Should -Not -BeNullOrEmpty
        $result.Changed | Should -BeTrue
        $result.NewFingerprint | Should -Match '^SHA256:'
    }

    It 'returns null for normal plink output' {
        $result = Parse-PlinkHostKeyChanged 'normal output here'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'New-KnownHostsStore' {
    It 'creates an empty store' {
        $store = New-KnownHostsStore
        $store | Should -BeOfType [hashtable]
        $store.hosts | Should -BeOfType [hashtable]
    }
}

Describe 'Get-KnownHostKey' {
    It 'returns null for unknown host' {
        $store = New-KnownHostsStore
        $key = Get-KnownHostKey $store '10.0.0.1'
        $key | Should -BeNullOrEmpty
    }

    It 'returns stored key for known host' {
        $store = New-KnownHostsStore
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:abc123' 'ssh-ed25519'
        $key = Get-KnownHostKey $store '10.0.0.1'
        $key | Should -Not -BeNullOrEmpty
        $key.fingerprint | Should -Be 'SHA256:abc123'
    }
}

Describe 'Set-KnownHostKey' {
    It 'stores a new key with timestamps' {
        $store = New-KnownHostsStore
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:test' 'ssh-ed25519'
        $entry = $store.hosts['10.0.0.1']
        $entry.fingerprint | Should -Be 'SHA256:test'
        $entry.algorithm | Should -Be 'ssh-ed25519'
        $entry.firstSeen | Should -Not -BeNullOrEmpty
        $entry.lastSeen | Should -Not -BeNullOrEmpty
    }

    It 'updates lastSeen on re-store' {
        $store = New-KnownHostsStore
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:test' 'ssh-ed25519'
        $first = $store.hosts['10.0.0.1'].firstSeen
        Start-Sleep -Milliseconds 50
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:test' 'ssh-ed25519'
        $store.hosts['10.0.0.1'].firstSeen | Should -Be $first
    }
}

Describe 'Save/Load KnownHostsStore roundtrip' {
    BeforeAll {
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) "test_known_hosts_$(Get-Random).json"
    }
    AfterAll {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    It 'roundtrips through JSON' {
        $store = New-KnownHostsStore
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:testkey' 'ssh-ed25519'
        Save-KnownHostsStore $store $tempFile
        $loaded = Import-KnownHostsStore $tempFile
        $key = Get-KnownHostKey $loaded '10.0.0.1'
        $key.fingerprint | Should -Be 'SHA256:testkey'
    }

    It 'overwrites an existing store file' {
        $store = New-KnownHostsStore
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:first' 'ssh-ed25519'
        Save-KnownHostsStore $store $tempFile
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:second' 'ssh-ed25519'
        Save-KnownHostsStore $store $tempFile
        $loaded = Import-KnownHostsStore $tempFile
        (Get-KnownHostKey $loaded '10.0.0.1').fingerprint | Should -Be 'SHA256:second'
        Test-Path -LiteralPath ($tempFile + '.tmp') | Should -BeFalse
    }
}

Describe 'Resolve-HostKey' {
    It 'returns pinned key when available' {
        $pinned = @{ '10.0.0.1' = 'ssh-ed25519 255 SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234' }
        $store = New-KnownHostsStore
        $result = Resolve-HostKey '10.0.0.1' $pinned $store
        $result['Source'] | Should -Be 'pinned'
        $result['Fingerprint'] | Should -Be 'SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk1234'
    }

    It 'falls back to known_hosts store' {
        $pinned = @{}
        $store = New-KnownHostsStore
        Set-KnownHostKey $store '10.0.0.1' 'SHA256:knownkey' 'ssh-ed25519'
        $result = Resolve-HostKey '10.0.0.1' $pinned $store
        $result.Source | Should -Be 'known_hosts'
        $result.Fingerprint | Should -Be 'SHA256:knownkey'
    }

    It 'returns null when key is unknown' {
        $pinned = @{}
        $store = New-KnownHostsStore
        $result = Resolve-HostKey '10.0.0.1' $pinned $store
        $result | Should -BeNullOrEmpty
    }
}
