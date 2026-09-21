#!/usr/bin/env bash
#
# debian-harden.sh
# Conservative security hardening for Debian-based systems.
#
# Usage:
#   sudo ./debian-harden.sh
#   sudo ./debian-harden.sh --dry-run
#
# Notes:
# - Designed for Debian 12/13 and Debian-based systems.
# - Creates backups before modifying configuration.
# - Does NOT disable root locally, change the SSH port, or blindly
#   disable arbitrary services.
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/debian-hardening/$TIMESTAMP"
LOG_FILE="/var/log/debian-hardening.log"
DRY_RUN=0
ASSUME_YES=0

SSH_CONFIG="/etc/ssh/sshd_config"
SYSCTL_CONFIG="/etc/sysctl.d/99-debian-hardening.conf"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
RESET=$'\033[0m'

log() {
    local msg="$1"
    printf '[%s] %s\n' "$(date '+%F %T')" "$msg" | tee -a "$LOG_FILE" >/dev/null
}

info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; log "INFO: $*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; log "OK: $*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; log "WARN: $*"; }
error() { printf '%s[ERR ]%s %s\n' "$RED" "$RESET" "$*" >&2; log "ERROR: $*"; }

die() {
    error "$*"
    exit 1
}

run() {
    if (( DRY_RUN )); then
        printf '%s[DRY ]%s' "$YELLOW" "$RESET"
        printf ' '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root: sudo ./$SCRIPT_NAME"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            -y|--yes)
                ASSUME_YES=1
                ;;
            -h|--help)
                cat <<EOF
Usage: sudo ./$SCRIPT_NAME [OPTIONS]

Options:
  --dry-run       Show commands without changing the system
  -y, --yes       Do not ask for confirmation
  -h, --help      Show this help

The script:
  * updates packages
  * installs security utilities
  * configures conservative SSH hardening
  * enables a firewall
  * configures Fail2ban
  * applies conservative kernel/network sysctl settings
  * enables unattended security updates when available
  * fixes selected sensitive file permissions
  * creates backups before configuration changes
EOF
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

confirm() {
    local question="$1"

    (( ASSUME_YES )) && return 0
    (( DRY_RUN )) && return 0

    read -r -p "$question [y/N] " answer
    [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]
}

backup_file() {
    local file="$1"

    [[ -e "$file" ]] || return 0

    if (( DRY_RUN )); then
        info "Would backup: $file"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    cp -a -- "$file" "$BACKUP_DIR/"
    ok "Backup created: $BACKUP_DIR/$(basename "$file")"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
        warn "This script targets Debian-based systems. Detected: ${PRETTY_NAME:-unknown}"
        confirm "Continue anyway?" || exit 0
    fi

    info "Detected OS: ${PRETTY_NAME:-unknown}"
}

prepare() {
    if (( ! DRY_RUN )); then
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    fi

    if (( ! DRY_RUN )); then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
    fi

    info "Backup directory: $BACKUP_DIR"
    info "Log file: $LOG_FILE"
}

update_system() {
    info "Updating package lists..."
    run apt-get update

    info "Upgrading installed packages..."
    run env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

    ok "System packages updated."
}

install_security_tools() {
    local packages=(
        ca-certificates
        curl
        unattended-upgrades
        apt-listchanges
        fail2ban
        nftables
        auditd
        apparmor
        apparmor-utils
    )

    info "Installing security tools..."
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    ok "Security tools installed."
}

