# Cisco C9200 OT Investigation Collector

A PowerShell-based read-only diagnostic collector for Cisco Catalyst 9200 switches running Cisco IOS or IOS-XE. The script connects to multiple switches through PuTTY Plink, runs a broad but time-bounded set of investigation commands, and writes all collected output to one timestamped TXT report.

The project is intended for authorized troubleshooting and forensic triage in industrial and OT networks, where the initial fault domain may be unknown and collection time must remain controlled.

## Repository description

> Fast, read-only PowerShell collector for Cisco Catalyst 9200 OT network investigations, covering health, uptime, logs, interfaces, errors, traffic, VLANs, STP, MAC tables, security controls, neighbors, and configuration extracts.

## Important privacy note

The repository contains only generic example values:

```text
Username: network-admin
Switches: OT-SWITCH-01 through OT-SWITCH-04
IPs: 192.0.2.10 through 192.0.2.13
```

The `192.0.2.0/24` range is used only for documentation. Replace the examples with authorized management addresses before running the script.

Do not commit production usernames, internal IP addresses, SSH host keys, passwords, collected reports, device configurations, MAC addresses, or topology data to a public repository.

## Main features

- Prompts for the SSH password once using `SecureString`.
- Defines switch names and IP addresses in a simple ordered PowerShell dictionary.
- Connects to each switch sequentially using `plink.exe`.
- Performs a TCP/22 pre-check before starting SSH.
- Uses one SSH session per switch and sends all commands through a command file.
- Applies a hard timeout per switch and preserves partial output when time expires.
- Continues collecting from the remaining switches after a failure or timeout.
- Generates one consolidated timestamped TXT report.
- Supports `Fast`, `Standard`, and `Deep` modes.
- Supports optional focused VLAN investigation.
- Supports optional MAC-address searches.
- Supports PuTTY host-key pinning.
- Uses `-pwfile` when supported by the installed Plink version.
- Removes temporary command and password files after use.
- Sends only show/terminal/exit commands and does not intentionally modify switch configuration.

## Requirements

- Windows PowerShell 5.1 or a compatible Windows PowerShell environment.
- Network reachability to TCP port 22 on each switch.
- An SSH account with authorization to execute the required show commands.
- `plink.exe` from the official PuTTY distribution.
- Trusted SSH host keys stored in PuTTY or explicitly pinned in the script.

## Project structure

```text
cisco-c9200-ot-investigation/
├── CiscoC9200-OT-Investigation.ps1
├── README.md
├── GITHUB_INFO.txt
├── switches.example.ps1
└── .gitignore
```

`plink.exe` is intentionally not included. Download PuTTY/Plink from its official source and place `plink.exe` beside the script or add it to `PATH`.

## Configuration

Open `CiscoC9200-OT-Investigation.ps1` and review the user configuration section.

### SSH username

Replace the generic account:

```powershell
$User = 'network-admin'
```

Use an account authorized for read-only diagnostic commands whenever possible.

### Switch names and IP addresses

The public example uses documentation-only addresses:

```powershell
$Switches = [ordered]@{
    'OT-SWITCH-01' = '192.0.2.10'
    'OT-SWITCH-02' = '192.0.2.11'
    'OT-SWITCH-03' = '192.0.2.12'
    'OT-SWITCH-04' = '192.0.2.13'
}
```

Replace the names and addresses with authorized devices before execution:

```powershell
$Switches = [ordered]@{
    'SITE-A-OT-SW-01' = '10.20.30.11'
    'SITE-A-OT-SW-02' = '10.20.30.12'
}
```

Do not publish the customized file if the names or addresses are considered sensitive.

### Optional MAC searches

Add one or more MAC addresses when tracing a missing OT endpoint:

```powershell
$LostMacs = @(
    '00:11:22:33:44:55'
    '00-AA-BB-CC-DD-EE'
)
```

The script normalizes common formats to Cisco dotted notation.

