# Generic example only. Copy the values into the user configuration section of
# CiscoC9200-OT-Investigation.ps1 and replace them with authorized devices.

$User = 'network-admin'

$Switches = [ordered]@{
    'OT-SWITCH-01' = '192.0.2.10'
    'OT-SWITCH-02' = '192.0.2.11'
    'OT-SWITCH-03' = '192.0.2.12'
    'OT-SWITCH-04' = '192.0.2.13'
}

$LostMacs = @()
$FocusVlans = @()

$HostKeys = [ordered]@{
    # '192.0.2.10' = 'ssh-ed25519 255 SHA256:REPLACE_WITH_VERIFIED_FINGERPRINT'
}