configure_ssh() {
    [[ -f "$SSH_CONFIG" ]] || {
        warn "OpenSSH server configuration not found; skipping SSH hardening."
        return
    }

    if ! command -v sshd >/dev/null 2>&1; then
        warn "sshd not installed; skipping SSH hardening."
        return
    fi

    info "Preparing SSH hardening..."

    # Never make changes if we cannot validate sshd configuration.
    backup_file "$SSH_CONFIG"

    if (( DRY_RUN )); then
        info "Would configure conservative SSH settings."
        return
    fi

    # Preserve the existing file and manage our settings in a dedicated drop-in.
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin="$dropin_dir/99-debian-hardening.conf"

    mkdir -p "$dropin_dir"
    backup_file "$dropin"

    cat > "$dropin" <<'EOF'
# Managed by debian-harden.sh
#
# Conservative SSH hardening.
# PasswordAuthentication remains unchanged intentionally.
# PermitRootLogin is changed to prohibit-password so existing
# key-based administration can continue while root passwords
# cannot be used for SSH login.

PermitRootLogin prohibit-password
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding yes
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

    chmod 644 "$dropin"

    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        ok "SSH configuration validated and reloaded."
    else
        error "New SSH configuration is invalid. Restoring drop-in."
        rm -f "$dropin"

        if [[ -f "$BACKUP_DIR/$(basename "$dropin")" ]]; then
            cp -a "$BACKUP_DIR/$(basename "$dropin")" "$dropin"
        fi

        sshd -t || die "SSH configuration remains invalid."
    fi
}

configure_firewall() {
    if ! command -v nft >/dev/null 2>&1; then
        warn "nft command unavailable; skipping firewall."
        return
    fi

    if ! systemctl is-enabled nftables >/dev/null 2>&1; then
        info "Enabling nftables..."
        run systemctl enable nftables
    fi

    if [[ ! -f /etc/nftables.conf ]]; then
        warn "/etc/nftables.conf not found; creating a conservative ruleset."
    else
        backup_file /etc/nftables.conf
    fi

    if (( DRY_RUN )); then
        info "Would configure nftables."
        return
    fi

    cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter;
        policy drop;

        # Loopback
        iifname "lo" accept

        # Existing/related connections
        ct state established,related accept

        # Invalid packets
        ct state invalid drop

        # ICMP/ICMPv6 are needed for normal network operation.
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # SSH
        tcp dport 22 ct state new accept
    }

    chain forward {
        type filter hook forward priority filter;
        policy drop;
    }

    chain output {
        type filter hook output priority filter;
        policy accept;
    }
}
EOF

    chmod 600 /etc/nftables.conf

    if nft -c -f /etc/nftables.conf; then
        systemctl restart nftables
        ok "nftables configured."
    else
        error "nftables configuration validation failed; restoring backup."
        if [[ -f "$BACKUP_DIR/nftables.conf" ]]; then
            cp -a "$BACKUP_DIR/nftables.conf" /etc/nftables.conf
            systemctl restart nftables || true
        fi
        die "Firewall configuration failed."
    fi

    warn "Firewall allows SSH on TCP/22. If your SSH port is different, edit the ruleset before applying it."
}

configure_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        warn "Fail2ban is unavailable; skipping."
        return
    fi

    local jail="/etc/fail2ban/jail.d/sshd-hardening.conf"

    backup_file "$jail"

    if (( DRY_RUN )); then
        info "Would configure Fail2ban for SSH."
        return
    fi

    mkdir -p /etc/fail2ban/jail.d

    cat > "$jail" <<'EOF'
[sshd]
enabled = true
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1d
EOF

    chmod 644 "$jail"

    if fail2ban-client -t >/dev/null 2>&1; then
        systemctl enable --now fail2ban
        systemctl restart fail2ban
        ok "Fail2ban SSH jail enabled."
    else
        error "Fail2ban configuration test failed; restoring previous configuration."
        rm -f "$jail"
        if [[ -f "$BACKUP_DIR/$(basename "$jail")" ]]; then
            cp -a "$BACKUP_DIR/$(basename "$jail")" "$jail"
        fi
    fi
}