Leave the array empty when no focused MAC search is required:

```powershell
$LostMacs = @()
```

### Optional focused VLANs

Add important OT VLAN IDs to collect detailed STP and MAC information only for those VLANs:

```powershell
$FocusVlans = @(
    100,
    200,
    300
)
```

Each configured VLAN adds:

```text
show spanning-tree vlan <VLAN> detail
show mac address-table vlan <VLAN>
```

Keep the list short to preserve the per-switch time target.

### SSH host keys

For automation, either connect manually once with PuTTY/Plink and validate the key, or pin each expected host key:

```powershell
$HostKeys = [ordered]@{
    '192.0.2.10' = 'ssh-ed25519 255 SHA256:REPLACE_WITH_VERIFIED_FINGERPRINT'
}
```

Replace the example only after verifying the fingerprint through a trusted channel. Never accept an unexpected changed host key without investigation.

## Collection modes

### Fast

```powershell
.\CiscoC9200-OT-Investigation.ps1 -Mode Fast
```

Designed for the quickest first-pass investigation. It excludes the longest detailed commands.

### Standard

```powershell
.\CiscoC9200-OT-Investigation.ps1 -Mode Standard
```

The default and recommended balance for OT troubleshooting. It adds detailed interface, STP, platform punt-rate, and diagnostic outputs while enforcing the configured hard timeout.

### Deep

```powershell
.\CiscoC9200-OT-Investigation.ps1 -Mode Deep
```

Adds a broader running-configuration extract with sensitive keywords excluded. Deep mode can produce substantially more output and may reach the timeout on busy switches.

`show tech-support` remains disabled by default because it can be large and exceed the three-minute collection objective.

## Time controls

The default hard timeout is 175 seconds per switch:

```powershell
[int]$PerSwitchTimeoutSeconds = 175
```

This remains below the three-minute target. The supported command-line range is 60 to 180 seconds.

Example:

```powershell
.\CiscoC9200-OT-Investigation.ps1 `
    -Mode Standard `
    -PerSwitchTimeoutSeconds 150 `
    -SshConnectTimeoutSeconds 5
```

If the hard timeout is reached:

- Plink is terminated.
- Output already received is retained.
- The report marks the switch as timed out.
- Collection continues with the next switch.

## Data collected

### Identity, uptime, software, stack, and hardware

```text
show clock detail
show version
show inventory
show switch detail
show boot
show redundancy
show platform
show platform resources
show platform software status control-processor brief
show processes cpu sorted 5sec
show processes memory platform sorted
show environment all
show power inline
show license summary
```

### Interfaces, traffic, errors, optics, and err-disable

```text
show interfaces status
show interfaces description
show ip interface brief
show interfaces counters
show interfaces counters errors
show interfaces transceiver detail
show interfaces switchport
show interfaces status err-disabled
show errdisable detect
show errdisable recovery
```

These outputs help investigate link state, speed, duplex, CRC/input/output errors, drops, traffic levels, optics, PoE behavior, and ports disabled by protection mechanisms.

### VLANs, trunks, EtherChannel, STP, and MAC tables

```text
show vlan brief
show interfaces trunk
show etherchannel summary
show etherchannel port-channel
show spanning-tree summary
show spanning-tree root
show spanning-tree blockedports
show spanning-tree inconsistentports
show mac address-table count
show mac address-table dynamic
show vtp status
```

### Neighbors and topology

```text
show cdp neighbors detail
show lldp neighbors detail
```

### Layer 3 and time synchronization

```text
show ip arp
show ip route
show ip default-gateway
show ip protocols
show ntp associations
show ntp status
```

### Common OT access and blocking controls

```text
show port-security
show port-security address
show authentication sessions
show access-lists
show ip access-lists
show ip dhcp snooping
show ip arp inspection
show ip verify source
show storm-control
show monitor session all
```

### Relevant configuration extracts

```text
show running-config | section ^interface
show running-config | section ^vlan
show running-config | section ^spanning-tree
show running-config | section ^monitor session
show running-config | include ^hostname|^ip default-gateway|^ip route|^ntp|^clock timezone|^logging host|^snmp-server location
```

### Logs

```text
show logging | last 300
```

Command support and output modifiers can vary by IOS-XE release. A CLI error from an unsupported command is retained in the report and does not intentionally stop subsequent collection.

## Running the collector

Place these files in the same directory:

```text
CiscoC9200-OT-Investigation.ps1
plink.exe
```

Unblock downloaded files when required:

```powershell
Unblock-File .\CiscoC9200-OT-Investigation.ps1
Unblock-File .\plink.exe
```

Run the default Standard collection:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\CiscoC9200-OT-Investigation.ps1 `
    -Mode Standard
