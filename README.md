# Debian Hardening Script

A conservative Bash hardening script for Debian and Debian-based Linux systems.

The goal is to apply a practical baseline of security improvements without blindly disabling services or making irreversible changes.

## Features

- Updates installed packages
- Installs common security tools
- Hardens SSH configuration
- Enables and configures `nftables`
- Configures `fail2ban` for SSH
- Applies conservative kernel/network `sysctl` hardening
- Enables automatic package/security updates
- Enables `auditd` when supported
- Enables AppArmor when supported
- Checks permissions on sensitive system files
- Creates configuration backups before modifying files
- Provides a `--dry-run` mode
- Keeps an execution log
- Validates SSH and firewall configurations before applying them

## Supported Systems

Primarily intended for:

- Debian 12
- Debian 13
- Debian-based distributions using the standard Debian package ecosystem

Other Debian-based distributions may work, but their defaults and installed services can differ.

## Requirements

Run the script as `root` or through `sudo`.

The script expects:

- Bash
- `apt`
- `systemd`
- A Debian-style `/etc/os-release`

## Installation

Clone or copy the script:

```bash
git clone https://github.com/khodemadi/debian-hardening
cd debian-hardening
```

Make it executable:

```bash
chmod +x debian-harden.sh
```

## Dry Run

Before making changes, run:

```bash
sudo ./debian-harden.sh --dry-run
```

Dry-run mode shows the commands and configuration changes the script intends to perform without modifying the system.

It is strongly recommended to use this first.

## Run the Hardening

After reviewing the dry-run output:

```bash
sudo ./debian-harden.sh
```

The script asks for confirmation before applying the hardening.

To skip the confirmation prompt:

```bash
sudo ./debian-harden.sh --yes
```

Use `--yes` only when you understand the changes being applied.

## What Gets Changed?

### 1. Package Updates

The script updates package metadata and upgrades installed packages:

```text
apt-get update
apt-get upgrade
```

It also installs security-related packages such as:

- `fail2ban`
- `nftables`
- `auditd`
- `apparmor`
- `unattended-upgrades`
- `apt-listchanges`

### 2. SSH Hardening

If OpenSSH Server is installed, the script creates:

```text
/etc/ssh/sshd_config.d/99-debian-hardening.conf
```

The default hardening includes:

```text
PermitRootLogin prohibit-password
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
```

The script deliberately does **not** disable password authentication automatically.

This avoids locking users out of systems that still depend on SSH passwords.

The SSH configuration is validated with:

```bash
sshd -t
```

before the SSH service is reloaded.

### 3. Firewall

The script configures `nftables` with a conservative default policy:

```text
INPUT   DROP
FORWARD DROP
OUTPUT  ACCEPT
```

It allows:

- Loopback traffic
- Established/related connections
- ICMP/ICMPv6
- SSH on TCP port `22`

The firewall configuration is validated before it is loaded.

> **Important:** If your SSH server uses a port other than `22`, modify `/etc/nftables.conf` before applying the firewall configuration.

If you run a web server, database server, game server, or other network service, its required ports must also be explicitly allowed.

### 4. Fail2ban

A dedicated SSH jail is created:

```text
/etc/fail2ban/jail.d/sshd-hardening.conf
```

The default configuration limits repeated SSH authentication failures and progressively increases the ban duration.

Check its status with:

```bash
sudo fail2ban-client status sshd
```

### 5. Kernel and Network Hardening

The script creates:

```text
/etc/sysctl.d/99-debian-hardening.conf
```

It applies conservative settings such as:

- Disable source routing
- Disable ICMP redirects
- Disable IPv4 secure redirects
- Enable SYN cookies
- Ignore ICMP broadcast requests
- Log suspicious source addresses
- Disable IP forwarding by default

The settings are applied with:

```bash
sudo sysctl --system
```

### 6. Automatic Updates

The script enables Debian's automatic update mechanism when available.

Configuration:

```text
/etc/apt/apt.conf.d/20auto-upgrades
```

This enables periodic package-list updates and unattended upgrades.

### 7. AppArmor

When available, the script enables AppArmor.

Check its status:

```bash
sudo aa-status
```

### 8. Audit Logging

When supported, the script enables `auditd`.

Check the service:

```bash
sudo systemctl status auditd
```

### 9. Sensitive File Permissions

The script checks permissions on files such as:

```text
/etc/passwd
/etc/group
/etc/shadow
/etc/gshadow
```

It does not modify arbitrary files across the filesystem.

## Backups

Before modifying an existing configuration file, the script creates a backup under:

```text
/var/backups/debian-hardening/<timestamp>/
```

For example:

```text
/var/backups/debian-hardening/20260921-170000/
```

This makes it possible to inspect the previous configuration if something goes wrong.

## Logs

Execution logs are stored in:

```text
/var/log/debian-hardening.log
```

The log can be reviewed with:

```bash
sudo less /var/log/debian-hardening.log
```

## Verification

After running the script, verify the important services.

### SSH

```bash
sudo sshd -t
sudo systemctl status ssh
```

### Firewall

```bash
sudo nft list ruleset
```

### Fail2ban

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

### AppArmor

```bash
sudo aa-status
```

### Auditd

```bash
sudo systemctl status auditd
```

### Automatic Updates

```bash
systemctl status unattended-upgrades
```

## Important Safety Notes

This script provides a **security baseline**, not a complete security solution.

Hardening requirements depend on the machine's role.

For example, a:

- Desktop
- SSH server
- Web server
- Database server
- Docker host
- Kubernetes node
- VPN server

will require different firewall rules and security policies.

### SSH Warning

Always keep an existing SSH session open while testing SSH changes.

Open a second terminal and verify that you can connect before closing your original session.

### Firewall Warning

The default firewall configuration only allows SSH on TCP port `22`.

If your machine provides other network services, add the required ports before enabling the firewall.

Do not blindly expose services to the Internet.

## Uninstall / Rollback

The script does not provide an automatic "undo everything" command because the correct rollback depends on what was installed or changed.

Configuration backups are stored in:

```text
/var/backups/debian-hardening/
```

The managed files can be restored manually from the corresponding backup.

The main managed configuration files are:

```text
/etc/ssh/sshd_config.d/99-debian-hardening.conf
/etc/nftables.conf
/etc/fail2ban/jail.d/sshd-hardening.conf
/etc/sysctl.d/99-debian-hardening.conf
/etc/apt/apt.conf.d/20auto-upgrades
```

## Command Reference

```text
./debian-harden.sh --dry-run
```

Preview changes without modifying the system.

```text
sudo ./debian-harden.sh
```

Run interactively.

```text
sudo ./debian-harden.sh --yes
```

Run without confirmation prompts.

```text
./debian-harden.sh --help
```

Show available options.

## Project Structure

```text
.
├── debian-harden.sh
└── README.md
```

## Security Philosophy

The script follows a few principles:

1. Prefer reversible configuration changes.
2. Back up configuration before modifying it.
3. Validate configuration before reloading critical services.
4. Avoid disabling SSH password authentication automatically.
5. Avoid automatically disabling unknown services.
6. Avoid automatic package removal.
7. Use a conservative firewall baseline.
8. Keep the administrator in control of system-specific decisions.

## Disclaimer

Use this script at your own risk.

No hardening script can guarantee that a system is secure.

Always review the generated configuration and adapt firewall, SSH, AppArmor, audit, and service settings to the actual role of the machine.

## License

MIT License.

Copyright (c) 2026

See the [LICENSE](LICENSE) file for the full license text.