configure_sysctl() {
    backup_file "$SYSCTL_CONFIG"

    if (( DRY_RUN )); then
        info "Would apply conservative sysctl network hardening."
        return
    fi

    cat > "$SYSCTL_CONFIG" <<'EOF'
# Managed by debian-harden.sh
# Conservative network/kernel hardening.

# Disable IPv4 source routing.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Do not send ICMP redirects.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable IPv4 secure redirects.
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Ignore ICMP broadcast requests.
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log suspicious source addresses.
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Enable SYN cookies.
net.ipv4.tcp_syncookies = 1

# IPv6 source routing and redirects.
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not enable IP forwarding automatically.
net.ipv4.ip_forward = 0
EOF

    chmod 644 "$SYSCTL_CONFIG"

    if sysctl --system >/dev/null; then
        ok "Kernel/network sysctl hardening applied."
    else
        warn "Some sysctl settings could not be applied; review sysctl output."
    fi
}

configure_unattended_upgrades() {
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        warn "unattended-upgrades is unavailable; skipping."
        return
    fi

    local auto_conf="/etc/apt/apt.conf.d/20auto-upgrades"

    backup_file "$auto_conf"

    if (( DRY_RUN )); then
        info "Would enable automatic package/security updates."
        return
    fi

    cat > "$auto_conf" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    chmod 644 "$auto_conf"
    ok "Automatic updates enabled."
}

configure_auditd() {
    if ! command -v auditctl >/dev/null 2>&1; then
        warn "auditd unavailable; skipping."
        return
    fi

    if (( DRY_RUN )); then
        info "Would enable auditd."
        return
    fi

    systemctl enable --now auditd 2>/dev/null || true
    ok "auditd enabled where supported."
}

configure_apparmor() {
    if ! command -v aa-status >/dev/null 2>&1; then
        warn "AppArmor tools unavailable; skipping."
        return
    fi

    if (( DRY_RUN )); then
        info "Would enable AppArmor."
        return
    fi

    systemctl enable --now apparmor 2>/dev/null || true
    ok "AppArmor enabled where supported."
}

fix_sensitive_permissions() {
    info "Checking sensitive file permissions..."

    if [[ -f /etc/shadow ]]; then
        run chmod 640 /etc/shadow
    fi

    if [[ -f /etc/gshadow ]]; then
        run chmod 640 /etc/gshadow
    fi

    if [[ -f /etc/passwd ]]; then
        run chmod 644 /etc/passwd
    fi

    if [[ -f /etc/group ]]; then
        run chmod 644 /etc/group
    fi

    ok "Sensitive file permissions checked."
}

remove_orphaned_packages() {
    info "Checking for orphaned packages..."

    if (( DRY_RUN )); then
        run apt-get -s autoremove
        return
    fi

    # Simulation first; actual removal is deliberately not automatic.
    apt-get -s autoremove || true
    warn "No automatic autoremove was performed. Review the list above manually."
}

show_summary() {
    printf '\n'
    printf '%s========================================%s\n' "$GREEN" "$RESET"
    printf '%s Debian hardening completed%s\n' "$GREEN" "$RESET"
    printf '%s========================================%s\n' "$GREEN" "$RESET"
    printf 'Backup: %s\n' "$BACKUP_DIR"
    printf 'Log:    %s\n' "$LOG_FILE"
    printf '\n'
    printf 'Important:\n'
    printf '  1. Verify you can still SSH into the machine from a second terminal.\n'
    printf '  2. Verify your required network services are reachable.\n'
    printf '  3. Review: nft list ruleset\n'
    printf '  4. Review: fail2ban-client status sshd\n'
    printf '  5. Review: systemctl status ssh fail2ban nftables\n'
    printf '\n'
}

main() {
    parse_args "$@"
    require_root
    detect_os
    prepare

    if (( DRY_RUN )); then
        warn "DRY-RUN mode: no changes will be made."
    else
        if ! confirm "Apply Debian hardening to this system?"; then
            info "Cancelled."
            exit 0
        fi
    fi

    update_system
    install_security_tools
    configure_ssh
    configure_firewall
    configure_fail2ban
    configure_sysctl
    configure_unattended_upgrades
    configure_auditd
    configure_apparmor
    fix_sensitive_permissions
    remove_orphaned_packages

    show_summary
}

main "$@"