```

The script prompts once:

```text
SSH password for network-admin:
```

The entered password is not written to the report. Temporary password files used with supported Plink versions are removed after each connection.

## Report output

The script creates one file in the script directory:

```text
Cisco_C9200_OT_Investigation_YYYYMMDD_HHMMSS.txt
```

The report contains:

- Run metadata.
- Collection mode and timeout.
- Switch name and management IP.
- Command plan for every switch.
- Raw CLI output.
- Plink standard error when present.
- Exit code.
- Timeout state.
- Per-switch duration.
- Overall duration.

Example structure:

```text
CISCO C9200 OT NETWORK INVESTIGATION
Started: ...
Collection mode: Standard
Switch count: ...

SWITCH: OT-SWITCH-01 (192.0.2.10)

COMMAND PLAN:
  terminal length 0
  show version
  ...

RAW CLI OUTPUT:
  ...

COLLECTION RESULT:
  Exit code : 0
  Timed out: False
  Duration : 62.4 seconds
```

## Troubleshooting

### `plink.exe was not found`

Place `plink.exe` beside the PowerShell script or add the PuTTY directory to the system `PATH`.

### TCP/22 is reported as unreachable

Verify:

- Management IP address.
- Routing and VPN connectivity.
- Firewall and ACL rules.
- SSH is enabled on the switch.
- The selected IP belongs to the management interface or VRF reachable from the workstation.

### Plink exits immediately in batch mode

The SSH host key may not be trusted. Perform one manual connection and validate the fingerprint, or configure the verified fingerprint under `$HostKeys`.

### Authentication fails

Verify the username, password, AAA source, TACACS/RADIUS availability, account permissions, and whether privilege level 15 or an equivalent command authorization profile is required.

### Some commands return `% Invalid input`

IOS-XE command availability varies by release, feature set, hardware variant, and configuration. The invalid-command output remains in the TXT report as useful compatibility evidence.

### Collection reaches the timeout

Use `Fast` mode, reduce `$FocusVlans`, keep `$LostMacs` focused, or increase the timeout up to 180 seconds. Avoid enabling `show tech-support` when the three-minute objective matters.

### Report contains sensitive information

The output can include real hostnames, management addresses, interface descriptions, MAC addresses, configuration extracts, usernames, neighbors, VLANs, routes, ACLs, and logs. Store the report securely and never commit it to a public repository.

## Safety and operational guidance

- Use only on switches and networks for which collection is authorized.
- Prefer an account intended for read-only diagnostics.
- Execute during an approved support window when site procedures require change control.
- Although the script sends show commands only, extensive CLI collection still consumes management-plane CPU, SSH bandwidth, and terminal resources.
- Start with one switch in `Fast` mode before running against a larger group.
- Review the command list against local OT cybersecurity standards.
- Protect reports as operationally sensitive information.

## Suggested GitHub topics

```text
cisco
catalyst-9200
cisco-ios-xe
powershell
plink
ot-network
industrial-network
network-troubleshooting
network-forensics
switch-audit
```

## License

No license is included. Add an appropriate `LICENSE` file before defining reuse or redistribution terms.
